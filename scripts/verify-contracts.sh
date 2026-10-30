#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/verify-contracts.sh <testnet|mainnet>
# Interactive explorer verification of every Aethra Fi contract, made for screen recording: the output shows contract
# names, addresses and explorer links, never local paths. Sends no transaction and needs no keystore.
#
# Each contract is submitted with a source package prepared by scripts/verify-prepare.mjs, which already proved
# locally that the package compiles to the exact bytes deployed on-chain. Missing packages are prepared first.
# After submitting, the script reads every contract back from the explorer API as proof, saves the links to
# docs/verification/<network>.md and lets you open any contract on the explorer.
# Safe to re-run: verified contracts show as already verified.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NETWORK="${1:-}"

case "$NETWORK" in
  testnet) CHAIN=46630; NAME="Robinhood Chain Testnet"; EXPLORER="https://explorer.testnet.chain.robinhood.com"; RPC="https://rpc.testnet.chain.robinhood.com" ;;
  mainnet) CHAIN=4663; NAME="Robinhood Chain"; EXPLORER="https://robinhoodchain.blockscout.com"; RPC="https://rpc.mainnet.chain.robinhood.com" ;;
  *) echo "usage: bash scripts/verify-contracts.sh <testnet|mainnet>"; exit 1 ;;
esac

PKG="$ROOT/packages/contracts/verification/$NETWORK"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; printf "\e[?25h"' EXIT
TTY=0; [ -t 0 ] && [ -t 1 ] && TTY=1

if [ "$TTY" = 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; L=$'\e[38;5;118m'; N=$'\e[0m'
else
  B=""; DIM=""; G=""; Y=""; R=""; C=""; L=""; N=""
fi
OK="${G}✓${N}"; BAD="${R}✗${N}"

short() { echo "${1:0:6}…${1: -4}"; }
link() { echo "${EXPLORER}/address/$1?tab=contract"; }
pause() { [ "$TTY" = 1 ] && { printf "  ${C}?${N} %s ${DIM}[Enter]${N} " "$1"; read -r _; }; }

# run "$@" in the background with a spinner and a status text; the command's output goes to $TMP/out
spin() {
  local text="$1"; shift
  "$@" >"$TMP/out" 2>&1 &
  local pid=$! frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' k=0
  if [ "$TTY" = 1 ]; then
    printf "\e[?25l"
    while kill -0 "$pid" 2>/dev/null; do
      printf "\r  ${C}%s${N} %s" "${frames:k++%10:1}" "$text"; sleep 0.1
    done
    printf "\r\e[K\e[?25h"
  fi
  wait "$pid"
}

api() { curl -s --max-time 60 "$@"; }
json() { node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const j=JSON.parse(d);console.log(eval(process.argv[1])??"")}catch{console.log("")}})' "$1"; }

# ------------------------------------------------------------------ intro

clear 2>/dev/null || true
echo
echo "  ${L}${B}◆ AETHRA FI${N}  ${B}Smart contract verification${N}"
echo "  ${DIM}────────────────────────────────────────────────────────────${N}"
echo "  Network    ${B}${NAME}${N} ${DIM}· chain ${CHAIN}${N}"
echo "  Explorer   ${EXPLORER}"
echo "  Method     source code compiled by the explorer and matched"
echo "             against the bytecode deployed on-chain"
echo

# ------------------------------------------------------------------ checks

echo "  ${B}Checks${N}"
spin "Connecting to ${NAME}" cast chain-id --rpc-url "$RPC"
if [ "$(tr -d '[:space:]' <"$TMP/out")" = "$CHAIN" ]; then echo "  ${OK} Chain online (${CHAIN})"; else echo "  ${BAD} Chain did not answer"; exit 1; fi

spin "Connecting to the explorer" curl -s -o /dev/null -w '%{http_code}' --max-time 30 "${EXPLORER}/api?module=block&action=eth_block_number"
if [ "$(cat "$TMP/out")" = "200" ]; then
  echo "  ${OK} Explorer API online"
else
  echo "  ${BAD} Explorer API refused the connection (HTTP $(cat "$TMP/out"))"
  [ "$NETWORK" = mainnet ] && echo "    ${DIM}The mainnet explorer is behind Cloudflare: turn on a VPN and run again.${N}"
  exit 1
fi

if [ ! -f "$PKG/manifest.json" ]; then
  spin "Preparing source packages (compiling and matching bytecode)" bash -c "cd '$ROOT' && node scripts/verify-prepare.mjs '$NETWORK' --quiet"
  [ -f "$PKG/manifest.json" ] || { echo "  ${BAD} Could not prepare the source packages"; exit 1; }
fi
TOTAL="$(node -e "console.log(require('$PKG/manifest.json').length)")"
echo "  ${OK} ${TOTAL} source packages ready, each proven to match its on-chain bytecode"
echo

pause "Press Enter to verify ${TOTAL} contracts"
echo

# ------------------------------------------------------------------ submit

submit() { # $1 manifest index -> prints: verified | already | failed:<reason>
  local i="$1" address name args file guid res status tries
  read -r address name args file < <(node -e "const m=require('$PKG/manifest.json')[$i];console.log(m.address,m.contractName,m.args||'-',m.file)")
  [ "$args" = "-" ] && args=""
  # the explorer answers a second submission with a failure, so ask first
  if [ "$(api "${EXPLORER}/api/v2/addresses/${address}" | json 'j.is_verified ? "yes" : "no"')" = yes ]; then echo already; return; fi
  res="$(api -X POST "${EXPLORER}/api" \
    --data-urlencode "module=contract" --data-urlencode "action=verifysourcecode" \
    --data-urlencode "codeformat=solidity-standard-json-input" \
    --data-urlencode "contractaddress=${address}" --data-urlencode "contractname=${name}" \
    --data-urlencode "compilerversion=v0.8.26+commit.8a97fa7a" \
    --data-urlencode "constructorArguements=${args}" \
    --data-urlencode "sourceCode@${PKG}/${file}")"
  if grep -qi "already verified" <<<"$res"; then echo already; return; fi
  status="$(json 'j.status' <<<"$res")"; guid="$(json 'j.result' <<<"$res")"
  [ "$status" = "1" ] || { echo "failed:$(json 'j.result||j.message' <<<"$res" | cut -c1-80)"; return; }
  for tries in $(seq 1 60); do
    sleep 3
    res="$(api "${EXPLORER}/api?module=contract&action=checkverifystatus&guid=${guid}")"
    case "$(json 'j.result' <<<"$res")" in
      *"Pass"*|*"pass"*) echo verified; return ;;
      *"lready"*) echo already; return ;;
      *"Pending"*|*"pending"*|*"queue"*|"") ;;
      *) echo "failed:$(json 'j.result' <<<"$res" | cut -c1-80)"; return ;;
    esac
  done
  echo "failed:timed out waiting for the explorer"
}

echo "  ${B}Verifying${N}"
ok=0; failed=0
LABELS=(); ADDRS=()
for ((i = 0; i < TOTAL; i++)); do
  address="$(node -e "console.log(require('$PKG/manifest.json')[$i].address)")"
  label="$(node -e "console.log(require('$PKG/manifest.json')[$i].label)")"
  LABELS+=("$label"); ADDRS+=("$address")
  head="$(printf "${DIM}%2d/%d${N}  %-36s ${DIM}%s${N}" "$((i + 1))" "$TOTAL" "$label" "$(short "$address")")"
  spin "$(printf "%s  verifying…" "$head")" submit "$i"
  result="$(tail -1 "$TMP/out")"
  case "$result" in
    verified) printf "  ${OK} %s  ${G}verified${N}\n" "$head"; ok=$((ok + 1)) ;;
    already) printf "  ${OK} %s  ${G}already verified${N}\n" "$head"; ok=$((ok + 1)) ;;
    *) printf "  ${BAD} %s  ${R}%s${N}\n" "$head" "${result#failed:}"; failed=$((failed + 1)) ;;
  esac
done
echo

# ------------------------------------------------------------------ proof

echo "  ${B}Proof from the explorer${N} ${DIM}(read back from ${EXPLORER#https://})${N}"
proven=0
for idx in "${!ADDRS[@]}"; do
  a="${ADDRS[$idx]}"; v=""
  for t in 1 2 3 4 5; do
    v="$(api "${EXPLORER}/api/v2/addresses/${a}" | json 'j.is_verified ? "yes" : "no"')"
    [ "$v" = yes ] && break; sleep 2
  done
  if [ "$v" = yes ]; then mark="$OK"; proven=$((proven + 1)); else mark="$BAD"; fi
  printf "  %s %2d  %-36s %s\n" "$mark" "$((idx + 1))" "${LABELS[$idx]}" "$(link "$a")"
done

mkdir -p "$ROOT/docs/verification"
{
  echo "# Aethra Fi contract verification: ${NAME}"
  echo
  echo "Chain ID ${CHAIN}. Explorer: ${EXPLORER}. Verified with \`bash scripts/verify-contracts.sh ${NETWORK}\` on $(date -u +%Y-%m-%d)."
  echo
  echo "| # | Contract | Address | Explorer |"
  echo "|---|---|---|---|"
  for idx in "${!ADDRS[@]}"; do
    echo "| $((idx + 1)) | ${LABELS[$idx]} | \`${ADDRS[$idx]}\` | [source code]($(link "${ADDRS[$idx]}")) |"
  done
} >"$ROOT/docs/verification/${NETWORK}.md"

echo
echo "  ${DIM}────────────────────────────────────────────────────────────${N}"
if [ "$proven" -eq "$TOTAL" ]; then
  echo "  ${G}${B}✓ ${proven} of ${TOTAL} contracts verified on ${NAME}${N}"
else
  echo "  ${Y}${B}${proven} of ${TOTAL} contracts verified on ${NAME}${N} ${DIM}(${failed} failed)${N}"
fi
echo "  ${DIM}Links saved to docs/verification/${NETWORK}.md${N}"
echo

# ------------------------------------------------------------------ open on the explorer

if [ "$TTY" = 1 ]; then
  opener="$(command -v xdg-open || command -v open || true)"
  while :; do
    printf "  ${C}?${N} Open a contract on the explorer ${DIM}[1-%d, Enter = 1, q = quit]${N} " "$TOTAL"
    read -r pick
    [ "$pick" = q ] || [ "$pick" = Q ] && break
    [ -z "$pick" ] && pick=1
    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$TOTAL" ]; then
      url="$(link "${ADDRS[$((pick - 1))]}")"
      echo "    ${LABELS[$((pick - 1))]}  ${url}"
      [ -n "$opener" ] && "$opener" "$url" >/dev/null 2>&1 &
    fi
  done
  echo
fi
[ "$proven" -eq "$TOTAL" ]
