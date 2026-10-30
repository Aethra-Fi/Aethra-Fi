#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/testnet-redeploy.sh [--broadcast]
# Fresh Aethra Fi testnet, compiled with the CBOR metadata hash so the explorer can give a full verification match.
# Same release shape as mainnet (DeployMainnet): core, DLMM and DAMM live, launchpad, AETH, buyback and credit locked.
# Steps: Deploy -> SetupMarkets (faucet tokens, mock feeds, seeded v4 pools) -> DeployGated -> DeepenLiquidity.
# Without --broadcast: simulation against the live testnet (nothing sent, no file changes).
# With --broadcast: asks the keystore password once, checks the address, sends every step and writes
# packages/sdk/src/addresses/testnet.json. The password lives only in a private temp file deleted on exit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC="${TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com}"
DEPLOYER_ADDRESS="0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C"
KEYSTORE="${KEYSTORE:-$HOME/.foundry/keystores/deployer}"
SEED_WETH="${SEED_WETH:-1000000000000000}" # 0.001 ETH wrapped into the WETH/aUSD pool
MIN_BALANCE="${MIN_BALANCE:-3000000000000000}" # 0.003 ETH: gas for every step plus the seed

[ "$(cast chain-id --rpc-url "$RPC")" = "46630" ] || { echo "RPC is not Robinhood Chain Testnet (46630)"; exit 1; }
balance="$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC")"
echo "deployer balance: $(cast from-wei "$balance") ETH"
# DLMMPool is deployed from the bytecode of its explorer source package (see scripts/build-verifiable.mjs)
(cd "$ROOT" && node scripts/build-verifiable.mjs >/dev/null)
cd "$ROOT/packages/contracts"
export NETWORK=testnet

if [ "${1:-}" != "--broadcast" ]; then
  echo "Simulation of step 1 (Deploy) against the live testnet; nothing is sent."
  WRITE_ADDRESSES=false forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --sender "$DEPLOYER_ADDRESS"
  echo "The full flow (4 steps) was rehearsed on a fork; see docs/PROGRESS.md."
  exit 0
fi

if [ "$(node -e "console.log(BigInt('$balance') < BigInt('$MIN_BALANCE'))")" = true ]; then
  echo "STOP: balance below $(cast from-wei "$MIN_BALANCE") ETH. Top up from https://faucet.testnet.chain.robinhood.com"
  exit 1
fi

PW="$(mktemp)"; chmod 600 "$PW"; trap 'rm -f "$PW"' EXIT
read -rsp "Keystore password for 'deployer': " pass; echo
printf '%s' "$pass" >"$PW"; unset pass

ADDR="$(cast wallet address --keystore "$KEYSTORE" --password-file "$PW")"
if [ "$(echo "$ADDR" | tr 'A-F' 'a-f')" != "$(echo "$DEPLOYER_ADDRESS" | tr 'A-F' 'a-f')" ]; then
  echo "STOP: keystore is $ADDR, expected $DEPLOYER_ADDRESS. Nothing was sent."
  exit 1
fi
echo "keystore ok: $ADDR"

COMMON=(--rpc-url "$RPC" --keystore "$KEYSTORE" --password-file "$PW" --sender "$DEPLOYER_ADDRESS" --broadcast --slow)

echo "1/4  Core, DLMM, DAMM"
forge script script/Deploy.s.sol:Deploy "${COMMON[@]}"
echo "2/4  Test markets: faucet tokens, mock feeds, seeded v4 pools"
SEED_WETH="$SEED_WETH" forge script script/SetupMarkets.s.sol:SetupMarkets "${COMMON[@]}"
echo "3/4  Gated modules: launchpad, AETH, buyback, credit (locked)"
STABLECOIN="$(node -e "console.log(require('$ROOT/packages/sdk/src/addresses/testnet.json').tokens.aUSD.address)")" \
  forge script script/DeployGated.s.sol:DeployGated "${COMMON[@]}"
echo "4/4  Deeper liquidity, DLMM and DAMM pools"
SEED_WETH=0 forge script script/testnet/DeepenLiquidity.s.sol:DeepenLiquidity "${COMMON[@]}"

cd "$ROOT" && node scripts/set-start-block.mjs testnet
cd "$ROOT" && pnpm --filter @aethra/sdk build >/dev/null
cd "$ROOT" && node scripts/verify-prepare.mjs testnet --quiet || echo "WARNING: verification packages not ready"
echo "Done. Addresses written to packages/sdk/src/addresses/testnet.json"
echo "Remaining balance: $(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC" -e) ETH"
