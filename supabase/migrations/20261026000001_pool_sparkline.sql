-- Pool sparklines: 24 hourly points per pool with the last known close carried forward (the old view only
-- returned hours that had a stats row, so quiet pools drew one or two points), plus hourly volume.
-- Columns are only appended, so `create or replace` keeps the dependent dashboard views valid.

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
  coalesce(vspark.points, '{}'::float8[]) as volume_sparkline
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
