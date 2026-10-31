-- External pools: Uniswap v4 pools that do not use the Aethra hook, shown read-only next to Aethra's own.
-- A discovery pass in the indexer picks the most active ones (see functions/indexer/discover.ts); the indexer then
-- replays their Swap / ModifyLiquidity events from creation, so reserves, TVL and volume use the same path as
-- Aethra pools. `ext_synced_block` marks how far that replay has caught up (null = not started).
-- Aethra's own totals (analytics, event feed) exclude them, so the numbers keep meaning "Aethra".

alter table public.pools
  add column external boolean not null default false,
  add column ext_synced_block bigint;

create index pools_external_idx on public.pools (chain_id) where external;

-- pool_overview: `external` is appended, so create or replace keeps the dashboard views valid
create or replace view public.pool_overview with (security_invoker = true) as
select
  p.chain_id,
  p.pool_id,
  p.venue,
  p.pool_address,
  p.hooks,
  p.hub_pool_id,
  p.registered,
  jsonb_build_object(
    'address', p.token0, 'symbol', coalesce(t0.symbol, '?'), 'name', coalesce(t0.name, ''),
    'decimals', coalesce(t0.decimals, 18), 'kind', coalesce(t0.kind, 'unknown'),
    'logo_url', t0.logo_url, 'price_usd', t0.price_usd
  ) as token0,
  jsonb_build_object(
    'address', p.token1, 'symbol', coalesce(t1.symbol, '?'), 'name', coalesce(t1.name, ''),
    'decimals', coalesce(t1.decimals, 18), 'kind', coalesce(t1.kind, 'unknown'),
    'logo_url', t1.logo_url, 'price_usd', t1.price_usd
  ) as token1,
  p.fee_pips,
  p.dynamic_fee,
  p.tick_spacing,
  p.bin_step_bps,
  p.active_index,
  p.sqrt_price_x96::text as sqrt_price_x96,
  p.liquidity::text      as liquidity,
  p.reserve0::text       as reserve0,
  p.reserve1::text       as reserve1,
  p.price,
  p.mode,
  p.creator,
  p.enabled,
  p.launch_token,
  coalesce(p.tvl_usd, 0)::float8          as tvl_usd,
  coalesce(s24.volume_usd, 0)::float8     as volume_24h_usd,
  coalesce(s24.trades, 0)::int            as trades_24h,
  coalesce(s24.fees_usd, 0)::float8       as fees_24h_usd,
  coalesce(s1.volume_usd, 0)::float8      as volume_1h_usd,
  coalesce(s1.trades, 0)::int             as trades_1h,
  case
    when p.price is not null and base.price > 0 then ((p.price - base.price) / base.price * 100)::float8
    else 0::float8
  end                                     as price_change_24h,
  coalesce(spark.points, '{}'::float8[])  as sparkline,
  (p.created_at > now() - interval '72 hours') as is_fresh,
  p.created_at,
  p.created_block,
  p.updated_at,
  coalesce(vspark.points, '{}'::float8[]) as volume_sparkline,
  p.external
from public.pools p
left join public.tokens t0 on t0.chain_id = p.chain_id and t0.address = p.token0
left join public.tokens t1 on t1.chain_id = p.chain_id and t1.address = p.token1
left join lateral (
  select count(*) as trades, sum(s.amount_usd) as volume_usd, sum(s.fee_usd) as fees_usd
  from public.swaps s
  where s.chain_id = p.chain_id and s.pool_id = p.pool_id and s.ts > now() - interval '24 hours'
) s24 on true
left join lateral (
  select count(*) as trades, sum(s.amount_usd) as volume_usd
  from public.swaps s
  where s.chain_id = p.chain_id and s.pool_id = p.pool_id and s.ts > now() - interval '1 hour'
) s1 on true
left join lateral (
  select coalesce(
    (select h.close_price from public.pool_stats_hourly h
      where h.chain_id = p.chain_id and h.pool_id = p.pool_id and h.close_price is not null
        and h.hour <= now() - interval '24 hours'
      order by h.hour desc limit 1),
    (select h.open_price from public.pool_stats_hourly h
      where h.chain_id = p.chain_id and h.pool_id = p.pool_id and h.open_price is not null
        and h.hour > now() - interval '24 hours'
      order by h.hour asc limit 1)
  ) as price
) base on true
left join lateral (
  -- 24 hourly points, each carrying the last known close forward so quiet hours still draw a continuous line
  select array_agg(pt.price order by pt.hour)::float8[] as points
  from (
    select g.hour,
      (select h.close_price from public.pool_stats_hourly h
        where h.chain_id = p.chain_id and h.pool_id = p.pool_id and h.close_price is not null and h.hour <= g.hour
        order by h.hour desc limit 1) as price
    from generate_series(date_trunc('hour', now()) - interval '23 hours', date_trunc('hour', now()), interval '1 hour') as g(hour)
  ) pt
  where pt.price is not null
) spark on true
left join lateral (
  select array_agg(coalesce(h.volume_usd, 0) order by g.hour)::float8[] as points
  from generate_series(date_trunc('hour', now()) - interval '23 hours', date_trunc('hour', now()), interval '1 hour') as g(hour)
  left join public.pool_stats_hourly h on h.chain_id = p.chain_id and h.pool_id = p.pool_id and h.hour = g.hour
) vspark on true;

-- event feed: Aethra activity only (event_feed_all keeps external pools for their own pages)
create or replace view public.event_feed_all with (security_invoker = true) as
select s.chain_id, 'swap'::text as type, 'swap'::text as action, s.pool_id, s.tx_hash, s.log_index,
       s.block_number, s.ts, s.sender as account,
       jsonb_build_object(
         'venue', s.venue, 'sender', s.sender, 'recipient', s.recipient,
         'token_in', s.token_in, 'token_out', s.token_out,
         'amount_in', s.amount_in::text, 'amount_out', s.amount_out::text,
         'fee_amount', s.fee_amount::text, 'amount_usd', s.amount_usd, 'price', s.price
       ) as data
from public.swaps s
union all
select l.chain_id, 'liquidity', l.kind, l.pool_id, l.tx_hash, l.log_index, l.block_number, l.ts,
       coalesce(l.recipient, l.sender),
       jsonb_build_object(
         'venue', l.venue, 'source', l.source, 'sender', l.sender, 'recipient', l.recipient,
         'token_id', l.token_id::text, 'tick_lower', l.tick_lower, 'tick_upper', l.tick_upper,
         'bin_ids', l.bin_ids, 'liquidity_delta', l.liquidity_delta::text, 'shares', l.shares::text,
         'amount0', l.amount0::text, 'amount1', l.amount1::text, 'amount_usd', l.amount_usd
       )
from public.liquidity_events l
where l.source <> 'positions' or l.kind = 'collect'
union all
select la.chain_id, 'launch', 'created', la.token, la.created_tx, la.created_log_index, la.created_block,
       la.created_at, la.creator,
       jsonb_build_object('token', la.token, 'name', la.name, 'symbol', la.symbol, 'metadata_uri', la.metadata_uri)
from public.launches la
union all
select la.chain_id, 'launch', 'graduated', la.token, la.graduated_tx, la.graduated_log_index, la.graduated_block,
       la.graduated_at, la.creator,
       jsonb_build_object('token', la.token, 'symbol', la.symbol, 'v4_pool_id', la.v4_pool_id,
                          'position_id', la.position_id::text, 'weth_liquidity', la.graduation_weth::text,
                          'token_liquidity', la.graduation_tokens::text)
from public.launches la
where la.graduated and la.graduated_tx is not null
union all
select o.chain_id, 'order', 'placed', o.pool_id, o.placed_tx, o.placed_log_index, o.placed_block, o.placed_at, o.owner,
       jsonb_build_object('order_id', o.order_id::text, 'pool_address', o.pool_address, 'bin_id', o.bin_id,
                          'side', o.side, 'amount_in', o.amount_in::text)
from public.limit_orders o
union all
select o.chain_id, 'order', o.status, o.pool_id, o.closed_tx, o.closed_log_index, o.closed_block, o.closed_at, o.owner,
       jsonb_build_object('order_id', o.order_id::text, 'pool_address', o.pool_address, 'bin_id', o.bin_id,
                          'side', o.side, 'amount0', o.returned0::text, 'amount1', o.returned1::text)
from public.limit_orders o
where o.closed_tx is not null
union all
select v.chain_id, case when v.source = 'credit' then 'loan' else 'vault' end, lower(v.kind), null::text,
       v.tx_hash, v.log_index, v.block_number, v.ts, v.account,
       jsonb_build_object('source', v.source, 'kind', v.kind, 'token_id', v.token_id::text, 'account', v.account,
                          'counterparty', v.counterparty, 'assets', v.assets::text, 'shares', v.shares::text) || v.extra
from public.vault_events v
union all
select b.chain_id, 'buyback', b.kind, null::text, b.tx_hash, b.log_index, b.block_number, b.ts, b.from_address,
       jsonb_build_object('token', b.token, 'amount', b.amount::text, 'aeth_bought', b.aeth_bought::text,
                          'aeth_burned', b.aeth_burned::text, 'to_treasury', b.to_treasury::text, 'amount_usd', b.amount_usd)
from public.buybacks b
union all
select r.chain_id, 'route', 'executed', null::text, r.tx_hash, r.log_index, r.block_number, r.ts, r.sender,
       jsonb_build_object('sender', r.sender, 'recipient', r.recipient, 'token_in', r.token_in, 'token_out', r.token_out,
                          'amount_in', r.amount_in::text, 'amount_out', r.amount_out::text, 'hops', r.hops,
                          'amount_usd', r.amount_usd)
from public.route_executions r;

create or replace view public.event_feed with (security_invoker = true) as
select f.* from public.event_feed_all f
where f.pool_id is null or not exists (select 1 from public.pools xp where xp.chain_id = f.chain_id and xp.pool_id = f.pool_id and xp.external);

-- analytics: Aethra pools only
create or replace function public.api_analytics(p_chain integer, p_range text default '24h')
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_range text := case when p_range in ('24h', '7d', '30d') then p_range else '24h' end;
  v_interval interval;
  v_bucket interval;
  v_origin timestamptz := timestamptz '2000-01-01 00:00:00+00';
  v_first timestamptz;
  v_last timestamptz;
  v_from timestamptz;
  v_result jsonb;
begin
  if v_range = '7d' then
    v_interval := interval '7 days'; v_bucket := interval '6 hours';
  elsif v_range = '30d' then
    v_interval := interval '30 days'; v_bucket := interval '1 day';
  else
    v_interval := interval '24 hours'; v_bucket := interval '1 hour';
  end if;
  v_last := date_bin(v_bucket, now(), v_origin);
  v_first := date_bin(v_bucket, now() - v_interval + v_bucket, v_origin);
  v_from := now() - v_interval;

  with buckets as (
    select generate_series(v_first, v_last, v_bucket) as t
  ),
  own as (
    select pool_id from pools where chain_id = p_chain and not external
  ),
  series as (
    select b.t,
           coalesce(sum(h.volume_usd), 0)::float8 as volume_usd,
           coalesce(sum(h.fees_usd), 0)::float8 as fees_usd,
           coalesce(sum(h.trades), 0)::int as trades,
           coalesce((
             select sum(x.tvl) from (
               select distinct on (h2.pool_id) h2.tvl_usd as tvl
               from pool_stats_hourly h2
               where h2.chain_id = p_chain and h2.hour < b.t + v_bucket and h2.tvl_usd is not null and h2.pool_id in (select pool_id from own)
               order by h2.pool_id, h2.hour desc
             ) x
           ), 0)::float8 as tvl_usd
    from buckets b
    left join pool_stats_hourly h on h.chain_id = p_chain and h.hour >= b.t and h.hour < b.t + v_bucket and h.pool_id in (select pool_id from own)
    group by b.t
  ),
  range_swaps as (
    select s.* from swaps s where s.chain_id = p_chain and s.ts > v_from and s.pool_id in (select pool_id from own)
  ),
  venues as (
    select p.venue,
           count(distinct p.pool_id)::int as pools,
           coalesce(sum(p.tvl_usd), 0)::float8 as tvl_usd,
           coalesce(sum(rs.volume_usd), 0)::float8 as volume_usd,
           coalesce(sum(rs.trades), 0)::int as trades
    from pools p
    left join (
      select pool_id, sum(amount_usd) as volume_usd, count(*) as trades from range_swaps group by pool_id
    ) rs on rs.pool_id = p.pool_id
    where p.chain_id = p_chain and not p.external
    group by p.venue
  ),
  top as (
    select p.pool_id, p.venue, coalesce(t0.symbol, '?') as symbol0, coalesce(t1.symbol, '?') as symbol1,
           p.fee_pips, p.tvl_usd::float8 as tvl_usd,
           coalesce(rs.volume_usd, 0)::float8 as volume_usd, coalesce(rs.fees_usd, 0)::float8 as fees_usd,
           coalesce(rs.trades, 0)::int as trades
    from pools p
    left join tokens t0 on t0.chain_id = p.chain_id and t0.address = p.token0
    left join tokens t1 on t1.chain_id = p.chain_id and t1.address = p.token1
    left join (
      select pool_id, sum(amount_usd) as volume_usd, sum(fee_usd) as fees_usd, count(*) as trades
      from range_swaps group by pool_id
    ) rs on rs.pool_id = p.pool_id
    where p.chain_id = p_chain and p.enabled and not p.external
    order by coalesce(rs.volume_usd, 0) desc, p.tvl_usd desc, coalesce(rs.trades, 0) desc
    limit 10
  )
  select jsonb_build_object(
    'chain_id', p_chain,
    'range', v_range,
    'bucket_seconds', extract(epoch from v_bucket)::int,
    'timestamp', now(),
    'totals', jsonb_build_object(
      'tvl_usd', (select coalesce(sum(tvl_usd), 0)::float8 from pools where chain_id = p_chain and enabled and not external),
      'volume_usd', (select coalesce(sum(amount_usd), 0)::float8 from range_swaps),
      'fees_usd', (select coalesce(sum(fee_usd), 0)::float8 from range_swaps),
      'trades', (select count(*)::int from range_swaps),
      'traders', (select count(distinct sender)::int from range_swaps),
      'pools', (select count(*)::int from pools where chain_id = p_chain and enabled and not external)
    ),
    'series', coalesce((select jsonb_agg(jsonb_build_object(
        'timestamp', t, 'volume_usd', volume_usd, 'fees_usd', fees_usd, 'trades', trades, 'tvl_usd', tvl_usd
      ) order by t) from series), '[]'::jsonb),
    'venues', coalesce((select jsonb_agg(to_jsonb(venues) order by volume_usd desc, tvl_usd desc) from venues), '[]'::jsonb),
    'top_pools', coalesce((select jsonb_agg(to_jsonb(top)) from top), '[]'::jsonb),
    'buyback', jsonb_build_object(
      'executions', (select count(*)::int from buybacks where chain_id = p_chain and kind = 'buyback' and ts > v_from),
      'revenue_events', (select count(*)::int from buybacks where chain_id = p_chain and kind = 'revenue' and ts > v_from),
      'aeth_burned', (select coalesce(sum(aeth_burned), 0)::text from buybacks where chain_id = p_chain and kind = 'buyback' and ts > v_from)
    )
  ) into v_result;

  return v_result;
end;
$$;

-- refresh: external TVL counts trusted sides only
create or replace function public.aethra_refresh(p_chain integer, p_pools text[] default null, p_since timestamptz default null)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_pools text[];
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

  -- 1. reserves for event-sourced venues (V4, DLMM): liquidity adds/removes + swap deltas
  with k as (select unnest(v_pools) as pool_id),
  liq as (
    select l.pool_id, sum(l.amount0) as a0, sum(l.amount1) as a1
    from liquidity_events l
    where l.chain_id = p_chain and l.source <> 'positions' and l.kind in ('add', 'remove', 'modify')
      and l.pool_id = any(v_pools)
    group by l.pool_id
  ),
  sw as (
    select s.pool_id, sum(s.delta0) as d0, sum(s.delta1) as d1
    from swaps s where s.chain_id = p_chain and s.pool_id = any(v_pools)
    group by s.pool_id
  )
  update pools p
     set reserve0 = greatest(0, coalesce(liq.a0, 0) + coalesce(sw.d0, 0)),
         reserve1 = greatest(0, coalesce(liq.a1, 0) + coalesce(sw.d1, 0)),
         updated_at = now()
    from k
    left join liq on liq.pool_id = k.pool_id
    left join sw on sw.pool_id = k.pool_id
   where p.chain_id = p_chain and p.pool_id = k.pool_id and p.reserves_from_events;
  get diagnostics n_reserves = row_count;

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
        updated_at = now();

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

grant execute on function public.api_analytics(integer, text) to anon, authenticated, service_role;
grant select on public.pool_overview, public.event_feed, public.event_feed_all to anon, authenticated, service_role;
