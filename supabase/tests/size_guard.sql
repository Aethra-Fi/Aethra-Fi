-- Size guard migration (20261101000002): aethra_compact keeps the top external pools and folds their history into ext_base*.
-- Run against local Supabase: psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/size_guard.sql
-- Everything runs in one transaction and is rolled back.
begin;
insert into chains (chain_id, name, network, rpc_url, external_max) values (999, 'test', 'local', 'http://x', 1);
insert into pools (chain_id, pool_id, venue, token0, token1, external, ext_synced_block, tvl_usd) values
  (999, '0xbig', 'V4', '0xa', '0xb', true, 900, 100), (999, '0xsmall', 'V4', '0xa', '0xb', true, 900, 1),
  (999, '0xown', 'V4', '0xa', '0xb', false, null, 5);
insert into liquidity_events (chain_id, tx_hash, log_index, block_number, ts, pool_id, venue, source, kind, amount0, amount1) values
  (999, '0xl1', 0, 10, now() - interval '30 days', '0xbig', 'V4', 'v4', 'add', 1000, 2000),
  (999, '0xl2', 0, 10, now() - interval '30 days', '0xsmall', 'V4', 'v4', 'add', 10, 20),
  (999, '0xl3', 0, 10, now() - interval '30 days', '0xown', 'V4', 'v4', 'add', 500, 500);
insert into swaps (chain_id, tx_hash, log_index, block_number, ts, pool_id, venue, sender, recipient, token_in, token_out, amount_in, amount_out, delta0, delta1) values
  (999, '0xs1', 0, 20, now() - interval '20 days', '0xbig', 'V4', 's', 'r', '0xa', '0xb', 100, 150, 100, -150),
  (999, '0xs2', 0, 900, now() - interval '1 day', '0xbig', 'V4', 's', 'r', '0xb', '0xa', 50, 30, -30, 50),
  (999, '0xs3', 0, 30, now() - interval '20 days', '0xown', 'V4', 's', 'r', '0xa', '0xb', 10, 10, 10, -10),
  (999, '0xs4', 0, 40, now() - interval '20 days', '0xsmall', 'V4', 's', 'r', '0xa', '0xb', 1, 1, 1, -1);
select 'compact' t, aethra_compact(999) - 'db_bytes_before' - 'at';
select 'pools left (0xbig, 0xown)' t, string_agg(pool_id, ',' order by pool_id) from pools where chain_id = 999;
select 'big sums (base 1070/1900, live 0, floor 900)' t, ext_base0, ext_base1, ext_live0, ext_live1, ext_floor_block, ext_sums_ready from pools where pool_id = '0xbig';
select 'rows left (swaps: 0xs2 0xs3; liq: 0xl3)' t, (select string_agg(tx_hash, ' ' order by tx_hash) from swaps where chain_id = 999), (select string_agg(tx_hash, ' ' order by tx_hash) from liquidity_events where chain_id = 999);
select aethra_refresh(999);
select 'reserves (big 1070/1900, own 510/490)' t, pool_id, reserve0, reserve1 from pools where chain_id = 999 order by pool_id;
-- a new event is counted; a re-scan of an old (pruned) one is not
insert into swaps (chain_id, tx_hash, log_index, block_number, ts, pool_id, venue, sender, recipient, token_in, token_out, amount_in, amount_out, delta0, delta1) values
  (999, '0xs5', 0, 950, now(), '0xbig', 'V4', 's', 'r', '0xa', '0xb', 5, 5, 5, -5),
  (999, '0xs1', 0, 20, now() - interval '20 days', '0xbig', 'V4', 's', 'r', '0xa', '0xb', 100, 150, 100, -150);
select aethra_refresh(999);
select 'after new event (big 1075/1895)' t, reserve0, reserve1 from pools where pool_id = '0xbig';
select 'compact again keeps the totals (1075/1895)' t, (aethra_compact(999) ->> 'kept_external') kept;
select aethra_refresh(999);
select 'after second compact (big 1075/1895)' t, reserve0, reserve1, ext_live0 from pools where pool_id = '0xbig';
select 'size guard' t, (aethra_size_guard() ? 'db_bytes') ok, (select db_bytes > 0 from db_health);
rollback;
