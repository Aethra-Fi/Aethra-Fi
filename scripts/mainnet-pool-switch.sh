#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/mainnet-pool-switch.sh <off|on> [poolId]
# Emergency switch: the hook refuses every swap on a pool the hub marks disabled (PoolDisabled). Liquidity can always
# be withdrawn. Default pool: WETH/USDG v4. One transaction (~35k gas), keystore password asked once.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC="${MAINNET_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
DEPLOYER_ADDRESS="0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C"
KEYSTORE="${KEYSTORE:-$HOME/.foundry/keystores/deployer}"
case "${1:-}" in off) FLAG=false ;; on) FLAG=true ;; *) echo "usage: bash scripts/mainnet-pool-switch.sh <off|on> [poolId]"; exit 1 ;; esac
get() { node -e "console.log(require('$ROOT/packages/sdk/src/addresses/mainnet.json').$1)"; }
HUB="$(get hub)"
POOL_ID="${2:-$(cast keccak "$(cast abi-encode 'f(address,address,uint24,int24,address)' "$(get weth)" "$(get tokens.USDG.address)" 8388608 10 "$(get hook)")")}"
echo "pool $POOL_ID enabled: $(cast call "$HUB" 'isPoolEnabled(bytes32)(bool)' "$POOL_ID" --rpc-url "$RPC")"
cast call "$HUB" 'setPoolEnabled(bytes32,bool)' "$POOL_ID" "$FLAG" --from "$DEPLOYER_ADDRESS" --rpc-url "$RPC" >/dev/null

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
read -rsp "Keystore password for 'deployer': " pass; echo
printf '%s' "$pass" >"$TMP/pw"; chmod 600 "$TMP/pw"; unset pass
ADDR="$(cast wallet address --keystore "$KEYSTORE" --password-file "$TMP/pw")"
[ "$(echo "$ADDR" | tr 'A-F' 'a-f')" = "$(echo "$DEPLOYER_ADDRESS" | tr 'A-F' 'a-f')" ] || { echo "STOP: keystore is $ADDR"; exit 1; }
cast send "$HUB" 'setPoolEnabled(bytes32,bool)' "$POOL_ID" "$FLAG" --keystore "$KEYSTORE" --password-file "$TMP/pw" --rpc-url "$RPC" >/dev/null
echo "pool $POOL_ID enabled: $(cast call "$HUB" 'isPoolEnabled(bytes32)(bool)' "$POOL_ID" --rpc-url "$RPC")"
