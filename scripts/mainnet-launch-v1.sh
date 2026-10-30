#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/mainnet-launch-v1.sh
# v1.0 launch on mainnet: opens the WETH/USDG v4 pool at the market price (CoinGecko), seeds it with a full-range
# position (script/mainnet/SeedV1.s.sol), then smoke-tests it with a small ETH -> USDG swap through the router.
# SEED_ETH (wei, default 0.005 ETH) is paired with the matching USDG. Asks for confirmation and the keystore password
# once; the password lives only in a private temp file deleted on exit. Rehearsed by test/fork/MainnetLaunch.t.sol.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC="${MAINNET_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
EXPLORER="https://robinhoodchain.blockscout.com"
DEPLOYER_ADDRESS="0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C"
KEYSTORE="${KEYSTORE:-$HOME/.foundry/keystores/deployer}"
SEED_ETH="${SEED_ETH:-5000000000000000}"
SMOKE_ETH="${SMOKE_ETH:-100000000000000}" # 0.0001 ETH
GAS_RESERVE=300000000000000              # keep 0.0003 ETH for gas

[ "$(cast chain-id --rpc-url "$RPC")" = "4663" ] || { echo "RPC is not Robinhood Chain mainnet (4663)"; exit 1; }
get() { node -e "console.log(require('$ROOT/packages/sdk/src/addresses/mainnet.json').$1)"; }
USDG="$(get tokens.USDG.address)"; WETH="$(get weth)"; ROUTER="$(get router)"; HOOK="$(get hook)"

PRICE="$(curl -s 'https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd' | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{console.log(JSON.parse(d).ethereum.usd)})')"
PRICE6="$(node -e "console.log(Math.round($PRICE * 1e6))")"
SEED_USDG="$(node -e "console.log((BigInt('$SEED_ETH') * BigInt('$PRICE6') / 10n**18n).toString())")"
ETH_BAL="$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC")"
USDG_BAL="$(cast call "$USDG" 'balanceOf(address)(uint256)' "$DEPLOYER_ADDRESS" --rpc-url "$RPC" | awk '{print $1}')"

echo "ETH price:   \$$PRICE"
echo "Seed:        $(cast from-wei "$SEED_ETH") ETH + $(node -e "console.log($SEED_USDG/1e6)") USDG  (≈ \$$(node -e "console.log((2*$SEED_USDG/1e6).toFixed(2))"))"
echo "Deployer:    $(cast from-wei "$ETH_BAL") ETH, $(node -e "console.log($USDG_BAL/1e6)") USDG"
need_eth="$(node -e "console.log((BigInt('$SEED_ETH') + BigInt('$SMOKE_ETH') + BigInt('$GAS_RESERVE')).toString())")"
if [ "$(node -e "console.log(BigInt('$ETH_BAL') < BigInt('$need_eth'))")" = true ]; then
  echo "STOP: need $(cast from-wei "$need_eth") ETH on the deployer (seed + smoke swap + gas)."; exit 1
fi
if [ "$(node -e "console.log(BigInt('$USDG_BAL') < BigInt('$SEED_USDG'))")" = true ]; then
  echo "STOP: need $(node -e "console.log($SEED_USDG/1e6)") USDG on the deployer."; exit 1
fi
read -rp "Open WETH/USDG at \$$PRICE and seed it? [y/N] " ok
[ "$ok" = y ] || { echo "Nothing sent."; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
read -rsp "Keystore password for 'deployer': " pass; echo
printf '%s' "$pass" >"$TMP/pw"; chmod 600 "$TMP/pw"; unset pass
ADDR="$(cast wallet address --keystore "$KEYSTORE" --password-file "$TMP/pw")"
if [ "$(echo "$ADDR" | tr 'A-F' 'a-f')" != "$(echo "$DEPLOYER_ADDRESS" | tr 'A-F' 'a-f')" ]; then
  echo "STOP: keystore is $ADDR, expected $DEPLOYER_ADDRESS. Nothing was sent."; exit 1
fi

echo "1/2  Opening and seeding WETH/USDG"
cd "$ROOT/packages/contracts"
SEED_ETH="$SEED_ETH" SEED_USDG="$SEED_USDG" PRICE_USDG_PER_ETH="$PRICE6" forge script script/mainnet/SeedV1.s.sol:SeedV1 \
  --rpc-url "$RPC" --keystore "$KEYSTORE" --password-file "$TMP/pw" --sender "$DEPLOYER_ADDRESS" --broadcast --slow

echo "2/2  Smoke test: $(cast from-wei "$SMOKE_ETH") ETH -> USDG through the router"
KEY="($WETH,$USDG,8388608,10,$HOOK)"
DATA="$(cast abi-encode 'f((address,address,uint24,int24,address))' "$KEY")"
HOPS="[(1,0x0000000000000000000000000000000000000000,$WETH,$USDG,$DATA)]"
QUOTE="$(cast call "$ROUTER" 'quote((uint8,address,address,address,bytes)[],uint256)(uint256,uint256[])' "$HOPS" "$SMOKE_ETH" --rpc-url "$RPC" | head -1 | awk '{print $1}')"
[ "$QUOTE" != "0" ] || { echo "STOP: the router quotes 0; check the pool before going further."; exit 1; }
MIN="$(node -e "console.log((BigInt('$QUOTE') * 99n / 100n).toString())")"
cast send "$ROUTER" 'swap((uint8,address,address,address,bytes)[],uint256,uint256,address,uint256,bool)' "$HOPS" "$SMOKE_ETH" "$MIN" \
  "$DEPLOYER_ADDRESS" "$(( $(date +%s) + 600 ))" false --value "$SMOKE_ETH" \
  --keystore "$KEYSTORE" --password-file "$TMP/pw" --rpc-url "$RPC" --json >"$TMP/swap.json"
rm -f "$TMP/pw"
TX="$(node -e 'console.log(require(process.argv[1]).transactionHash)' "$TMP/swap.json")"
STATUS="$(node -e 'console.log(require(process.argv[1]).status)' "$TMP/swap.json")"
echo "     quote $(node -e "console.log($QUOTE/1e6)") USDG, swap ${STATUS/0x1/ok} $EXPLORER/tx/$TX"
echo "Done. Remaining: $(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC" -e) ETH"
