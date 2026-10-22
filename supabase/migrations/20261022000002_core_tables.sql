-- Aethra Fi indexer: core tables.
-- Conventions
--   * addresses, tx hashes and pool ids are stored lowercase hex text
--   * raw on-chain integers (uint256 / int256) are numeric(78,0); USD values and prices are double precision
--   * every event table is keyed by (chain_id, tx_hash, log_index) so re-scans are idempotent upserts
--   * prices are "token1 per token0" in human units (decimals applied)

-- ---------------------------------------------------------------------------------------------
-- Chains & configuration
-- ---------------------------------------------------------------------------------------------
create table public.chains (
  chain_id      integer primary key,
  name          text not null,
  network       text not null check (network in ('local', 'testnet', 'mainnet')),
  rpc_url       text,                       -- public default; the indexer prefers RPC_URL_<id> from env
  explorer_url  text,
  is_testnet    boolean not null default true,
  enabled       boolean not null default true,
  created_at    timestamptz not null default now()
);
comment on table public.chains is 'Chains served by the Aethra Fi indexer and API.';

-- One row per chain: the JSON mirrors packages/sdk/src/addresses/{network}.json.
create table public.deployments (
  chain_id     integer primary key references public.chains (chain_id) on delete cascade,
  addresses    jsonb not null default '{}'::jsonb,
  start_block  bigint not null default 0,
  updated_at   timestamptz not null default now()
);
comment on table public.deployments is 'Contract addresses (proxy addresses) + start block per chain. The indexer reads its config from here.';

create table public.indexer_state (
  chain_id      integer primary key references public.chains (chain_id) on delete cascade,
  last_block    bigint,
  last_hash     text,
  head_block    bigint,
  status        text not null default 'idle' check (status in ('idle', 'running', 'ok', 'syncing', 'error', 'disabled')),
  error         text,
  chunk_size    integer,
  last_run_ms   integer,
  logs_indexed  bigint not null default 0,
  meta          jsonb not null default '{}'::jsonb,   -- chain reads cached by the indexer (e.g. graduation threshold)
  updated_at    timestamptz not null default now()
);
comment on table public.indexer_state is 'Block cursor and health of the indexer, per chain.';

-- ---------------------------------------------------------------------------------------------
-- Tokens & pools
-- ---------------------------------------------------------------------------------------------
create table public.tokens (
  chain_id          integer not null references public.chains (chain_id) on delete cascade,
  address           text not null,
  symbol            text not null default '?',
  name              text not null default '',
  decimals          integer not null default 18,
  kind              text not null default 'unknown',  -- canonical | stock | launch | rwa | test | unknown
  asset_class       text,                              -- hub AssetClass (CANONICAL/STOCK/LAUNCH/RWA) when registered
  asset_enabled     boolean,
  oracle            text,
  max_staleness     integer,
  is_stable         boolean not null default false,
  logo_url          text,
  price_usd         double precision,
  price_source      text,                              -- stable | oracle | pool:<pool_id>
  price_updated_at  timestamptz,
  first_seen_block  bigint,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  primary key (chain_id, address)
);

create table public.pools (
  chain_id              integer not null references public.chains (chain_id) on delete cascade,
  pool_id               text not null,      -- V4: PoolId; DLMM/DAMM: pool address; LAUNCH: launch token address
  venue                 text not null check (venue in ('V4', 'DLMM', 'DAMM', 'LAUNCH')),
  pool_address          text,               -- DLMM/DAMM pool, launchpad for LAUNCH, null for V4
  hub_pool_id           text,               -- bytes32 id in AethraHub when registered
  registered            boolean not null default false,
  hooks                 text,
  token0                text not null,
  token1                text not null,
  fee_pips              integer not null default 0,
  dynamic_fee           boolean not null default false,
  tick_spacing          integer,
  bin_step_bps          integer,
  active_index          integer,            -- V4 tick, DLMM active bin, DAMM tick/tickSpacing
  sqrt_price_x96        numeric(78, 0),
  sqrt_price_lower_x96  numeric(78, 0),
  sqrt_price_upper_x96  numeric(78, 0),
  liquidity             numeric(78, 0),
  reserve0              numeric(78, 0) not null default 0,
  reserve1              numeric(78, 0) not null default 0,
  reserves_from_events  boolean not null default true,   -- false: reserves come from chain reads (DAMM, LAUNCH)
  price                 double precision,   -- token1 per token0, human units
  tvl_usd               double precision not null default 0,
  mode                  text not null default 'dynamic' check (mode in ('dynamic', 'oracle', 'plain')),
  creator               text,
  enabled               boolean not null default true,
  launch_token          text,               -- set for LAUNCH pools and for v4 pools a launch graduated into
  created_at            timestamptz not null default now(),
  created_block         bigint,
  created_tx            text,
  updated_at            timestamptz not null default now(),
  primary key (chain_id, pool_id)
);

-- Every v4 Initialize seen on the PoolManager (cheap: one row per pool). Lets the indexer resolve the
-- PoolKey of a plain v4 pool that the hub registers later.
create table public.v4_pool_keys (
  chain_id        integer not null references public.chains (chain_id) on delete cascade,
  pool_id         text not null,
  currency0       text not null,
  currency1       text not null,
  fee             integer not null,
  tick_spacing    integer not null,
  hooks           text not null,
  sqrt_price_x96  numeric(78, 0) not null,
  tick            integer not null,
  block_number    bigint not null,
  tx_hash         text not null,
  ts              timestamptz,
  primary key (chain_id, pool_id)
);

-- ---------------------------------------------------------------------------------------------
-- Activity
-- ---------------------------------------------------------------------------------------------
create table public.swaps (
  chain_id             integer not null references public.chains (chain_id) on delete cascade,
  tx_hash              text not null,
  log_index            integer not null,
  block_number         bigint not null,
  block_hash           text,
  ts                   timestamptz not null,
  pool_id              text not null,
  venue                text not null,
  sender               text not null,
  recipient            text not null,
  token_in             text not null,
  token_out            text not null,
  amount_in            numeric(78, 0) not null,
  amount_out           numeric(78, 0) not null,
  fee_amount           numeric(78, 0) not null default 0,
  protocol_fee_amount  numeric(78, 0) not null default 0,
  delta0               numeric(78, 0) not null default 0,   -- pool balance change of token0 (signed)
  delta1               numeric(78, 0) not null default 0,
  price                double precision,                    -- pool price after the swap
  amount_usd           double precision,
  fee_usd              double precision,
  primary key (chain_id, tx_hash, log_index)
);

create table public.liquidity_events (
  chain_id         integer not null references public.chains (chain_id) on delete cascade,
  tx_hash          text not null,
  log_index        integer not null,
  block_number     bigint not null,
  block_hash       text,
  ts               timestamptz not null,
  pool_id          text,
  venue            text,
  source           text not null check (source in ('v4', 'dlmm', 'damm', 'positions')),
  kind             text not null check (kind in ('add', 'remove', 'collect', 'claim', 'modify')),
  sender           text,
  recipient        text,
  token_id         numeric(78, 0),
  tick_lower       integer,
  tick_upper       integer,
  bin_ids          integer[],
  liquidity_delta  numeric(78, 0),
  shares           numeric(78, 0),
  amount0          numeric(78, 0) not null default 0,   -- signed pool balance change (add +, remove -); collect: paid out (+)
  amount1          numeric(78, 0) not null default 0,
  amount_usd       double precision,
  primary key (chain_id, tx_hash, log_index)
);

create table public.positions (
  chain_id          integer not null references public.chains (chain_id) on delete cascade,
  token_id          numeric(78, 0) not null,
  pool_id           text not null,
  owner             text not null,
  tick_lower        integer not null,
  tick_upper        integer not null,
  liquidity         numeric(78, 0) not null default 0,
  lock_cliff        timestamptz,
  lock_end          timestamptz,
  lock_permanent    boolean not null default false,
  locked_liquidity  numeric(78, 0),
  fees0_collected   numeric(78, 0) not null default 0,
  fees1_collected   numeric(78, 0) not null default 0,
  burned            boolean not null default false,
  minted_block      bigint,
  minted_tx         text,
  minted_at         timestamptz,
  updated_at        timestamptz not null default now(),
  primary key (chain_id, token_id)
);

create table public.launches (
  chain_id               integer not null references public.chains (chain_id) on delete cascade,
  token                  text not null,
  creator                text not null,
  name                   text not null,
  symbol                 text not null,
  metadata_uri           text,
  real_weth              numeric(78, 0) not null default 0,
  graduated              boolean not null default false,
  v4_pool_id             text,
  position_id            numeric(78, 0),
  graduation_weth        numeric(78, 0),
  graduation_tokens      numeric(78, 0),
  graduated_at           timestamptz,
  graduated_block        bigint,
  graduated_tx           text,
  graduated_log_index    integer,
  created_at             timestamptz not null,
  created_block          bigint not null,
  created_tx             text not null,
  created_log_index      integer not null,
  updated_at             timestamptz not null default now(),
  primary key (chain_id, token)
);

create table public.launch_trades (
  chain_id         integer not null references public.chains (chain_id) on delete cascade,
  tx_hash          text not null,
  log_index        integer not null,
  block_number     bigint not null,
  block_hash       text,
  ts               timestamptz not null,
  token            text not null,
  trader           text not null,
  is_buy           boolean not null,
  weth_amount      numeric(78, 0) not null,
  token_amount     numeric(78, 0) not null,
  fee              numeric(78, 0) not null default 0,
  real_weth_after  numeric(78, 0) not null,
  amount_usd       double precision,
  primary key (chain_id, tx_hash, log_index)
);

create table public.limit_orders (
  chain_id           integer not null references public.chains (chain_id) on delete cascade,
  order_id           numeric(78, 0) not null,
  owner              text not null,
  pool_address       text not null,
  pool_id            text,
  bin_id             integer not null,
  side               text not null check (side in ('SELL_TOKEN0', 'SELL_TOKEN1')),
  amount_in          numeric(78, 0) not null,
  status             text not null default 'open' check (status in ('open', 'cancelled', 'claimed')),
  returned0          numeric(78, 0),
  returned1          numeric(78, 0),
  placed_block       bigint not null,
  placed_tx          text not null,
  placed_log_index   integer not null,
  placed_at          timestamptz not null,
  closed_block       bigint,
  closed_tx          text,
  closed_log_index   integer,
  closed_at          timestamptz,
  updated_at         timestamptz not null default now(),
  primary key (chain_id, order_id)
);

-- Lending vault + credit manager events (source = vault | credit). Loans are derived from these.
create table public.vault_events (
  chain_id      integer not null references public.chains (chain_id) on delete cascade,
  tx_hash       text not null,
  log_index     integer not null,
  block_number  bigint not null,
  block_hash    text,
  ts            timestamptz not null,
  source        text not null check (source in ('vault', 'credit')),
  kind          text not null,   -- vault: Borrowed Repaid InterestAccrued Deposit Withdraw; credit: Pledged Released Borrow Repay Liquidated
  token_id      numeric(78, 0),
  account       text,
  counterparty  text,
  assets        numeric(78, 0),
  shares        numeric(78, 0),
  extra         jsonb not null default '{}'::jsonb,
  primary key (chain_id, tx_hash, log_index)
);

create table public.loans (
  chain_id                integer not null references public.chains (chain_id) on delete cascade,
  token_id                numeric(78, 0) not null,
  owner                   text not null,
  status                  text not null check (status in ('pledged', 'released', 'liquidated')),
  borrowed                numeric(78, 0) not null default 0,
  repaid                  numeric(78, 0) not null default 0,
  principal_outstanding   numeric(78, 0) not null default 0,  -- borrowed - repaid (interest is read on-chain)
  liquidated_by           text,
  liquidation_debt        numeric(78, 0),
  liquidation_value_usd   double precision,
  pledged_at              timestamptz,
  last_event_at           timestamptz,
  updated_at              timestamptz not null default now(),
  primary key (chain_id, token_id)
);

create table public.buybacks (
  chain_id      integer not null references public.chains (chain_id) on delete cascade,
  tx_hash       text not null,
  log_index     integer not null,
  block_number  bigint not null,
  block_hash    text,
  ts            timestamptz not null,
  kind          text not null check (kind in ('revenue', 'buyback')),
  token         text not null,
  amount        numeric(78, 0) not null,
  from_address  text,
  aeth_bought   numeric(78, 0),
  aeth_burned   numeric(78, 0),
  to_treasury   numeric(78, 0),
  amount_usd    double precision,
  primary key (chain_id, tx_hash, log_index)
);

create table public.route_executions (
  chain_id      integer not null references public.chains (chain_id) on delete cascade,
  tx_hash       text not null,
  log_index     integer not null,
  block_number  bigint not null,
  block_hash    text,
  ts            timestamptz not null,
  sender        text not null,
  recipient     text not null,
  token_in      text not null,
  token_out     text not null,
  amount_in     numeric(78, 0) not null,
  amount_out    numeric(78, 0) not null,
  hops          integer not null,
  amount_usd    double precision,
  primary key (chain_id, tx_hash, log_index)
);

create table public.pool_stats_hourly (
  chain_id     integer not null references public.chains (chain_id) on delete cascade,
  pool_id      text not null,
  hour         timestamptz not null,
  volume_usd   double precision not null default 0,
  volume0      numeric(78, 0) not null default 0,
  volume1      numeric(78, 0) not null default 0,
  trades       integer not null default 0,
  fees_usd     double precision not null default 0,
  open_price   double precision,
  close_price  double precision,
  high_price   double precision,
  low_price    double precision,
  tvl_usd      double precision,
  updated_at   timestamptz not null default now(),
  primary key (chain_id, pool_id, hour)
);
