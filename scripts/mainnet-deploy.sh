#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/mainnet-deploy.sh [--broadcast]
# Full Aethra Fi mainnet release (DeployMainnet.deployAll): core + DLMM + DAMM live, launchpad, AETH, buyback and credit
# deployed but locked on-chain (docs/RELEASE_PLAN.md). The deployer stays owner of every contract.
# Without --broadcast: dry run against the live chain, nothing is sent and no file changes.
# With --broadcast: checks the keystore (password prompt), then sends (password prompt) and writes
# packages/sdk/src/addresses/mainnet.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC="${MAINNET_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
DEPLOYER_ADDRESS="0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C"
# Official Robinhood stock tokens ("• Robinhood Token"), registered as STOCK with enabled=false until stock pools open
STOCK_TOKENS="${STOCK_TOKENS:-0x322F0929c4625eD5bAd873c95208D54E1c003b2d,0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC,0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9}"
BUDGET_USD="7"

[ "$(cast chain-id --rpc-url "$RPC")" = "4663" ] || { echo "RPC is not Robinhood Chain mainnet (4663)"; exit 1; }
cd "$ROOT/packages/contracts"

hub="$(node -e "console.log(require('$ROOT/packages/sdk/src/addresses/mainnet.json').hub ?? '')")"
if [ -n "$hub" ] && [ "${1:-}" = "--broadcast" ]; then
  echo "STOP: mainnet.json already has a hub ($hub). Aethra Fi is already deployed on mainnet."
  exit 1
fi

balance="$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC")"
gas_price="$(cast gas-price --rpc-url "$RPC")"
echo "deployer balance: $(cast from-wei "$balance") ETH, gas price: $(cast from-wei "$gas_price" gwei) gwei"

ARGS=(script/DeployMainnet.s.sol:DeployMainnet --sig "deployAll()" --rpc-url "$RPC" --sender "$DEPLOYER_ADDRESS")
export NETWORK=mainnet STOCK_TOKENS

if [ "${1:-}" != "--broadcast" ]; then
  echo "Dry run (nothing is sent)"
  forge script "${ARGS[@]}"
  cd "$ROOT" && node scripts/mainnet-cost.mjs "$gas_price" "$BUDGET_USD"
  exit 0
fi

echo "1/2  Verifying the deployer keystore address (password prompt)"
ADDR="$(cast wallet address --account deployer)"
if [ "$(echo "$ADDR" | tr 'A-F' 'a-f')" != "$(echo "$DEPLOYER_ADDRESS" | tr 'A-F' 'a-f')" ]; then
  echo "STOP: keystore 'deployer' is $ADDR, expected $DEPLOYER_ADDRESS. Nothing was deployed."
  exit 1
fi

echo "2/2  Deploying to Robinhood Chain mainnet (password prompt)"
forge script "${ARGS[@]}" --account deployer --broadcast --slow

cd "$ROOT" && node scripts/set-start-block.mjs mainnet
# prove the explorer source packages now, while the build that produced the deployed bytecode is still in out/
cd "$ROOT" && node scripts/verify-prepare.mjs mainnet --quiet || echo "WARNING: verification packages not ready, see scripts/verify-prepare.mjs"
cd "$ROOT" && pnpm --filter @aethra/sdk build >/dev/null
echo "Done. Addresses written to packages/sdk/src/addresses/mainnet.json"
echo "Remaining balance: $(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC" -e) ETH"
