#!/usr/bin/env bash
# Jalankan di: ROOT
# Deploys Aethra Fi to the local Anvil fork by impersonating the deployer (no private key).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOYER_ADDRESS="${DEPLOYER_ADDRESS:-0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C}"
RPC="${LOCAL_RPC_URL:-http://127.0.0.1:8545}"
cast rpc anvil_setBalance "$DEPLOYER_ADDRESS" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null  # 100 ETH
cd "$ROOT/packages/contracts"
NETWORK=local forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --unlocked --sender "$DEPLOYER_ADDRESS" --broadcast --slow "$@"
if [ -f script/SetupMarkets.s.sol ]; then
  SEED_WETH=${SEED_WETH:-5000000000000000000} NETWORK=local forge script script/SetupMarkets.s.sol:SetupMarkets --rpc-url "$RPC" --unlocked --sender "$DEPLOYER_ADDRESS" --broadcast --slow
fi
NETWORK=local forge script script/DeployCredit.s.sol:DeployCredit --rpc-url "$RPC" --unlocked --sender "$DEPLOYER_ADDRESS" --broadcast --slow
cd "$ROOT" && pnpm --filter @aethra/sdk abis >/dev/null 2>&1 || true
echo "Local deployment written to packages/sdk/src/addresses/local.json"
