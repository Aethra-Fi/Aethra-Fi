#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/mainnet-v13.sh <open|lock>
# Release v1.3 on mainnet: launchpad markets, and protocol fees to the treasury (packages/contracts/script/mainnet/ReleaseV13.s.sol).
# `open` upgrades the v4 hook and the DLMM pool beacon (their protocol fee sweep falls back to hub.treasury() while no
# buyback is set), sets a 20% protocol share of swap fees to the treasury, and makes the launchpad a hub registrar.
# `lock` closes the launchpad and sets the protocol share back to 0 (the upgrades stay).
# Before anything is sent: the RPC must be chain 4663, the DLMM pool bytecode is rebuilt from its explorer package,
# both upgrades are validated against the deployed build (OpenZeppelin storage layout), and the whole batch is simulated
# against live mainnet state. Asks the keystore password once; it lives only in a private temp file deleted on exit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC="${MAINNET_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
DEPLOYER_ADDRESS="0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C"
KEYSTORE="${KEYSTORE:-$HOME/.foundry/keystores/deployer}"
case "${1:-}" in open|lock) export MODE="$1" ;; *) echo "usage: bash scripts/mainnet-v13.sh <open|lock>"; exit 1 ;; esac

[ "$(cast chain-id --rpc-url "$RPC")" = "4663" ] || { echo "RPC is not Robinhood Chain mainnet (4663)"; exit 1; }
cd "$ROOT"

if [ "$MODE" = open ]; then
  echo "== DLMM pool bytecode from its explorer package"
  node scripts/build-verifiable.mjs
  echo "== storage layout and upgrade safety (hook, DLMM pool) against the deployed v1.2.0 build"
  [ -d packages/contracts/upgrades/mainnet-v12 ] || bash scripts/snapshot-build.sh v1.2.0 mainnet-v12
  bash scripts/upgrade.sh mainnet hook,dlmmPool mainnet-v12 | grep -E "upgrade validated|owner of target" || { echo "STOP: upgrade validation failed. Nothing was sent."; exit 1; }
fi

cd "$ROOT/packages/contracts"
echo "== simulation against live mainnet state"
forge script script/mainnet/ReleaseV13.s.sol:ReleaseV13 --rpc-url "$RPC" --sender "$DEPLOYER_ADDRESS" 2>&1 \
  | grep -E "v1.3|treasury|protocol share|graduation|implementation|Estimated total gas|Estimated amount|Error|revert" || true
forge script script/mainnet/ReleaseV13.s.sol:ReleaseV13 --rpc-url "$RPC" --sender "$DEPLOYER_ADDRESS" >/dev/null 2>&1 \
  || { echo "STOP: simulation failed. Nothing was sent."; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
read -rsp "Keystore password for 'deployer': " pass; echo
printf '%s' "$pass" >"$TMP/pw"; chmod 600 "$TMP/pw"; unset pass
ADDR="$(cast wallet address --keystore "$KEYSTORE" --password-file "$TMP/pw")"
if [ "$(echo "$ADDR" | tr 'A-F' 'a-f')" != "$(echo "$DEPLOYER_ADDRESS" | tr 'A-F' 'a-f')" ]; then
  echo "STOP: keystore is $ADDR, expected $DEPLOYER_ADDRESS. Nothing was sent."
  exit 1
fi

echo "== broadcast ($MODE)"
status=0
forge script script/mainnet/ReleaseV13.s.sol:ReleaseV13 --rpc-url "$RPC" --keystore "$KEYSTORE" --password-file "$TMP/pw" \
  --sender "$DEPLOYER_ADDRESS" --broadcast --slow >"$TMP/log" 2>&1 || status=$?
grep -E "v1.3|treasury|protocol share|graduation|implementation|ONCHAIN EXECUTION|Error|revert|Hash" "$TMP/log" || true
if [ "$status" -ne 0 ]; then echo "FAILED (exit $status). Last lines:"; tail -20 "$TMP/log"; exit "$status"; fi
echo "Done. Broadcast record: packages/contracts/broadcast/ReleaseV13.s.sol/4663/run-latest.json"
