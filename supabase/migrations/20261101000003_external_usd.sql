-- External pools showed impossible USD volumes ($4.5B in 24h on a pool with $3M TVL). Their swaps had been valued
-- through tokens that are not trustworthy: a look-alike "USDG" priced at $1 by its symbol, and tokens priced from
-- their own pools. The indexer now values external swaps only through a side priced by a stable or an oracle (the
-- rule their TVL already used); this one-shot job re-values the stored external swaps the same way and rebuilds
-- their hourly stats. Aethra's own pools are not touched.

set lock_timeout = '10s';
set statement_timeout = '120s';

create or replace function public.aethra_fix_external_usd()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_ids text[];
  n_swaps bigint := 0;
  n bigint;
  v_since timestamptz;
begin
  perform cron.unschedule('aethra-fix-external-usd');
  for r in select chain_id from chains where enabled loop
    v_ids := array(select pool_id from pools where chain_id = r.chain_id and external);
    continue when coalesce(array_length(v_ids, 1), 0) = 0;

    update swaps s
       set amount_usd = coalesce(
             case when ti.price_source in ('stable', 'oracle') then (s.amount_in / power(10::numeric, ti.decimals))::float8 * ti.price_usd end,
             case when tou.price_source in ('stable', 'oracle') then (s.amount_out / power(10::numeric, tou.decimals))::float8 * tou.price_usd end,
             0),
           fee_usd = null
      from tokens ti, tokens tou
     where s.chain_id = r.chain_id and s.pool_id = any(v_ids)
       and ti.chain_id = s.chain_id and ti.address = s.token_in
       and tou.chain_id = s.chain_id and tou.address = s.token_out;
    get diagnostics n = row_count;
    n_swaps := n_swaps + n;

    update swaps s
       set fee_usd = s.amount_usd * (s.fee_amount / nullif(s.amount_in, 0))::float8
     where s.chain_id = r.chain_id and s.pool_id = any(v_ids) and s.fee_usd is null;

    -- rebuild the hourly stats of every stored hour (aethra_refresh step 5). Older hours were built from swaps that
    -- are pruned now and cannot be re-valued: their USD volume and fees are cleared (prices and TVL stay).
    select min(ts) into v_since from swaps where chain_id = r.chain_id and pool_id = any(v_ids);
    if v_since is not null then
      perform public.aethra_refresh(r.chain_id, v_ids, v_since);
    end if;
    update pool_stats_hourly h
       set volume_usd = 0, fees_usd = 0
     where h.chain_id = r.chain_id and h.pool_id = any(v_ids)
       and h.hour < date_trunc('hour', coalesce(v_since, now()))
       and (h.volume_usd <> 0 or h.fees_usd <> 0);
  end loop;
  return jsonb_build_object('swaps_revalued', n_swaps, 'at', now());
end;
$$;

revoke all on function public.aethra_fix_external_usd() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'aethra-fix-external-usd') then
    perform cron.unschedule('aethra-fix-external-usd');
  end if;
  perform cron.schedule('aethra-fix-external-usd', '* * * * *', 'set statement_timeout = 0; select public.aethra_fix_external_usd()');
end
$$;
