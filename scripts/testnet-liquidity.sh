#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/testnet-liquidity.sh [--broadcast]
# Testnet markets refresh (script/testnet/DeepenLiquidity.s.sol): fresh mock prices with a 365 day staleness window
# (stock pools were halted by stale feeds), deeper v4 pools, the first DLMM pool (aTSLA/aUSD) and two DAMM pools.
# Without --broadcast: simulation against the live testnet. With --broadcast: keystore password prompt twice.
# SEED_WETH (wei, default 0.003 ETH) is wrapped and added to the WETH/aUSD pool.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC="${TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com}"
DEPLOYER_ADDRESS="0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C"
export NETWORK=testnet SEED_WETH="${SEED_WETH:-3000000000000000}"

[ "$(cast chain-id --rpc-url "$RPC")" = "46630" ] || { echo "RPC is not Robinhood Chain Testnet (46630)"; exit 1; }
echo "balance: $(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC" -e) ETH, SEED_WETH: $(cast from-wei "$SEED_WETH") ETH"
cd "$ROOT/packages/contracts"
ARGS=(script/testnet/DeepenLiquidity.s.sol:DeepenLiquidity --rpc-url "$RPC" --sender "$DEPLOYER_ADDRESS")

if [ "${1:-}" != "--broadcast" ]; then
  forge script "${ARGS[@]}"
  exit 0
fi

echo "1/2  Verifying the deployer keystore address (password prompt)"
ADDR="$(cast wallet address --account deployer)"
if [ "$(echo "$ADDR" | tr 'A-F' 'a-f')" != "$(echo "$DEPLOYER_ADDRESS" | tr 'A-F' 'a-f')" ]; then
  echo "STOP: keystore 'deployer' is $ADDR, expected $DEPLOYER_ADDRESS. Nothing was sent."
  exit 1
fi
echo "2/2  Sending (password prompt)"
forge script "${ARGS[@]}" --account deployer --broadcast --slow
echo "Done. Remaining balance: $(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC" -e) ETH"
