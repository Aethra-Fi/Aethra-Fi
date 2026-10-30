#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/verify-contracts.sh <testnet|mainnet>
# Verifies the source code of every Aethra Fi contract on the network's Blockscout explorer, then checks the result
# through the explorer API and writes the explorer links to docs/verification/<network>.md.
# Made for screen recording: the output shows contract names, addresses and explorer links, never local paths.
# Needs no keystore and sends no transaction. Safe to re-run: verified contracts are reported as already verified.
# VERIFIER=sourcify uses Sourcify instead of the Blockscout API (Blockscout reads Sourcify matches too).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NETWORK="${1:-}"
VERIFIER="${VERIFIER:-blockscout}"

case "$NETWORK" in
  testnet) CHAIN=46630; NAME="Robinhood Chain Testnet"; EXPLORER="https://explorer.testnet.chain.robinhood.com"; RPC="https://rpc.testnet.chain.robinhood.com" ;;
  mainnet) CHAIN=4663; NAME="Robinhood Chain"; EXPLORER="https://robinhoodchain.blockscout.com"; RPC="https://rpc.mainnet.chain.robinhood.com" ;;
  *) echo "usage: bash scripts/verify-contracts.sh <testnet|mainnet>"; exit 1 ;;
esac

B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'
cd "$ROOT/packages/contracts" || exit 1

echo "${B}Aethra Fi · smart contract verification${N}"
echo "Network   ${NAME} (chain ${CHAIN})"
echo "Explorer  ${EXPLORER}"
echo "Verifier  ${VERIFIER}"
echo

printf "Checking the chain ... "
[ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null)" = "$CHAIN" ] || { echo "${R}RPC did not answer with chain ${CHAIN}${N}"; exit 1; }
echo "${G}ok${N}"

if [ "$VERIFIER" = "blockscout" ]; then
  printf "Checking the explorer API ... "
  code="$(curl -s -o /dev/null -w '%{http_code}' "${EXPLORER}/api?module=block&action=eth_block_number")"
  if [ "$code" != "200" ]; then
    echo "${R}HTTP ${code}${N}"
    echo "The explorer API refused this connection (Cloudflare). Turn on a VPN and run again,"
    echo "or run: VERIFIER=sourcify bash scripts/verify-contracts.sh ${NETWORK}"
    exit 1
  fi
  echo "${G}ok${N}"
  VERIFY_ARGS=(--verifier blockscout --verifier-url "${EXPLORER}/api/")
else
  VERIFY_ARGS=(--verifier sourcify)
fi

printf "Compiling the contracts ... "
forge build --skip test >/dev/null 2>&1 || { echo "${R}forge build failed${N}"; exit 1; }
echo "${G}ok${N}"

LIST="$(cd "$ROOT" && node scripts/verify-list.mjs "$NETWORK" 2>/dev/null)" || { echo "${R}could not read the deployment records for ${NETWORK}${N}"; exit 1; }
TOTAL="$(printf '%s\n' "$LIST" | grep -c .)"
echo
echo "${B}${TOTAL} contracts to verify${N}"
echo

i=0; ok=0; failed=0
LABELS=(); ADDRS=()
while IFS=$'\t' read -r label address source args; do
  [ -n "$address" ] || continue
  i=$((i + 1))
  LABELS+=("$label"); ADDRS+=("$address")
  printf "${B}[%2d/%d]${N} %-36s %s\n" "$i" "$TOTAL" "$label" "$address"
  ARGS=("$address" "$source" "${VERIFY_ARGS[@]}" --chain "$CHAIN" --compiler-version 0.8.26 --compilation-profile default --watch)
  [ -n "$args" ] && ARGS+=(--constructor-args "$args")
  out="$(forge verify-contract "${ARGS[@]}" 2>&1 </dev/null)"
  if grep -qiE "already verified" <<<"$out"; then
    echo "        ${G}✓ already verified${N}"; ok=$((ok + 1))
  elif grep -qiE "successfully verified|Pass - Verified|verification successful|exact_match|^ *match" <<<"$out"; then
    echo "        ${G}✓ verified${N}"; ok=$((ok + 1))
  else
    reason="$(grep -iE "error|fail|reason|details" <<<"$out" | tail -1 | sed "s|$ROOT/||g" | cut -c1-140)"
    echo "        ${R}✗ ${reason:-not verified}${N}"; failed=$((failed + 1))
  fi
  echo "        ${D}${EXPLORER}/address/${address}?tab=contract${N}"
done <<<"$LIST"

echo
echo "${B}Checking the explorer for verified source code${N}"
shown=0
for idx in "${!ADDRS[@]}"; do
  a="${ADDRS[$idx]}"
  v="$(curl -s "${EXPLORER}/api/v2/addresses/${a}" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{console.log(JSON.parse(d).is_verified?"yes":"no")}catch{console.log("?")}})')"
  case "$v" in
    yes) mark="${G}✓ verified${N}" ;;
    no) mark="${Y}… not shown yet${N}" ;;
    *) mark="${Y}? explorer API unavailable${N}" ;;
  esac
  printf "  %-36s %s\n" "${LABELS[$idx]}" "$mark"
  shown=$((shown + 1))
done

# explorer links for the record
mkdir -p "$ROOT/docs/verification"
{
  echo "# Aethra Fi contract verification: ${NAME}"
  echo
  echo "Chain ID ${CHAIN}. Explorer: ${EXPLORER}. Verified with \`bash scripts/verify-contracts.sh ${NETWORK}\` on $(date -u +%Y-%m-%d)."
  echo
  echo "| Contract | Address | Explorer |"
  echo "|---|---|---|"
  for idx in "${!ADDRS[@]}"; do
    echo "| ${LABELS[$idx]} | \`${ADDRS[$idx]}\` | [source](${EXPLORER}/address/${ADDRS[$idx]}?tab=contract) |"
  done
} > "$ROOT/docs/verification/${NETWORK}.md"

echo
echo "${B}Result: ${G}${ok} verified${N}${B}, $([ "$failed" -gt 0 ] && echo "${R}" )${failed} failed${N} (of ${TOTAL})"
echo "Explorer links saved to docs/verification/${NETWORK}.md"
[ "$failed" -eq 0 ]
