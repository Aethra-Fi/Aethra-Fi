-- Stay under the free plan's 500 MB database size (the "exceeding usage limits" warning of 2026-11-01).
--
-- Testnet had grown to 1362 MB and mainnet to 614 MB, almost all of it the replayed history of 150 external
-- Uniswap v4 pools (testnet: bot pools with 1.39M swaps). Deleting rows does not give disk space back, so:
--
-- 1. chains.external_max sets the watchlist size per chain (mainnet 40, others 0). The indexer reads it.
-- 2. aethra_compact() keeps the top external pools by TVL, folds their whole stored history into the running sums
--    (ext_base*), keeps only their last p_keep of events plus all of Aethra's own, and rewrites the two event
--    tables (TRUNCATE + re-insert), which returns the space at once.
-- 3. It runs as pg_cron jobs inside the database: a long statement over a client connection gets cut off on this
--    tier (see B29), a background job does not.
-- 4. aethra_size_guard() records the size every hour into db_health and compacts harder past 400 MB. /health
--    reports the size and turns "degraded" past 400 MB.

-- Fail fast instead of queueing behind a lock; the heavy work runs later as a pg_cron job. Safe to rerun.
set lock_timeout = '10s';
set statement_timeout = '120s';

alter table public.chains add column if not exists external_max integer not null default 0;
comment on column public.chains.external_max is 'Watchlist size for external Uniswap v4 pools (0 = none). Each one adds its replayed history to the database.';
update public.chains set external_max = 40 where network = 'mainnet' and external_max = 0;

create table if not exists public.db_health (
  id          integer primary key default 1 check (id = 1),
  checked_at  timestamptz not null default now(),
  db_bytes    bigint not null,
  action      jsonb
);
alter table public.db_health enable row level security;
revoke all on public.db_health from anon, authenticated;
grant select on public.db_health to service_role;

/**
 * Shrinks the event tables of one chain. Keeps the top p_max_external external pools by TVL (drops the rest from
 * the watchlist), adds every stored event of the kept pools above ext_floor_block to ext_base* and moves the floor
 * to the last replayed block, then keeps their events of the last p_keep and every event of Aethra's own pools.
 * Rows re-inserted below the floor are skipped by the sum trigger, so nothing is counted twice.
 */
create or replace function public.aethra_compact(p_chain integer, p_keep interval default interval '7 days', p_max_external integer default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_max integer := coalesce(p_max_external, (select external_max from chains where chain_id = p_chain), 0);
  v_cut timestamptz := now() - p_keep;
  v_kept text[];
  v_drop text[];
  v_own text[];
  v_before bigint := pg_database_size(current_database());
  n_swaps bigint;
  n_liq bigint;
begin
  lock table public.swaps, public.liquidity_events in exclusive mode;

  v_kept := array(
    select pool_id from pools
    where chain_id = p_chain and external and enabled
    order by tvl_usd desc nulls last, pool_id
    limit greatest(v_max, 0)
  );
  v_drop := array(select pool_id from pools where chain_id = p_chain and external and not (pool_id = any(v_kept)));
  v_own := array(select pool_id from pools where chain_id = p_chain and not external);

  -- 1. fold the stored history of the kept pools into ext_base*
  update pools p
     set ext_base0 = p.ext_base0 + coalesce(sw.d0, 0) + coalesce(lq.a0, 0),
         ext_base1 = p.ext_base1 + coalesce(sw.d1, 0) + coalesce(lq.a1, 0),
         ext_live0 = 0,
         ext_live1 = 0,
         ext_floor_block = greatest(p.ext_floor_block, coalesce(p.ext_synced_block, -1), coalesce(sw.b, -1), coalesce(lq.b, -1)),
         ext_sums_ready = true
    from pools q
    left join lateral (
      select sum(s.delta0) as d0, sum(s.delta1) as d1, max(s.block_number) as b from swaps s
      where s.chain_id = q.chain_id and s.pool_id = q.pool_id and s.block_number > q.ext_floor_block
    ) sw on true
    left join lateral (
      select sum(l.amount0) filter (where l.source <> 'positions' and l.kind in ('add', 'remove', 'modify')) as a0,
             sum(l.amount1) filter (where l.source <> 'positions' and l.kind in ('add', 'remove', 'modify')) as a1,
             max(l.block_number) as b
      from liquidity_events l
      where l.chain_id = q.chain_id and l.pool_id = q.pool_id and l.block_number > q.ext_floor_block
    ) lq on true
   where q.chain_id = p_chain and q.pool_id = any(v_kept) and p.chain_id = q.chain_id and p.pool_id = q.pool_id;

  -- 2. what stays: every Aethra event, the recent events of the kept pools, and other chains' rows. Each part is
  --    read through an index (an OR over the whole table is a sequential scan, too slow on this tier).
  create temp table aethra_keep_swaps on commit drop as
    select * from swaps s where s.chain_id = p_chain and s.pool_id = any(v_own);
  insert into aethra_keep_swaps
    select * from swaps s where s.chain_id = p_chain and s.pool_id = any(v_kept) and s.ts >= v_cut;
  insert into aethra_keep_swaps
    select s.* from chains c join swaps s on s.chain_id = c.chain_id where c.chain_id <> p_chain;
  create temp table aethra_keep_liq on commit drop as
    select * from liquidity_events l where l.chain_id = p_chain and l.pool_id = any(v_own);
  insert into aethra_keep_liq
    select * from liquidity_events l where l.chain_id = p_chain and l.pool_id is null;
  insert into aethra_keep_liq
    select * from liquidity_events l where l.chain_id = p_chain and l.pool_id = any(v_kept) and l.ts >= v_cut;
  insert into aethra_keep_liq
    select l.* from chains c join liquidity_events l on l.chain_id = c.chain_id where c.chain_id <> p_chain;

  -- 3. rewrite both tables (returns the disk space)
  truncate public.swaps, public.liquidity_events;
  insert into public.swaps select * from aethra_keep_swaps;
  get diagnostics n_swaps = row_count;
  insert into public.liquidity_events select * from aethra_keep_liq;
  get diagnostics n_liq = row_count;
  drop table aethra_keep_swaps, aethra_keep_liq; -- the size guard compacts several chains in one transaction

  -- 4. dropped pools leave the watchlist (hourly stats and keys go with them)
  delete from pool_stats_hourly where chain_id = p_chain and pool_id = any(v_drop);
  delete from v4_pool_keys where chain_id = p_chain and pool_id = any(v_drop);
  delete from pools where chain_id = p_chain and pool_id = any(v_drop);

  return jsonb_build_object(
    'chain_id', p_chain, 'kept_external', coalesce(array_length(v_kept, 1), 0), 'dropped_external', coalesce(array_length(v_drop, 1), 0),
    'swaps_kept', n_swaps, 'liquidity_events_kept', n_liq, 'db_bytes_before', v_before, 'at', now()
  );
end;
$$;

revoke all on function public.aethra_compact(integer, interval, integer) from public, anon, authenticated;
grant execute on function public.aethra_compact(integer, interval, integer) to service_role;

/**
 * Hourly: records the database size. Past 400 MB it compacts every enabled chain with a shorter history and half
 * the watchlist, so the database comes back under the limit without anyone acting. Free plan limit: 500 MB.
 */
create or replace function public.aethra_size_guard()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_size bigint := pg_database_size(current_database());
  v_action jsonb := null;
  r record;
begin
  if v_size > 400 * 1024 * 1024 then
    v_action := '[]'::jsonb;
    for r in select chain_id, external_max from chains where enabled loop
      update chains set external_max = external_max / 2 where chain_id = r.chain_id;
      v_action := v_action || jsonb_build_array(public.aethra_compact(r.chain_id, interval '2 days', r.external_max / 2));
    end loop;
    v_size := pg_database_size(current_database());
  end if;
  insert into db_health as h (id, checked_at, db_bytes, action) values (1, now(), v_size, v_action)
  on conflict (id) do update set checked_at = excluded.checked_at, db_bytes = excluded.db_bytes,
    action = coalesce(excluded.action, h.action);
  return jsonb_build_object('db_bytes', v_size, 'action', v_action);
end;
$$;

revoke all on function public.aethra_size_guard() from public, anon, authenticated;
grant execute on function public.aethra_size_guard() to service_role;

-- One-shot job: compact now (in the background, see 3. above), record the size, then remove itself.
create or replace function public.aethra_compact_once()
returns void
language plpgsql
security definer
set search_path = public, cron
as $$
declare
  r record;
  v jsonb := '[]'::jsonb;
begin
  perform cron.unschedule('aethra-compact-once');
  for r in select chain_id from chains where enabled loop
    v := v || jsonb_build_array(public.aethra_compact(r.chain_id));
  end loop;
  insert into db_health as h (id, checked_at, db_bytes, action) values (1, now(), pg_database_size(current_database()), v)
  on conflict (id) do update set checked_at = excluded.checked_at, db_bytes = excluded.db_bytes, action = excluded.action;
end;
$$;

revoke all on function public.aethra_compact_once() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'aethra-compact-once') then
    perform cron.unschedule('aethra-compact-once');
  end if;
  -- pg_cron statements stop after 2 minutes by default here; the one-shot compaction may need longer
  perform cron.schedule('aethra-compact-once', '* * * * *', 'set statement_timeout = 0; select public.aethra_compact_once()');

  if exists (select 1 from cron.job where jobname = 'aethra-size-guard') then
    perform cron.unschedule('aethra-size-guard');
  end if;
  perform cron.schedule('aethra-size-guard', '41 * * * *', 'set statement_timeout = 0; select public.aethra_size_guard()');

  -- the first fill of pool_overview_mv (migration 20261101000001) can also take longer than 2 minutes
  if exists (select 1 from cron.job where jobname = 'aethra-overview') then
    perform cron.unschedule('aethra-overview');
  end if;
  perform cron.schedule('aethra-overview', '* * * * *', $job$set statement_timeout = '10min'; select public.aethra_refresh_overview()$job$);
end
$$;
