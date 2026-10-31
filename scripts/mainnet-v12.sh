#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/mainnet-v12.sh <lock|open>
# Release v1.2 gate on mainnet: stock pools with the oracle guard. A v4 pool that holds a STOCK asset starts in ORACLE mode
# and only opens while both of its tokens are enabled and have a fresh feed. `open` registers the Chainlink feeds of
# WETH, USDG, TSLA, NVDA and AAPL in the hub and enables the three stock tokens (5 transactions); `lock` restores the
# v1.0 state (stocks STOCK + disabled + no feed, WETH and USDG without feed). The web app lists the stock tokens from
# packages/sdk/src/addresses/mainnet.json, so the stock UI appears with the release that adds them.
# Staleness windows are longer than each feed's longest observed gap: stocks update 24/5 (up to ~14h overnight), WETH
# up to ~8h, USDG has a 24h heartbeat. A stale feed halts the pool (fail closed); liquidity can always be withdrawn.
# Asks the keystore password once; the password lives only in a private temp file deleted on exit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC="${MAINNET_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
DEPLOYER_ADDRESS="0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C"
KEYSTORE="${KEYSTORE:-$HOME/.foundry/keystores/deployer}"
case "${1:-}" in lock|open) MODE="$1" ;; *) echo "usage: bash scripts/mainnet-v12.sh <lock|open>"; exit 1 ;; esac

[ "$(cast chain-id --rpc-url "$RPC")" = "4663" ] || { echo "RPC is not Robinhood Chain mainnet (4663)"; exit 1; }
HUB="$(node -e "console.log(require('$ROOT/packages/sdk/src/addresses/mainnet.json').hub)")"
WETH="0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73"
USDG="0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"
TSLA="0x322F0929c4625eD5bAd873c95208D54E1c003b2d"
NVDA="0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC"
AAPL="0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9"
# Chainlink feed proxies on Robinhood Chain (description() and latestRoundData() checked on-chain 2026-10-31)
F_WETH="0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9"
F_USDG="0x61B7e5650328764B076A108EFF5fa7282a1B9aD2"
F_TSLA="0x4A1166a659A55625345e9515b32adECea5547C38"
F_NVDA="0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15"
F_AAPL="0x6B22A786bAa607d76728168703a39Ea9C99f2cD0"
CANONICAL=1; STOCK=2
ZERO="0x0000000000000000000000000000000000000000"

# rows: token class enabled feed maxStaleness (feeds before stocks when opening)
if [ "$MODE" = open ]; then
  ROWS=("$WETH $CANONICAL true $F_WETH 86400" "$USDG $CANONICAL true $F_USDG 172800"
        "$TSLA $STOCK true $F_TSLA 86400" "$NVDA $STOCK true $F_NVDA 86400" "$AAPL $STOCK true $F_AAPL 86400")
else
  ROWS=("$TSLA $STOCK false $ZERO 0" "$NVDA $STOCK false $ZERO 0" "$AAPL $STOCK false $ZERO 0"
        "$WETH $CANONICAL true $ZERO 0" "$USDG $CANONICAL true $ZERO 0")
fi
SIG='setAsset(address,uint8,bool,address,uint32)'
state() {
  for t in "$TSLA" "$NVDA" "$AAPL" "$WETH" "$USDG"; do
    echo "  $t  $(cast call "$HUB" 'asset(address)(uint8,bool,address,uint32)' "$t" --rpc-url "$RPC" | tr '\n' ' ')"
  done
}
echo "before:"; state

# simulate every call from the deployer first; a revert stops the script before anything is sent
for r in "${ROWS[@]}"; do
  set -- $r
  cast call "$HUB" "$SIG" "$1" "$2" "$3" "$4" "$5" --from "$DEPLOYER_ADDRESS" --rpc-url "$RPC" >/dev/null
done

if [ "$MODE" = open ]; then
  # every feed must answer with a positive price before anything is sent
  for f in "$F_WETH" "$F_USDG" "$F_TSLA" "$F_NVDA" "$F_AAPL"; do
    ans="$(cast call "$f" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$RPC" | sed -n 2p | awk '{print $1}')"
    [ "$ans" -gt 0 ] || { echo "STOP: feed $f returned no price. Nothing was sent."; exit 1; }
  done
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
read -rsp "Keystore password for 'deployer': " pass; echo
printf '%s' "$pass" >"$TMP/pw"; chmod 600 "$TMP/pw"; unset pass
ADDR="$(cast wallet address --keystore "$KEYSTORE" --password-file "$TMP/pw")"
if [ "$(echo "$ADDR" | tr 'A-F' 'a-f')" != "$(echo "$DEPLOYER_ADDRESS" | tr 'A-F' 'a-f')" ]; then
  echo "STOP: keystore is $ADDR, expected $DEPLOYER_ADDRESS. Nothing was sent."
  exit 1
fi
for r in "${ROWS[@]}"; do
  set -- $r
  cast send "$HUB" "$SIG" "$1" "$2" "$3" "$4" "$5" --keystore "$KEYSTORE" --password-file "$TMP/pw" --rpc-url "$RPC" --json \
    | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const j=JSON.parse(d);console.log("  tx",j.transactionHash,j.status==="0x1"?"ok":"FAILED")})'
done
echo "after:"; state
if [ "$MODE" = open ]; then
  echo "prices (hub.tryGetPrice: price, fresh, marketOpen):"
  for t in "$TSLA" "$NVDA" "$AAPL" "$WETH" "$USDG"; do
    echo "  $t  $(cast call "$HUB" 'tryGetPrice(address)(uint256,bool,bool)' "$t" --rpc-url "$RPC" | tr '\n' ' ')"
  done
fi
