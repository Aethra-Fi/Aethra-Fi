-- Aethra Fi seed: chains, empty deployments (addresses mirror packages/sdk/src/addresses/*.json) and cursors.
-- Contract addresses are null until deployed. Load real ones with supabase/scripts/sync-deployments.mjs.

insert into public.chains (chain_id, name, network, rpc_url, explorer_url, is_testnet, enabled) values
  (31337, 'Aethra Local (testnet fork)', 'local',   'http://host.docker.internal:8545',           null,                                            true,  true),
  (46630, 'Robinhood Chain Testnet',     'testnet', 'https://rpc.testnet.chain.robinhood.com', 'https://explorer.testnet.chain.robinhood.com', true,  true),
  (4663,  'Robinhood Chain',             'mainnet', 'https://rpc.mainnet.chain.robinhood.com', 'https://robinhoodchain.blockscout.com',        false, true)
on conflict (chain_id) do update set name = excluded.name, network = excluded.network, rpc_url = excluded.rpc_url,
  explorer_url = excluded.explorer_url, is_testnet = excluded.is_testnet;

insert into public.deployments (chain_id, addresses, start_block) values
  (31337, '{"deployer":"0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C","poolManager":"0x8366a39CC670B4001A1121B8F6A443A643e40951","weth":"0x33e4191705c386532ba27cBF171Db86919200B94","multicall3":"0xcA11bde05977b3631167028862bE2a173976CA11","permit2":"0x000000000022D473030F116dDEE9F6B43aC78BA3","hub":null,"hook":null,"router":null,"positions":null,"dlmmFactory":null,"dlmmLimitOrders":null,"dammFactory":null,"launchpad":null,"lendingVault":null,"creditManager":null,"buyback":null,"aeth":null,"tokens":{},"oracles":{},"startBlock":0}'::jsonb, 0),
  (46630, '{"deployer":"0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C","poolManager":"0x8366a39CC670B4001A1121B8F6A443A643e40951","weth":"0x33e4191705c386532ba27cBF171Db86919200B94","multicall3":"0xcA11bde05977b3631167028862bE2a173976CA11","permit2":"0x000000000022D473030F116dDEE9F6B43aC78BA3","hub":null,"hook":null,"router":null,"positions":null,"dlmmFactory":null,"dlmmLimitOrders":null,"dammFactory":null,"launchpad":null,"lendingVault":null,"creditManager":null,"buyback":null,"aeth":null,"tokens":{},"oracles":{},"startBlock":0}'::jsonb, 0),
  (4663, '{"deployer":"0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C","poolManager":"0x8366a39CC670B4001A1121B8F6A443A643e40951","weth":"0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73","multicall3":"0xcA11bde05977b3631167028862bE2a173976CA11","permit2":"0x000000000022D473030F116dDEE9F6B43aC78BA3","hub":null,"hook":null,"router":null,"positions":null,"dlmmFactory":null,"dlmmLimitOrders":null,"dammFactory":null,"launchpad":null,"lendingVault":null,"creditManager":null,"buyback":null,"aeth":null,"tokens":{},"oracles":{},"startBlock":0}'::jsonb, 0)
on conflict (chain_id) do nothing;

insert into public.indexer_state (chain_id, status) values (31337, 'idle'), (46630, 'idle'), (4663, 'idle')
on conflict (chain_id) do nothing;
