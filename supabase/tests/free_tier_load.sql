-- Free-tier load migration (20261101000001): running sums, prune and overview refresh for external pools.
-- Run against local Supabase: psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/free_tier_load.sql
-- Everything runs in one transaction and is rolled back.
begin;
-- a pending one-shot compaction makes the backfill wait; take it out of the picture for this test
select cron.unschedule('aethra-compact-once') from cron.job where jobname = 'aethra-compact-once';
insert into chains (chain_id, name, network, rpc_url) values (999, 'test', 'local', 'http://x');
insert into pools (chain_id, pool_id, venue, token0, token1, external, ext_synced_block) values
  (999, '0xext', 'V4', '0xa', '0xb', true, 5000), (999, '0xown', 'V4', '0xa', '0xb', false, null);
insert into liquidity_events (chain_id, tx_hash, log_index, block_number, ts, pool_id, venue, source, kind, amount0, amount1) values
  (999, '0x1', 0, 10, now() - interval '30 days', '0xext', 'V4', 'v4', 'add', 1000, 2000),
  (999, '0x1o', 0, 10, now() - interval '30 days', '0xown', 'V4', 'v4', 'add', 1000, 2000);
insert into swaps (chain_id, tx_hash, log_index, block_number, ts, pool_id, venue, sender, recipient, token_in, token_out, amount_in, amount_out, delta0, delta1) values
  (999, '0x2', 0, 20, now() - interval '20 days', '0xext', 'V4', 's', 'r', '0xa', '0xb', 100, 150, 100, -150),
  (999, '0x3', 0, 900, now() - interval '1 day', '0xext', 'V4', 's', 'r', '0xb', '0xa', 50, 30, -30, 50),
  (999, '0x2o', 0, 20, now() - interval '20 days', '0xown', 'V4', 's', 'r', '0xa', '0xb', 100, 150, 100, -150);
insert into swaps (chain_id, tx_hash, log_index, block_number, ts, pool_id, venue, sender, recipient, token_in, token_out, amount_in, amount_out, delta0, delta1)
  values (999, '0x2', 0, 20, now() - interval '20 days', '0xext', 'V4', 's', 'r', '0xa', '0xb', 100, 150, 100, -150) on conflict do nothing;
select 'live after insert (expect 1070 1900)' t, ext_live0, ext_live1, ext_base0, ext_floor_block from pools where pool_id='0xext';
select 'not ready: refresh keeps reserves (expect 0/0)' t, aethra_refresh(999), (select reserve0 from pools where pool_id='0xext') r0;
select 'backfill' t, aethra_backfill_ext_sums(999);
select 'refresh' t, aethra_refresh(999);
select 'reserves (both expect 1070/1900, own 1100/1850)' t, pool_id, reserve0, reserve1 from pools where chain_id=999 order by pool_id;
select 'prune' t, aethra_prune_external(999, interval '7 days', 10);
select 'after prune (live -30/50, base 1100/1850, floor 20)' t, ext_live0, ext_live1, ext_base0, ext_base1, ext_floor_block from pools where pool_id='0xext';
select 'rows left (1,0,1)' t, (select count(*) from swaps where chain_id=999 and pool_id='0xext') swaps, (select count(*) from liquidity_events where chain_id=999 and pool_id='0xext') liq, (select count(*) from swaps where chain_id=999 and pool_id='0xown') own_swaps;
insert into swaps (chain_id, tx_hash, log_index, block_number, ts, pool_id, venue, sender, recipient, token_in, token_out, amount_in, amount_out, delta0, delta1)
  values (999, '0x2', 0, 20, now() - interval '20 days', '0xext', 'V4', 's', 'r', '0xa', '0xb', 100, 150, 100, -150) on conflict do nothing;
select 'rebuild' t, aethra_backfill_ext_sums(999, interval '15 seconds', true);
select aethra_refresh(999);
select 'reserves after rewind+rebuild (ext 1070/1900)' t, pool_id, reserve0, reserve1 from pools where chain_id=999 order by pool_id;
select aethra_refresh_overview();
select 'overview' t, pool_id, trades_24h, external from pool_overview where chain_id=999 order by pool_id;
rollback;
