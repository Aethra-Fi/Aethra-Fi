-- Keep the database inside the free compute tier (shared CPU, 0.5 GB RAM).
--
-- Before this migration the replay of ~150 external Uniswap v4 pools filled `swaps` with ~590k rows (533 MB, more
-- than RAM). Every indexer run re-summed the full history of each touched pool to rebuild its reserves, and every
-- API read of `pool_overview` ran five lateral subqueries per pool. Reads hit disk, statements hit the 8 s API
-- timeout and the whole instance stalled.
--
-- 1. External pools: reserves become running sums. A statement trigger adds the deltas of newly inserted events
--    (ON CONFLICT DO NOTHING rows are not in the transition table, so re-scans do not double count).
--    ext_live* = sum of stored events above ext_floor_block, ext_base* = sum of pruned events. Pools that existed
--    before are summed a few at a time by pg_cron (aethra_backfill_ext_sums) and keep their reserves until then.
-- 2. External events older than 7 days are pruned in small batches (pg_cron). Their hourly stats stay.
-- 3. pool_overview is served from a materialized view refreshed every minute by pg_cron.
-- Aethra's own pools are unchanged: full history, reserves summed from the event tables.

-- Fail fast instead of queueing: a DDL statement waiting for a lock blocks every later reader of that table.
-- On a timeout, rerun `supabase db push`; every step is safe to repeat.
set lock_timeout = '10s';
set statement_timeout = '120s';

-- ---------------------------------------------------------------------------------------------
-- 1. running sums for external pools
-- ---------------------------------------------------------------------------------------------
alter table public.pools
  add column if not exists ext_base0 numeric not null default 0,
  add column if not exists ext_base1 numeric not null default 0,
  add column if not exists ext_live0 numeric not null default 0,
  add column if not exists ext_live1 numeric not null default 0,
  add column if not exists ext_floor_block bigint not null default -1,
  add column if not exists ext_sums_ready boolean not null default false;

comment on column public.pools.ext_live0 is 'External pools: token0 sum of stored events above ext_floor_block (trigger-maintained)';
comment on column public.pools.ext_base0 is 'External pools: token0 sum of events pruned at or below ext_floor_block';
comment on column public.pools.ext_sums_ready is 'External pools: ext_live* covers every stored event (set by aethra_backfill_ext_sums)';

create or replace function public.aethra_ext_sums_swaps()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update pools p
     set ext_live0 = p.ext_live0 + x.d0, ext_live1 = p.ext_live1 + x.d1
    from (
      select n.chain_id, n.pool_id, sum(n.delta0) as d0, sum(n.delta1) as d1
      from new_rows n
      join pools q on q.chain_id = n.chain_id and q.pool_id = n.pool_id
      where q.external and n.block_number > q.ext_floor_block
      group by n.chain_id, n.pool_id
    ) x
   where p.chain_id = x.chain_id and p.pool_id = x.pool_id;
  return null;
end;
$$;

create or replace function public.aethra_ext_sums_liquidity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update pools p
     set ext_live0 = p.ext_live0 + x.a0, ext_live1 = p.ext_live1 + x.a1
    from (
      select n.chain_id, n.pool_id, sum(n.amount0) as a0, sum(n.amount1) as a1
      from new_rows n
      join pools q on q.chain_id = n.chain_id and q.pool_id = n.pool_id
      where q.external and n.block_number > q.ext_floor_block
        and n.source <> 'positions' and n.kind in ('add', 'remove', 'modify')
      group by n.chain_id, n.pool_id
    ) x
   where p.chain_id = x.chain_id and p.pool_id = x.pool_id;
  return null;
end;
$$;

-- Triggers first (a short lock): from here on every new event is added to its pool's sums.
do $$
begin
  lock table public.swaps, public.liquidity_events in share row exclusive mode;

  drop trigger if exists aethra_ext_sums on public.swaps;
  create trigger aethra_ext_sums after insert on public.swaps
    referencing new table as new_rows for each statement execute function public.aethra_ext_sums_swaps();

  drop trigger if exists aethra_ext_sums on public.liquidity_events;
  create trigger aethra_ext_sums after insert on public.liquidity_events
    referencing new table as new_rows for each statement execute function public.aethra_ext_sums_liquidity();
end
$$;

/**
 * Sets ext_live* of external pools from their stored events and marks them ready, a few pools per call (summing
 * the whole history at once is too heavy for the free tier). The table lock keeps inserts out while a pool is
 * summed, so the trigger and the sum never overlap. With p_all every external pool is redone (repair tool).
 * Until a pool is ready aethra_refresh leaves its reserves as they were.
 */
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

drop function if exists public.aethra_rebuild_ext_sums(integer);

-- ---------------------------------------------------------------------------------------------
-- 2. prune external events older than p_keep
-- ---------------------------------------------------------------------------------------------
/**
 * Deletes external-pool events at or below the block that was current `p_keep` ago, for up to `p_max_pools`
 * pools per call, and moves their sums from ext_live* to ext_base*. A pool whose replay has not reached that
 * block is skipped, so replayed events are never mistaken for pruned ones.
 */
create or replace function public.aethra_prune_external(p_chain integer, p_keep interval default interval '7 days', p_max_pools integer default 10)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cut bigint;
  v_cut_ts timestamptz := now() - p_keep;
  r record;
  s0 numeric; s1 numeric; l0 numeric; l1 numeric;
  ns integer; nl integer;
  tot_s integer := 0;
  tot_l integer := 0;
  n_pools integer := 0;
begin
  select s.block_number into v_cut from swaps s
  where s.chain_id = p_chain and s.ts < v_cut_ts
  order by s.ts desc limit 1;
  if v_cut is null then
    return jsonb_build_object('cut_block', null, 'pools', 0);
  end if;

  for r in
    select q.pool_id, q.ext_floor_block from pools q
    where q.chain_id = p_chain and q.external and q.ext_sums_ready and q.ext_floor_block < v_cut
      and q.ext_synced_block is not null and q.ext_synced_block >= v_cut
    order by q.ext_floor_block, q.pool_id
    limit p_max_pools
    for update
  loop
    with del as (
      delete from swaps s
      where s.chain_id = p_chain and s.pool_id = r.pool_id and s.ts < v_cut_ts + interval '1 hour' and s.block_number <= v_cut
      returning s.block_number, s.delta0, s.delta1
    )
    select coalesce(sum(delta0) filter (where block_number > r.ext_floor_block), 0),
           coalesce(sum(delta1) filter (where block_number > r.ext_floor_block), 0),
           count(*)
      into s0, s1, ns from del;

    with del as (
      delete from liquidity_events l
      where l.chain_id = p_chain and l.pool_id = r.pool_id and l.block_number <= v_cut
      returning l.block_number, l.source, l.kind, l.amount0, l.amount1
    )
    select coalesce(sum(amount0) filter (where block_number > r.ext_floor_block and source <> 'positions' and kind in ('add', 'remove', 'modify')), 0),
           coalesce(sum(amount1) filter (where block_number > r.ext_floor_block and source <> 'positions' and kind in ('add', 'remove', 'modify')), 0),
           count(*)
      into l0, l1, nl from del;

    update pools
       set ext_base0 = ext_base0 + s0 + l0, ext_base1 = ext_base1 + s1 + l1,
           ext_live0 = ext_live0 - s0 - l0, ext_live1 = ext_live1 - s1 - l1,
           ext_floor_block = v_cut
     where chain_id = p_chain and pool_id = r.pool_id;

    tot_s := tot_s + ns;
    tot_l := tot_l + nl;
    n_pools := n_pools + 1;
  end loop;

  return jsonb_build_object('cut_block', v_cut, 'pools', n_pools, 'swaps', tot_s, 'liquidity_events', tot_l);
end;
$$;

revoke all on function public.aethra_prune_external(integer, interval, integer) from public, anon, authenticated;
revoke all on function public.aethra_backfill_ext_sums(integer, interval, boolean) from public, anon, authenticated;
grant execute on function public.aethra_prune_external(integer, interval, integer) to service_role;
grant execute on function public.aethra_backfill_ext_sums(integer, interval, boolean) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 3. pool_overview from a materialized view
-- ---------------------------------------------------------------------------------------------
-- Nothing heavy runs here: the materialized view is created empty and first filled by the pg_cron job below, which
-- then points pool_overview at it. (Filling it inline took over 40 minutes on the starved mainnet instance while
-- pool_overview was already renamed away, see B29.) Each step checks the current state, so a rerun after a cut
-- connection picks up where it stopped.
-- The dashboard views (SQL mirror of functions/_shared/ranking.ts, not read by the API) expanded `o.*` when they
-- were first created, so they are dropped and recreated with the current column list.
do $$
begin
  drop view if exists public.dashboard_trending, public.dashboard_established, public.dashboard_most_traded,
    public.dashboard_highest_volume, public.dashboard_fresh, public.dashboard_launch;

  -- pool_overview_live: the SQL of the view as it is now
  if to_regclass('public.pool_overview_live') is null then
    execute 'create view public.pool_overview_live with (security_invoker = true) as '
      || rtrim(pg_get_viewdef('public.pool_overview'::regclass), '; ' || chr(10));
  end if;
  -- an earlier run renamed pool_overview away: serve the live SQL until the materialized view is filled
  if to_regclass('public.pool_overview') is null then
    create view public.pool_overview with (security_invoker = true) as select * from public.pool_overview_live;
  end if;
  if to_regclass('public.pool_overview_mv') is null then
    create materialized view public.pool_overview_mv as select * from public.pool_overview_live with no data;
    create unique index pool_overview_mv_pk on public.pool_overview_mv (chain_id, pool_id);
  end if;
end
$$;

create view public.dashboard_trending with (security_invoker = true) as
select o.*, (o.trades_1h * (1 + log(1 + greatest(o.volume_1h_usd, 0))))::float8 as score
from public.pool_overview o
where o.enabled and o.trades_1h > 0;

create view public.dashboard_established with (security_invoker = true) as
select o.*, o.tvl_usd as score
from public.pool_overview o
where o.enabled and o.created_at < now() - interval '7 days' and o.tvl_usd > 0;

create view public.dashboard_most_traded with (security_invoker = true) as
select o.*, o.trades_24h::float8 as score
from public.pool_overview o
where o.enabled and o.trades_24h > 0;

create view public.dashboard_highest_volume with (security_invoker = true) as
select o.*, o.volume_24h_usd as score
from public.pool_overview o
where o.enabled and o.volume_24h_usd > 0;

create view public.dashboard_fresh with (security_invoker = true) as
select o.*, extract(epoch from o.created_at)::float8 as score
from public.pool_overview o
where o.enabled and o.is_fresh;

create view public.dashboard_launch with (security_invoker = true) as
select o.*, (o.volume_24h_usd * 1e6 + o.trades_24h)::float8 as score
from public.pool_overview o
where o.enabled and (o.venue = 'LAUNCH' or o.launch_token is not null);

revoke all on public.pool_overview_live, public.pool_overview_mv from anon, authenticated;
grant select on public.pool_overview_live, public.pool_overview_mv, public.pool_overview to service_role;
grant select on public.pool_overview_mv, public.pool_overview to anon, authenticated;
grant select on public.dashboard_trending, public.dashboard_established, public.dashboard_most_traded,
  public.dashboard_highest_volume, public.dashboard_fresh, public.dashboard_launch to anon, authenticated, service_role;

/**
 * pg_cron, every minute. Waits until the one-shot compaction (migration 20261101000002) has run, since the
 * overview is cheap only after it. The first run fills the materialized view and points pool_overview at it; later
 * runs refresh it concurrently, so readers keep the previous rows meanwhile.
 */
create or replace function public.aethra_refresh_overview()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- wait for the one-shot compaction: it leaves its result in db_health (cron.job hides other roles' jobs)
  if to_regclass('public.db_health') is not null then
    if not exists (select 1 from public.db_health where action is not null) then
      return;
    end if;
  end if;
  if not (select ispopulated from pg_matviews where schemaname = 'public' and matviewname = 'pool_overview_mv') then
    refresh materialized view public.pool_overview_mv;
    create or replace view public.pool_overview with (security_invoker = true) as select * from public.pool_overview_mv;
  else
    refresh materialized view concurrently public.pool_overview_mv;
  end if;
end;
$$;

revoke all on function public.aethra_refresh_overview() from public, anon, authenticated;
grant execute on function public.aethra_refresh_overview() to service_role;

-- ---------------------------------------------------------------------------------------------
-- 4. aethra_refresh: external reserves from the running sums, and no writes for unchanged rows
-- ---------------------------------------------------------------------------------------------
create or replace function public.aethra_refresh(p_chain integer, p_pools text[] default null, p_since timestamptz default null)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_pools text[];
  v_own text[];
  v_hook text;
  v_since timestamptz := coalesce(p_since, now() - interval '1 hour');
  v_hour timestamptz := date_trunc('hour', now());
  n_reserves int := 0;
  n_usd int := 0;
  n_stats int := 0;
  n_loans int := 0;
  n_positions int := 0;
begin
  v_pools := coalesce(p_pools, array(select pool_id from pools where chain_id = p_chain));
  select lower(addresses->>'hook') into v_hook from deployments where chain_id = p_chain;
  v_own := array(select pool_id from pools where chain_id = p_chain and not external and pool_id = any(v_pools));

  -- 1. reserves for event-sourced venues (V4, DLMM): liquidity adds/removes + swap deltas.
  --    Aethra pools are few and keep their full history, so they are summed from the event tables.
  with k as (select unnest(v_own) as pool_id),
  liq as (
    select l.pool_id, sum(l.amount0) as a0, sum(l.amount1) as a1
    from liquidity_events l
    where l.chain_id = p_chain and l.source <> 'positions' and l.kind in ('add', 'remove', 'modify')
      and l.pool_id = any(v_own)
    group by l.pool_id
  ),
  sw as (
    select s.pool_id, sum(s.delta0) as d0, sum(s.delta1) as d1
    from swaps s where s.chain_id = p_chain and s.pool_id = any(v_own)
    group by s.pool_id
  )
  update pools p
     set reserve0 = greatest(0, coalesce(liq.a0, 0) + coalesce(sw.d0, 0)),
         reserve1 = greatest(0, coalesce(liq.a1, 0) + coalesce(sw.d1, 0)),
         updated_at = now()
    from k
    left join liq on liq.pool_id = k.pool_id
    left join sw on sw.pool_id = k.pool_id
   where p.chain_id = p_chain and p.pool_id = k.pool_id and p.reserves_from_events
     and (p.reserve0, p.reserve1) is distinct from (greatest(0, coalesce(liq.a0, 0) + coalesce(sw.d0, 0)), greatest(0, coalesce(liq.a1, 0) + coalesce(sw.d1, 0)));
  get diagnostics n_reserves = row_count;

  --    External pools keep only recent events, so their reserves are running sums maintained on insert
  --    (aethra_ext_sums) plus the part already pruned (ext_base*). No event scan here.
  update pools p
     set reserve0 = greatest(0, p.ext_base0 + p.ext_live0),
         reserve1 = greatest(0, p.ext_base1 + p.ext_live1),
         updated_at = now()
   where p.chain_id = p_chain and p.external and p.ext_sums_ready and p.reserves_from_events and p.pool_id = any(v_pools)
     and (p.reserve0, p.reserve1) is distinct from (greatest(0, p.ext_base0 + p.ext_live0), greatest(0, p.ext_base1 + p.ext_live1));

  -- 2. pool mode: oracle when a side is a stock/RWA asset, plain for curves and non-Aethra v4 hooks
  update pools p set mode = m.mode, updated_at = now()
  from (
    select q.pool_id,
      case
        when q.venue = 'LAUNCH' then 'plain'
        when exists (
          select 1 from tokens t
          where t.chain_id = q.chain_id and t.address in (q.token0, q.token1)
            and (t.asset_class in ('STOCK', 'RWA') or t.kind in ('stock', 'rwa'))
        ) then 'oracle'
        when q.venue = 'V4' and (q.hooks is null or v_hook is null or q.hooks <> v_hook) then 'plain'
        else 'dynamic'
      end as mode
    from pools q where q.chain_id = p_chain
  ) m
  where p.chain_id = p_chain and p.pool_id = m.pool_id and p.mode <> m.mode;

  -- 3. USD backfill for recent swaps that were indexed before a price was known
  update swaps s
     set amount_usd = coalesce(
           case when ti.price_usd is not null then (s.amount_in / power(10::numeric, ti.decimals))::float8 * ti.price_usd end,
           case when tou.price_usd is not null then (s.amount_out / power(10::numeric, tou.decimals))::float8 * tou.price_usd end
         )
    from tokens ti, tokens tou
   where s.chain_id = p_chain and s.amount_usd is null and s.ts >= v_since - interval '1 hour'
     and ti.chain_id = s.chain_id and ti.address = s.token_in
     and tou.chain_id = s.chain_id and tou.address = s.token_out
     and (ti.price_usd is not null or tou.price_usd is not null);
  get diagnostics n_usd = row_count;

  update swaps s
     set fee_usd = s.amount_usd * (s.fee_amount / nullif(s.amount_in, 0))::float8
   where s.chain_id = p_chain and s.fee_usd is null and s.amount_usd is not null and s.ts >= v_since - interval '1 hour';

  -- 4. TVL from reserves and token prices (unpriced sides count as 0). External pools: only a side priced by a
  --    stable or an oracle counts, doubled when the other side is not trusted (a token priced by its own pool
  --    would otherwise inflate spam pools).
  update pools p set tvl_usd = v.tvl
  from (
    select q.pool_id,
      case when q.external then
        case
          when t0.price_source in ('stable', 'oracle') and t1.price_source in ('stable', 'oracle') then x.s0 + x.s1
          when t0.price_source in ('stable', 'oracle') then 2 * x.s0
          when t1.price_source in ('stable', 'oracle') then 2 * x.s1
          else 0
        end
      else x.s0 + x.s1 end as tvl
    from pools q
    left join tokens t0 on t0.chain_id = q.chain_id and t0.address = q.token0
    left join tokens t1 on t1.chain_id = q.chain_id and t1.address = q.token1
    cross join lateral (
      select coalesce((q.reserve0 / power(10::numeric, coalesce(t0.decimals, 18)))::float8 * t0.price_usd, 0) as s0,
             coalesce((q.reserve1 / power(10::numeric, coalesce(t1.decimals, 18)))::float8 * t1.price_usd, 0) as s1
    ) x
    where q.chain_id = p_chain
  ) v
  where p.chain_id = p_chain and p.pool_id = v.pool_id and p.tvl_usd is distinct from v.tvl;

  -- 5. hourly stats rebuilt from swaps for the touched pools and hours
  insert into pool_stats_hourly as h
    (chain_id, pool_id, hour, volume_usd, volume0, volume1, trades, fees_usd, open_price, close_price, high_price, low_price, updated_at)
  select s.chain_id, s.pool_id, date_trunc('hour', s.ts),
         coalesce(sum(s.amount_usd), 0), sum(abs(s.delta0)), sum(abs(s.delta1)), count(*), coalesce(sum(s.fee_usd), 0),
         (array_agg(s.price order by s.block_number, s.log_index) filter (where s.price is not null))[1],
         (array_agg(s.price order by s.block_number desc, s.log_index desc) filter (where s.price is not null))[1],
         max(s.price), min(s.price), now()
  from swaps s
  where s.chain_id = p_chain and s.pool_id = any(v_pools) and s.ts >= date_trunc('hour', v_since)
  group by s.chain_id, s.pool_id, date_trunc('hour', s.ts)
  on conflict (chain_id, pool_id, hour) do update
    set volume_usd = excluded.volume_usd, volume0 = excluded.volume0, volume1 = excluded.volume1,
        trades = excluded.trades, fees_usd = excluded.fees_usd, open_price = excluded.open_price,
        close_price = excluded.close_price, high_price = excluded.high_price, low_price = excluded.low_price,
        updated_at = now();
  get diagnostics n_stats = row_count;

  -- current-hour snapshot for every pool: TVL and latest pool price (keeps TVL series and sparklines continuous)
  insert into pool_stats_hourly as h (chain_id, pool_id, hour, tvl_usd, open_price, close_price, high_price, low_price, updated_at)
  select chain_id, pool_id, v_hour, tvl_usd, price, price, price, price, now()
  from pools where chain_id = p_chain
  on conflict (chain_id, pool_id, hour) do update
    set tvl_usd = excluded.tvl_usd,
        close_price = coalesce(excluded.close_price, h.close_price),
        open_price = coalesce(h.open_price, excluded.open_price),
        high_price = greatest(h.high_price, excluded.high_price),
        low_price = least(h.low_price, excluded.low_price),
        updated_at = now()
    -- skip rows that would not change: this upsert runs for every pool on every run
    where (h.tvl_usd, h.close_price, h.high_price, h.low_price) is distinct from
          (excluded.tvl_usd, coalesce(excluded.close_price, h.close_price), greatest(h.high_price, excluded.high_price), least(h.low_price, excluded.low_price));

  -- 6. loans: state since the latest Pledged event of each position NFT
  insert into loans as ln (chain_id, token_id, owner, status, borrowed, repaid, principal_outstanding,
                           liquidated_by, liquidation_debt, liquidation_value_usd, pledged_at, last_event_at, updated_at)
  select p_chain, lp.token_id, lp.account,
         case when a.liquidated then 'liquidated' when a.released then 'released' else 'pledged' end,
         a.borrowed, a.repaid,
         case when a.liquidated then 0 else greatest(0, a.borrowed - a.repaid) end,
         a.liq_by, a.liq_debt, a.liq_value, lp.ts, coalesce(a.last_ts, lp.ts), now()
  from (
    select distinct on (token_id) token_id, account, block_number, log_index, ts
    from vault_events
    where chain_id = p_chain and source = 'credit' and kind = 'Pledged'
    order by token_id, block_number desc, log_index desc
  ) lp
  cross join lateral (
    select coalesce(sum(e.assets) filter (where e.kind = 'Borrow'), 0) as borrowed,
           coalesce(sum(e.assets) filter (where e.kind = 'Repay'), 0) as repaid,
           coalesce(bool_or(e.kind = 'Released'), false) as released,
           coalesce(bool_or(e.kind = 'Liquidated'), false) as liquidated,
           max(e.counterparty) filter (where e.kind = 'Liquidated') as liq_by,
           max(e.assets) filter (where e.kind = 'Liquidated') as liq_debt,
           max(((e.extra->>'collateral_value_usd_e18')::numeric / 1e18)::float8) filter (where e.kind = 'Liquidated') as liq_value,
           max(e.ts) as last_ts
    from vault_events e
    where e.chain_id = p_chain and e.source = 'credit' and e.token_id = lp.token_id
      and (e.block_number, e.log_index) > (lp.block_number, lp.log_index)
  ) a
  on conflict (chain_id, token_id) do update
    set owner = excluded.owner, status = excluded.status, borrowed = excluded.borrowed, repaid = excluded.repaid,
        principal_outstanding = excluded.principal_outstanding, liquidated_by = excluded.liquidated_by,
        liquidation_debt = excluded.liquidation_debt, liquidation_value_usd = excluded.liquidation_value_usd,
        pledged_at = excluded.pledged_at, last_event_at = excluded.last_event_at, updated_at = now()
    where (ln.owner, ln.status, ln.borrowed, ln.repaid, ln.last_event_at)
          is distinct from (excluded.owner, excluded.status, excluded.borrowed, excluded.repaid, excluded.last_event_at);
  get diagnostics n_loans = row_count;

  -- 7. position NFTs: liquidity and collected fees from the positions contract events
  update positions pos
     set liquidity = greatest(0, x.l), fees0_collected = x.f0, fees1_collected = x.f1, updated_at = now()
    from (
      select token_id,
             coalesce(sum(liquidity_delta) filter (where kind in ('add', 'remove')), 0) as l,
             coalesce(sum(amount0) filter (where kind = 'collect'), 0) as f0,
             coalesce(sum(amount1) filter (where kind = 'collect'), 0) as f1
      from liquidity_events
      where chain_id = p_chain and source = 'positions'
        and token_id in (
          select token_id from liquidity_events
          where chain_id = p_chain and source = 'positions' and ts >= v_since - interval '1 hour'
        )
      group by token_id
    ) x
   where pos.chain_id = p_chain and pos.token_id = x.token_id;
  get diagnostics n_positions = row_count;

  return jsonb_build_object(
    'pools', coalesce(array_length(v_pools, 1), 0), 'reserves', n_reserves, 'usd_backfilled', n_usd,
    'stats_rows', n_stats, 'loans', n_loans, 'positions', n_positions
  );
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. schedules
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from cron.job where jobname = 'aethra-overview') then
    perform cron.unschedule('aethra-overview');
  end if;
  perform cron.schedule('aethra-overview', '* * * * *', 'select public.aethra_refresh_overview()');

  -- sums of external pools that existed before this migration, a few per minute; a no-op once all are ready
  if exists (select 1 from cron.job where jobname = 'aethra-ext-backfill') then
    perform cron.unschedule('aethra-ext-backfill');
  end if;
  perform cron.schedule('aethra-ext-backfill', '* * * * *',
    $job$select public.aethra_backfill_ext_sums(chain_id) from public.chains where enabled$job$);

  if exists (select 1 from cron.job where jobname = 'aethra-prune') then
    perform cron.unschedule('aethra-prune');
  end if;
  perform cron.schedule('aethra-prune', '*/10 * * * *',
    $job$select public.aethra_prune_external(chain_id) from public.chains where enabled$job$);

  -- run history: one row per job per minute adds up; keep a day
  if exists (select 1 from cron.job where jobname = 'aethra-housekeeping') then
    perform cron.unschedule('aethra-housekeeping');
  end if;
  perform cron.schedule('aethra-housekeeping', '17 * * * *',
    $job$delete from cron.job_run_details where end_time < now() - interval '1 day'$job$);
end
$$;
