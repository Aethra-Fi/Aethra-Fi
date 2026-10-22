#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/testnet-deploy.sh
# Deploys Aethra Fi to Robinhood Chain Testnet with the `deployer` Foundry keystore.
# Prompts for the keystore password once per step (4x). Writes packages/sdk/src/addresses/testnet.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC="${TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com}"
DEPLOYER_ADDRESS="0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C"
SEED_WETH="${SEED_WETH:-5000000000000000}" # 0.005 ETH of seed liquidity for the WETH/aUSD pool

[ "$(cast chain-id --rpc-url "$RPC")" = "46630" ] || { echo "RPC is not Robinhood Chain Testnet (46630)"; exit 1; }

echo "1/4  Verifying the deployer keystore address (password prompt)"
ADDR="$(cast wallet address --account deployer)"
if [ "$(echo "$ADDR" | tr 'A-F' 'a-f')" != "$(echo "$DEPLOYER_ADDRESS" | tr 'A-F' 'a-f')" ]; then
  echo "STOP: keystore 'deployer' is $ADDR, expected $DEPLOYER_ADDRESS. Nothing was deployed."
  exit 1
fi
echo "     balance: $(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC" -e) ETH"

cd "$ROOT/packages/contracts"
COMMON=(--rpc-url "$RPC" --account deployer --sender "$DEPLOYER_ADDRESS" --broadcast --slow)

echo "2/4  Core + modules (password prompt)"
NETWORK=testnet forge script script/Deploy.s.sol:Deploy "${COMMON[@]}"

echo "3/4  Test markets: faucet tokens, mock feeds, seeded pools (password prompt)"
NETWORK=testnet SEED_WETH="$SEED_WETH" forge script script/SetupMarkets.s.sol:SetupMarkets "${COMMON[@]}"

echo "4/4  Credit: lending vault + credit manager (password prompt)"
NETWORK=testnet forge script script/DeployCredit.s.sol:DeployCredit "${COMMON[@]}"

cd "$ROOT" && pnpm --filter @aethra/sdk build >/dev/null
echo "Done. Addresses written to packages/sdk/src/addresses/testnet.json"
echo "Remaining balance: $(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC" -e) ETH"
