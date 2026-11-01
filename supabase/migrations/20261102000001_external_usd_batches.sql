-- The one-shot re-valuation of external swaps (20261101000003) did every pool in one transaction: on the free tier
-- the mainnet server restarted twice under it. It also unscheduled itself first, which kept a row lock on cron.job for
-- the whole run. This version does a few pools per minute, marks each one done, and removes its job only once nothing
-- is left. The backfill job no longer takes its table lock when it has nothing to do.

set lock_timeout = '10s';
set statement_timeout = '120s';

create table if not exists public.aethra_usd_fix (
  chain_id integer not null,
  pool_id  text not null,
  done_at  timestamptz not null default now(),
  primary key (chain_id, pool_id)
);
alter table public.aethra_usd_fix enable row level security;
revoke all on public.aethra_usd_fix from anon, authenticated;

drop function if exists public.aethra_fix_external_usd();

/** Re-values the stored swaps of up to p_pools external pools per call through a stable or oracle priced side. */
create or replace function public.aethra_fix_external_usd(p_pools integer default 3)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_since timestamptz;
  n integer := 0;
  v_left integer;
begin
  for r in
    select p.chain_id, p.pool_id from pools p
    join chains c on c.chain_id = p.chain_id and c.enabled
    where p.external and not exists (select 1 from aethra_usd_fix f where f.chain_id = p.chain_id and f.pool_id = p.pool_id)
    order by p.chain_id, p.pool_id
    limit p_pools
  loop
    update swaps s
       set amount_usd = coalesce(
             case when ti.price_source in ('stable', 'oracle') then (s.amount_in / power(10::numeric, ti.decimals))::float8 * ti.price_usd end,
             case when tou.price_source in ('stable', 'oracle') then (s.amount_out / power(10::numeric, tou.decimals))::float8 * tou.price_usd end,
             0),
           fee_usd = null
      from tokens ti, tokens tou
     where s.chain_id = r.chain_id and s.pool_id = r.pool_id
       and ti.chain_id = s.chain_id and ti.address = s.token_in
       and tou.chain_id = s.chain_id and tou.address = s.token_out;
    update swaps s
       set fee_usd = s.amount_usd * (s.fee_amount / nullif(s.amount_in, 0))::float8
     where s.chain_id = r.chain_id and s.pool_id = r.pool_id and s.fee_usd is null;

    -- hourly stats: rebuilt for the stored hours, USD cleared for older hours (their swaps are pruned)
    select min(ts) into v_since from swaps where chain_id = r.chain_id and pool_id = r.pool_id;
    if v_since is not null then
      perform public.aethra_refresh(r.chain_id, array[r.pool_id], v_since);
    end if;
    update pool_stats_hourly h
       set volume_usd = 0, fees_usd = 0
     where h.chain_id = r.chain_id and h.pool_id = r.pool_id
       and h.hour < date_trunc('hour', coalesce(v_since, now()))
       and (h.volume_usd <> 0 or h.fees_usd <> 0);

    insert into aethra_usd_fix (chain_id, pool_id) values (r.chain_id, r.pool_id) on conflict do nothing;
    n := n + 1;
  end loop;

  select count(*) into v_left from pools p join chains c on c.chain_id = p.chain_id and c.enabled
  where p.external and not exists (select 1 from aethra_usd_fix f where f.chain_id = p.chain_id and f.pool_id = p.pool_id);
  return jsonb_build_object('pools', n, 'left', v_left);
end;
$$;

revoke all on function public.aethra_fix_external_usd(integer) from public, anon, authenticated;

/** pg_cron: runs a batch, and removes its own job once every external pool is done (in a separate statement). */
create or replace function public.aethra_fix_external_usd_job()
returns void
language plpgsql
security definer
set search_path = public, cron
as $$
begin
  if (public.aethra_fix_external_usd(3) ->> 'left')::int = 0 then
    perform cron.unschedule('aethra-fix-external-usd');
  end if;
end;
$$;

revoke all on function public.aethra_fix_external_usd_job() from public, anon, authenticated;

-- backfill: only lock the event tables when some pool is still waiting
create or replace function public.aethra_backfill_ext_sums(p_chain integer, p_budget interval default interval '15 seconds', p_all boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stop timestamptz := clock_timestamp() + p_budget;
  r record;
  n integer := 0;
begin
  -- the one-shot compaction (migration 20261101000002) sums every kept pool itself; it leaves its result in db_health
  -- (cron.job is not a usable signal: its row-level security hides jobs scheduled by other roles)
  if to_regclass('public.db_health') is not null then
    if not exists (select 1 from public.db_health where action is not null) then
      return jsonb_build_object('skipped', 'compaction pending');
    end if;
  end if;
  if not p_all and not exists (select 1 from pools where chain_id = p_chain and external and not ext_sums_ready) then
    return jsonb_build_object('pools', 0, 'pending', 0);
  end if;
  lock table public.swaps, public.liquidity_events in share row exclusive mode;
  for r in
    select q.pool_id, q.ext_floor_block from pools q
    where q.chain_id = p_chain and q.external and (p_all or not q.ext_sums_ready)
    order by q.pool_id
  loop
    exit when clock_timestamp() > v_stop;
    update pools p
       set ext_live0 = coalesce((select sum(s.delta0) from swaps s where s.chain_id = p_chain and s.pool_id = r.pool_id and s.block_number > r.ext_floor_block), 0)
                     + coalesce((select sum(l.amount0) from liquidity_events l where l.chain_id = p_chain and l.pool_id = r.pool_id and l.block_number > r.ext_floor_block
                                   and l.source <> 'positions' and l.kind in ('add', 'remove', 'modify')), 0),
           ext_live1 = coalesce((select sum(s.delta1) from swaps s where s.chain_id = p_chain and s.pool_id = r.pool_id and s.block_number > r.ext_floor_block), 0)
                     + coalesce((select sum(l.amount1) from liquidity_events l where l.chain_id = p_chain and l.pool_id = r.pool_id and l.block_number > r.ext_floor_block
                                   and l.source <> 'positions' and l.kind in ('add', 'remove', 'modify')), 0),
           ext_sums_ready = true
     where p.chain_id = p_chain and p.pool_id = r.pool_id;
    n := n + 1;
  end loop;
  return jsonb_build_object('pools', n, 'pending', (select count(*) from pools where chain_id = p_chain and external and not ext_sums_ready));
end;
$$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'aethra-fix-external-usd') then
    perform cron.unschedule('aethra-fix-external-usd');
  end if;
  perform cron.schedule('aethra-fix-external-usd', '* * * * *', $job$set statement_timeout = '5min'; select public.aethra_fix_external_usd_job()$job$);
end
$$;
