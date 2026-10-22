-- Aethra Fi indexer: indexes for the API queries + row level security.

-- pools: lookups by address / hub id, venue filter, freshness, token search
create index pools_address_idx      on public.pools (chain_id, pool_address);
create index pools_hub_id_idx       on public.pools (chain_id, hub_pool_id);
create index pools_venue_idx        on public.pools (chain_id, venue);
create index pools_created_idx      on public.pools (chain_id, created_at desc);
create index pools_token0_idx       on public.pools (chain_id, token0);
create index pools_token1_idx       on public.pools (chain_id, token1);
create index pools_launch_token_idx on public.pools (chain_id, launch_token) where launch_token is not null;

create index tokens_symbol_idx on public.tokens (chain_id, lower(symbol));

-- event feeds: newest first, per chain and per pool
create index swaps_feed_idx       on public.swaps (chain_id, block_number desc, log_index desc);
create index swaps_pool_ts_idx    on public.swaps (chain_id, pool_id, ts desc);
create index swaps_ts_idx         on public.swaps (chain_id, ts desc);
create index swaps_sender_idx     on public.swaps (chain_id, sender);

create index liq_feed_idx         on public.liquidity_events (chain_id, block_number desc, log_index desc);
create index liq_pool_idx         on public.liquidity_events (chain_id, pool_id, block_number desc);
create index liq_token_id_idx     on public.liquidity_events (chain_id, token_id) where token_id is not null;
create index liq_recipient_idx    on public.liquidity_events (chain_id, recipient);
create index liq_sender_idx       on public.liquidity_events (chain_id, sender);

create index positions_owner_idx  on public.positions (chain_id, owner);
create index positions_pool_idx   on public.positions (chain_id, pool_id);

create index launches_created_idx on public.launches (chain_id, created_at desc);
create index launches_creator_idx on public.launches (chain_id, creator);
create index launch_trades_token_idx on public.launch_trades (chain_id, token, block_number desc);
create index launch_trades_feed_idx  on public.launch_trades (chain_id, block_number desc, log_index desc);

create index orders_owner_idx     on public.limit_orders (chain_id, owner);
create index orders_pool_idx      on public.limit_orders (chain_id, pool_address, bin_id);
create index orders_placed_idx    on public.limit_orders (chain_id, placed_block desc);

create index vault_events_feed_idx  on public.vault_events (chain_id, block_number desc, log_index desc);
create index vault_events_token_idx on public.vault_events (chain_id, token_id) where token_id is not null;
create index loans_owner_idx        on public.loans (chain_id, owner);

create index buybacks_feed_idx    on public.buybacks (chain_id, block_number desc, log_index desc);
create index routes_feed_idx      on public.route_executions (chain_id, block_number desc, log_index desc);
create index routes_sender_idx    on public.route_executions (chain_id, sender);

create index stats_hour_idx       on public.pool_stats_hourly (chain_id, hour desc);

-- ---------------------------------------------------------------------------------------------
-- RLS: public read, writes only through the service role (which bypasses RLS).
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'chains', 'deployments', 'indexer_state', 'tokens', 'pools', 'v4_pool_keys', 'swaps',
    'liquidity_events', 'positions', 'launches', 'launch_trades', 'limit_orders', 'vault_events',
    'loans', 'buybacks', 'route_executions', 'pool_stats_hourly'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select to anon, authenticated using (true)', t || '_public_read', t);
    execute format('revoke insert, update, delete, truncate on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end
$$;
