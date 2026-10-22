#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/local-activity.sh
# Generates real activity on the local Anvil fork (after scripts/local-deploy.sh) so every indexer handler
# and app page has data: v4/DLMM/DAMM pools, swaps through the router, a limit order, a launch, a v4
# position, and a loan. Uses impersonation only (no keys).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC="${LOCAL_RPC_URL:-http://127.0.0.1:8545}"
J="$ROOT/packages/sdk/src/addresses/local.json"
get() { node -e "const j=require('$J');console.log($1)"; }

DEPLOYER=$(get j.deployer)
TRADER=0x00000000000000000000000000000000000A1E7A
WETH=$(get j.weth); AUSD=$(get j.tokens.aUSD.address); HOOK=$(get j.hook); ROUTER=$(get j.router); POS=$(get j.positions)
DLMMF=$(get j.dlmmFactory); ORDERS=$(get j.dlmmLimitOrders); DAMMF=$(get j.dammFactory); LP=$(get j.launchpad)
VAULT=$(get j.lendingVault); CM=$(get j.creditManager)
MAX=0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
DL=$(( $(date +%s) + 3600 ))
ZERO=0x0000000000000000000000000000000000000000

send() { local from=$1; shift; cast send --unlocked --from "$from" --rpc-url "$RPC" "$@" >/dev/null; }
call() { cast call --rpc-url "$RPC" "$@"; }

echo "funding trader"
cast rpc anvil_setBalance "$TRADER" 0x3635C9ADC5DEA00000 --rpc-url "$RPC" >/dev/null # 1000 ETH
send "$TRADER" "$WETH" "deposit()" --value 50ether
send "$DEPLOYER" "$AUSD" "mint(address,uint256)" "$TRADER" 1000000000000 # 1,000,000 aUSD
for spender in "$ROUTER" "$POS" "$ORDERS" "$VAULT" "$CM"; do
  send "$TRADER" "$WETH" "approve(address,uint256)" "$spender" $MAX
  send "$TRADER" "$AUSD" "approve(address,uint256)" "$spender" $MAX
done

# WETH sorts before aUSD here, so token0 = WETH and prices are aUSD per WETH
[ "$(node -e "console.log(BigInt('$WETH') < BigInt('$AUSD'))")" = "true" ] || { echo "expected WETH < aUSD"; exit 1; }
V4KEY="($WETH,$AUSD,8388608,10,$HOOK)"

echo "v4: deep liquidity and swaps on WETH/aUSD"
# full range, ~10 WETH + 24,000 aUSD at 2400: L = sqrt(x*y) for full range
send "$TRADER" "$POS" "mint(((address,address,uint24,int24,address),int24,int24,uint128,uint256,uint256,address,uint256))" \
  "($V4KEY,-887270,887270,489897948556635,20000000000000000000,48000000000,$TRADER,$DL)"
V4DATA=$(cast abi-encode "f((address,address,uint24,int24,address))" "$V4KEY")
send "$TRADER" "$ROUTER" "swap((uint8,address,address,address,bytes)[],uint256,uint256,address,uint256,bool)" \
  "[(1,$ZERO,$WETH,$AUSD,$V4DATA)]" 500000000000000000 0 "$TRADER" $DL false
send "$TRADER" "$ROUTER" "swap((uint8,address,address,address,bytes)[],uint256,uint256,address,uint256,bool)" \
  "[(1,$ZERO,$AUSD,$WETH,$V4DATA)]" 800000000 0 "$TRADER" $DL false

echo "DLMM: pool, shaped liquidity, swap, limit order"
send "$TRADER" "$DLMMF" "createPool((address,address,uint16,int24,uint24,uint24))" "($WETH,$AUSD,25,-7949,3000,50000)"
DLMM=$(call "$DLMMF" "getPool(address,address,uint16)(address)" "$WETH" "$AUSD" 25)
IDS="[-7954,-7953,-7952,-7951,-7950,-7949,-7948,-7947,-7946,-7945,-7944]"
A0="[0,0,0,0,0,1000000000000000000,1000000000000000000,1000000000000000000,1000000000000000000,1000000000000000000,1000000000000000000]"
A1="[2400000000,2400000000,2400000000,2400000000,2400000000,2400000000,0,0,0,0,0]"
send "$TRADER" "$WETH" "approve(address,uint256)" "$DLMM" $MAX
send "$TRADER" "$AUSD" "approve(address,uint256)" "$DLMM" $MAX
send "$TRADER" "$DLMM" "addLiquidity(int24[],uint256[],uint256[],address,uint256)" "$IDS" "$A0" "$A1" "$TRADER" $DL
send "$TRADER" "$ORDERS" "place(address,int24,uint8,uint256,uint256)" "$DLMM" -7946 0 100000000000000000 $DL
# buy WETH with aUSD through the router until the order's bin is crossed
send "$TRADER" "$ROUTER" "swap((uint8,address,address,address,bytes)[],uint256,uint256,address,uint256,bool)" \
  "[(2,$DLMM,$AUSD,$WETH,0x)]" 12000000000 0 "$TRADER" $DL false
echo "  active bin: $(call "$DLMM" "activeId()(int24)"), order status: $(call "$ORDERS" "status(uint256)(uint8)" 1) (3 = filled)"
send "$TRADER" "$ORDERS" "claimFor(uint256)" 1 || true

echo "DAMM: full-range pool with launch fee, deposit, swap"
SQRT=$(node -e "const p=2400*1e6/1e18;console.log((BigInt(Math.round(Math.sqrt(p)*2**48))<<48n).toString())")
send "$TRADER" "$DAMMF" "createPool((address,address,uint160,uint160,uint160,uint24,uint24,uint24,uint32))" "($WETH,$AUSD,$SQRT,0,0,3000,50000,100000,21600)"
DAMM=$(call "$DAMMF" "poolsForPair(address,address)(address[])" "$WETH" "$AUSD" | tr -d '[]' | cut -d, -f1)
send "$TRADER" "$WETH" "approve(address,uint256)" "$DAMM" $MAX
send "$TRADER" "$AUSD" "approve(address,uint256)" "$DAMM" $MAX
send "$TRADER" "$DAMM" "addLiquidity(uint256,uint256,uint256,address,uint256)" 2000000000000000000 4800000000 0 "$TRADER" $DL
send "$TRADER" "$ROUTER" "swap((uint8,address,address,address,bytes)[],uint256,uint256,address,uint256,bool)" \
  "[(3,$DAMM,$WETH,$AUSD,0x)]" 100000000000000000 0 "$TRADER" $DL false

echo "launchpad: create with a first buy, then trade on the curve"
send "$TRADER" "$LP" "create(string,string,string,uint256)" "Aethra Demo" "ADEMO" "" 0 --value 0.3ether
TOKEN=$(call "$LP" "launches()(address[])" | tr -d '[]' | awk -F', ' '{print $NF}')
LDATA=$(cast abi-encode "f(address)" "$TOKEN")
send "$TRADER" "$ROUTER" "swap((uint8,address,address,address,bytes)[],uint256,uint256,address,uint256,bool)" \
  "[(4,$LP,$WETH,$TOKEN,$LDATA)]" 1000000000000000000 0 "$TRADER" $DL false
send "$TRADER" "$TOKEN" "approve(address,uint256)" "$ROUTER" $MAX
send "$TRADER" "$ROUTER" "swap((uint8,address,address,address,bytes)[],uint256,uint256,address,uint256,bool)" \
  "[(4,$LP,$TOKEN,$WETH,$LDATA)]" 10000000000000000000000000 0 "$TRADER" $DL false

echo "credit: supply the vault, pledge the v4 position, borrow"
send "$TRADER" "$VAULT" "deposit(uint256,address)" 100000000000 "$TRADER" # 100,000 aUSD
send "$TRADER" "$POS" "setApprovalForAll(address,bool)" "$CM" true
POSID=$(( $(call "$POS" "nextTokenId()(uint256)") - 1 ))
send "$TRADER" "$CM" "pledge(uint256)" $POSID
send "$TRADER" "$CM" "borrow(uint256,uint256,address)" $POSID 5000000000 "$TRADER" # 5,000 aUSD

echo "done: trader $TRADER, DLMM $DLMM, DAMM $DAMM, launch $TOKEN, position #$POSID"
