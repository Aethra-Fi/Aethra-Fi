#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/upgrade.sh <network> <contract> <reference-name> [--broadcast]
#
# Validates and rolls out one implementation upgrade (see packages/contracts/script/upgrade/Upgrade.s.sol).
#   <network>         local | testnet | mainnet
#   <contract>        hub hook router positions dlmmFactory dlmmLimitOrders dlmmPool dammFactory dammPool
#                     launchpad buyback lendingVault creditManager
#   <reference-name>  build of the code that is deployed today, made with: bash scripts/snapshot-build.sh <git-ref> <name>
# Without --broadcast it only validates and simulates (no keystore, nothing sent).
# With --broadcast it asks for the `deployer` keystore password. On testnet/local the deployer owns the proxy, so the
# upgrade is sent too. On mainnet only the new implementation is deployed; the script prints the calldata for the Safe.
set -euo pipefail
NETWORK="${1:?usage: upgrade.sh <network> <contract> <reference-name> [--broadcast]}"
CONTRACT="${2:?usage: upgrade.sh <network> <contract> <reference-name> [--broadcast]}"
REF="${3:?usage: upgrade.sh <network> <contract> <reference-name> [--broadcast]}"
MODE="${4:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOYER_ADDRESS="0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C"

case "$NETWORK" in
  local) RPC="${LOCAL_RPC_URL:-http://127.0.0.1:8545}"; CHAIN=31337 ;;
  testnet) RPC="${TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com}"; CHAIN=46630 ;;
  mainnet) RPC="${MAINNET_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"; CHAIN=4663 ;;
  *) echo "unknown network: $NETWORK"; exit 1 ;;
esac
[ "$(cast chain-id --rpc-url "$RPC")" = "$CHAIN" ] || { echo "RPC is not chain $CHAIN"; exit 1; }
[ -d "$ROOT/packages/contracts/upgrades/$REF" ] || { echo "no reference build '$REF'. Run: bash scripts/snapshot-build.sh <git-ref> $REF"; exit 1; }

cd "$ROOT/packages/contracts"
export FOUNDRY_PROFILE=upgrade FOUNDRY_OUT=out-upgrade
# stale build-info files make the OpenZeppelin validator fail ("found multiple contracts"), so always rebuild from scratch
rm -rf out-upgrade cache-upgrade
forge build --build-info >/dev/null

export NETWORK CONTRACT REFERENCE_BUILD_INFO="upgrades/$REF" REFERENCE_NAME="$REF"
ARGS=(--rpc-url "$RPC" --sender "$DEPLOYER_ADDRESS")
if [ "$MODE" = "--broadcast" ]; then
  echo "Verifying the deployer keystore address (password prompt)"
  ADDR="$(cast wallet address --account deployer)"
  if [ "$(echo "$ADDR" | tr 'A-F' 'a-f')" != "$(echo "$DEPLOYER_ADDRESS" | tr 'A-F' 'a-f')" ]; then
    echo "STOP: keystore 'deployer' is $ADDR, expected $DEPLOYER_ADDRESS. Nothing was sent."
    exit 1
  fi
  [ "$NETWORK" = "mainnet" ] || export DIRECT=true
  ARGS+=(--account deployer --broadcast --slow)
else
  [ "$NETWORK" = "mainnet" ] || export DIRECT=true # simulate the upgrade call as well
fi
forge script script/upgrade/Upgrade.s.sol:Upgrade "${ARGS[@]}"
