#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/mainnet-v11.sh <lock|open>
# Release v1.1 gate on mainnet: DLMM pools, DAMM pools and DLMM limit orders. The hub only lets a factory create pools
# while it is a registrar, so `lock` removes both factories as registrars and `open` adds them back (2 transactions,
# about 60k gas). The web app reads the same flags, so it hides or shows the venues by itself.
# Asks the keystore password once; the password lives only in a private temp file deleted on exit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC="${MAINNET_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
DEPLOYER_ADDRESS="0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C"
KEYSTORE="${KEYSTORE:-$HOME/.foundry/keystores/deployer}"
case "${1:-}" in lock) FLAG=false ;; open) FLAG=true ;; *) echo "usage: bash scripts/mainnet-v11.sh <lock|open>"; exit 1 ;; esac

[ "$(cast chain-id --rpc-url "$RPC")" = "4663" ] || { echo "RPC is not Robinhood Chain mainnet (4663)"; exit 1; }
get() { node -e "console.log(require('$ROOT/packages/sdk/src/addresses/mainnet.json').$1)"; }
HUB="$(get hub)"; DLMM="$(get dlmmFactory)"; DAMM="$(get dammFactory)"
state() { echo "DLMM factory registrar: $(cast call "$HUB" 'isRegistrar(address)(bool)' "$DLMM" --rpc-url "$RPC"), DAMM factory registrar: $(cast call "$HUB" 'isRegistrar(address)(bool)' "$DAMM" --rpc-url "$RPC")"; }
echo "before: $(state)"

# simulate both calls from the deployer first; a revert stops the script before anything is sent
for f in "$DLMM" "$DAMM"; do
  cast call "$HUB" 'setRegistrar(address,bool)' "$f" "$FLAG" --from "$DEPLOYER_ADDRESS" --rpc-url "$RPC" >/dev/null
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
read -rsp "Keystore password for 'deployer': " pass; echo
printf '%s' "$pass" >"$TMP/pw"; chmod 600 "$TMP/pw"; unset pass
ADDR="$(cast wallet address --keystore "$KEYSTORE" --password-file "$TMP/pw")"
if [ "$(echo "$ADDR" | tr 'A-F' 'a-f')" != "$(echo "$DEPLOYER_ADDRESS" | tr 'A-F' 'a-f')" ]; then
  echo "STOP: keystore is $ADDR, expected $DEPLOYER_ADDRESS. Nothing was sent."
  exit 1
fi
for f in "$DLMM" "$DAMM"; do
  cast send "$HUB" 'setRegistrar(address,bool)' "$f" "$FLAG" --keystore "$KEYSTORE" --password-file "$TMP/pw" --rpc-url "$RPC" --json \
    | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const j=JSON.parse(d);console.log("  tx",j.transactionHash,j.status==="0x1"?"ok":"FAILED")})'
done
echo "after:  $(state)"
