#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/verify-v11.sh
# Release v1.1 verification on Robinhood Chain mainnet (DLMM, DAMM, DLMM limit orders), made for screen recording.
# Read-only: sends no transaction and needs no keystore. Each stage says what it proves, then checks it live:
#   1. network          the RPC answers as chain 4663
#   2. bytecode         every v1.1 contract has code on-chain
#   3. source code      Sourcify recompiled the published source to the exact deployed bytecode
#   4. wiring           proxies and beacons point at those verified implementations, and the modules at each other
#   5. control          the deployer owns every upgradeable piece, implementations cannot be initialized by anyone
#   6. release gate     the hub lets both factories create pools, which is what "v1.1 open" means on-chain
# Ends with a score, saves docs/verification/mainnet-v1.1.md and lets you open any contract on the explorer or Sourcify.
# FAST=1 skips the pacing between rows; NO_COLOR=1 prints without colors.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHAIN=4663
NAME="Robinhood Chain"
RPC="${MAINNET_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
EXPLORER="https://robinhoodchain.blockscout.com"
SOURCIFY="https://sourcify.dev/server"
SOURCIFY_REPO="https://repo.sourcify.dev"
DEPLOYER="0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C"
MANIFEST="$ROOT/packages/contracts/verification/mainnet/manifest.json"
ADDRESSES="$ROOT/packages/sdk/src/addresses/mainnet.json"
REPORT="$ROOT/docs/verification/mainnet-v1.1.md"
IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc # ERC-1967 implementation
INIT_SLOT=0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00 # OpenZeppelin Initializable (ERC-7201)

TTY=0; [ -t 0 ] && [ -t 1 ] && TTY=1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; [ "$TTY" = 1 ] && printf "\e[?25h"' EXIT
if [ "$TTY" = 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; L=$'\e[38;5;118m'; N=$'\e[0m'
else
  B=""; DIM=""; G=""; Y=""; R=""; C=""; L=""; N=""
fi
OK="${G}✓${N}"; BAD="${R}✗${N}"
PASS=0; FAIL=0
RULE="${DIM}──────────────────────────────────────────────────────────────────────${N}"

lc() { tr 'A-F' 'a-f' <<<"$1"; }
short() { echo "${1:0:6}…${1: -4}"; }
explorer() { echo "${EXPLORER}/address/$1?tab=contract"; }
sourcify_page() { echo "${SOURCIFY_REPO}/${CHAIN}/$1"; }
hyperlink() { if [ "$TTY" = 1 ]; then printf '\e]8;;%s\e\\%s\e]8;;\e\\' "$1" "${2:-$1}"; else printf '%s' "${2:-$1}"; fi; }
pause() { [ "$TTY" = 1 ] && { printf "\n  ${C}▸${N} %s ${DIM}[Enter]${N} " "$1"; read -r _; }; echo; }
pace() { [ "$TTY" = 1 ] && [ -z "${FAST:-}" ] && sleep "${1:-0.12}"; return 0; }
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); }

# run "$@" in the background behind a spinner; output lands in $TMP/out
spin() {
  local text="$1"; shift
  "$@" >"$TMP/out" 2>&1 &
  local pid=$! frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' k=0
  if [ "$TTY" = 1 ]; then
    printf "\e[?25l"
    while kill -0 "$pid" 2>/dev/null; do printf "\r  ${C}%s${N} %s" "${frames:k++%10:1}" "$text"; sleep 0.08; done
    printf "\r\e[K\e[?25h"
  fi
  wait "$pid"
}

stage() { # $1 number, $2 title, $3 what it proves
  echo "$RULE"
  echo "  ${L}${B}[$1/6]${N} ${B}$2${N}"
  echo "  ${DIM}$3${N}"
  echo
}

call() { cast call "$@" --rpc-url "$RPC" 2>/dev/null; }
slot_addr() { local v; v="$(cast storage "$1" "$2" --rpc-url "$RPC" 2>/dev/null)"; echo "0x${v: -40}"; }

# ------------------------------------------------------------------ the v1.1 contracts

for f in "$MANIFEST" "$ADDRESSES"; do
  [ -f "$f" ] || { echo "missing ${f#"$ROOT"/}"; exit 1; }
done
# label|address|role, in release order; addresses come from the deploy record
mapfile -t ROWS < <(node -e '
  const m = require(process.argv[1]);
  const want = [
    ["DLMM factory (proxy)", "proxy"], ["DLMM factory (implementation)", "impl"],
    ["DLMM pool beacon", "beacon"], ["DLMM pool (implementation)", "impl"],
    ["DLMM limit orders (proxy)", "proxy"], ["DLMM limit orders (implementation)", "impl"],
    ["DAMM factory (proxy)", "proxy"], ["DAMM factory (implementation)", "impl"],
    ["DAMM pool beacon", "beacon"], ["DAMM pool (implementation)", "impl"],
  ];
  for (const [label, role] of want) {
    const c = m.find((x) => x.label === label);
    if (!c) { console.error("not in manifest: " + label); process.exit(1); }
    console.log([label, c.address, role].join("|"));
  }' "$MANIFEST") || exit 1
TOTAL=${#ROWS[@]}
LABELS=(); ADDRS=(); ROLES=()
for r in "${ROWS[@]}"; do IFS='|' read -r l a ro <<<"$r"; LABELS+=("$l"); ADDRS+=("$a"); ROLES+=("$ro"); done
addr_of() { local i; for i in "${!LABELS[@]}"; do [ "${LABELS[$i]}" = "$1" ] && { echo "${ADDRS[$i]}"; return; }; done; }
HUB="$(node -p "require('$ADDRESSES').hub")"

# ------------------------------------------------------------------ intro

[ "$TTY" = 1 ] && clear
cat <<EOF

  ${L}${B}   ▄▀█ █▀▀ ▀█▀ █ █ █▀█ ▄▀█   █▀▀ █${N}
  ${L}${B}   █▀█ ██▄  █  █▀█ █▀▄ █▀█   █▀  █${N}

  ${B}Release v1.1 · contract verification${N}   ${DIM}DLMM · DAMM · limit orders${N}
$RULE
  Network     ${B}${NAME}${N} ${DIM}· chain ${CHAIN}${N}
  Explorer    ${EXPLORER}
  Verifier    Sourcify ${DIM}(independent source-code verification)${N}
  Owner       $(short "$DEPLOYER") ${DIM}Aethra deployer${N}
  Contracts   ${B}${TOTAL}${N} ${DIM}deployed for this release${N}

  ${DIM}Read-only: this script sends no transaction and holds no keys.${N}
EOF
pause "Press Enter to start the verification"

# ------------------------------------------------------------------ 1. network

stage 1 "Network" "Proves we are reading the real Robinhood Chain mainnet, live."
spin "Connecting to ${NAME}" cast chain-id --rpc-url "$RPC"
if [ "$(tr -d '[:space:]' <"$TMP/out")" = "$CHAIN" ]; then
  echo "  ${OK} Chain ID ${B}${CHAIN}${N} ${DIM}· ${NAME}${N}"; pass
else
  echo "  ${BAD} The RPC did not answer as chain ${CHAIN}"; exit 1
fi
spin "Reading the latest block" cast block-number --rpc-url "$RPC"
BLOCK="$(tr -d '[:space:]' <"$TMP/out")"
echo "  ${OK} Latest block ${B}$(printf "%'d" "$BLOCK" 2>/dev/null || echo "$BLOCK")${N} ${DIM}· $(date -u '+%Y-%m-%d %H:%M UTC')${N}"; pass
pace 0.3

# ------------------------------------------------------------------ 2. bytecode

pause "Next: bytecode on-chain"
stage 2 "Bytecode on-chain" "Proves each v1.1 contract exists at its address (code size and code hash)."
codecheck() { local code; code="$(cast code "$1" --rpc-url "$RPC")"; echo "$(((${#code} - 2) / 2)) $(cast keccak "$code")"; }
for i in "${!ADDRS[@]}"; do
  a="${ADDRS[$i]}"
  spin "$(printf "%2d/%d  %-36s reading code…" "$((i + 1))" "$TOTAL" "${LABELS[$i]}")" codecheck "$a"
  read -r size hash <"$TMP/out"
  if [ "${size:-0}" -gt 0 ] 2>/dev/null; then
    printf "  ${OK} ${DIM}%2d/%d${N}  %-36s ${DIM}%s${N}  %6s bytes  ${DIM}hash %s${N}\n" "$((i + 1))" "$TOTAL" "${LABELS[$i]}" "$(short "$a")" "$size" "$(short "$hash")"; pass
  else
    printf "  ${BAD} ${DIM}%2d/%d${N}  %-36s ${DIM}%s${N}  ${R}no code${N}\n" "$((i + 1))" "$TOTAL" "${LABELS[$i]}" "$(short "$a")"; fail
  fi
  pace
done

# ------------------------------------------------------------------ 3. source code

pause "Next: source code verification"
stage 3 "Source code" "Proves the published source compiles to exactly the bytecode on-chain.
  ${DIM}Exact match = same bytecode and same metadata hash, so nothing differs, not even comments.${N}"
sourcify() {
  curl -s --max-time 40 "${SOURCIFY}/v2/contract/${CHAIN}/$1?fields=compilation" | node -e '
    let d = ""; process.stdin.on("data", (c) => (d += c)).on("end", () => {
      try {
        const j = JSON.parse(d), c = j.compilation || {}, o = (c.compilerSettings || {}).optimizer || {};
        console.log([j.match || "none", c.name || "-", (c.compilerVersion || "-").split("+")[0], o.enabled ? o.runs : "off"].join(" "));
      } catch { console.log("none - - -"); }
    });'
}
VERIFIED=0
for i in "${!ADDRS[@]}"; do
  a="${ADDRS[$i]}"
  spin "$(printf "%2d/%d  %-36s asking Sourcify…" "$((i + 1))" "$TOTAL" "${LABELS[$i]}")" sourcify "$a"
  read -r match cname solc runs <"$TMP/out"
  case "$match" in
    exact_match) tag="${G}exact match${N}  "; mark="$OK"; pass; VERIFIED=$((VERIFIED + 1)) ;;
    match) tag="${Y}partial match${N}"; mark="$OK"; pass; VERIFIED=$((VERIFIED + 1)) ;;
    *) tag="${R}not verified${N} "; mark="$BAD"; fail ;;
  esac
  printf "  %s ${DIM}%2d/%d${N}  %-36s %s ${DIM}%-20s solc %s · optimizer %s${N}\n" "$mark" "$((i + 1))" "$TOTAL" "${LABELS[$i]}" "$tag" "$cname" "$solc" "$runs"
  pace
done
if [ "$VERIFIED" -lt "$TOTAL" ]; then
  echo
  echo "  ${Y}!${N} Missing contracts can be submitted with: ${B}bash scripts/verify-contracts.sh mainnet${N}"
fi

# ------------------------------------------------------------------ 4. wiring

pause "Next: how the contracts are wired"
stage 4 "Wiring" "Proves the live proxies run the verified code above, and the modules point at each other."
check() { # $1 label, $2 actual, $3 expected, $4 expected name
  if [ "$(lc "$2")" = "$(lc "$3")" ]; then
    printf "  ${OK} %-52s ${C}→${N} %-30s ${DIM}%s${N}\n" "$1" "$4" "$(short "$3")"; pass
  else
    printf "  ${BAD} %-52s ${R}→ %s${N} ${DIM}(expected %s)${N}\n" "$1" "$(short "$2")" "$(short "$3")"; fail
  fi
  pace
}
DLMM_F="$(addr_of "DLMM factory (proxy)")"; DAMM_F="$(addr_of "DAMM factory (proxy)")"; ORDERS="$(addr_of "DLMM limit orders (proxy)")"
DLMM_B="$(addr_of "DLMM pool beacon")"; DAMM_B="$(addr_of "DAMM pool beacon")"

echo "  ${B}Upgradeable proxies${N} ${DIM}(ERC-1967 implementation slot)${N}"
check "DLMM factory proxy runs" "$(slot_addr "$DLMM_F" $IMPL_SLOT)" "$(addr_of "DLMM factory (implementation)")" "DLMM factory implementation"
check "DLMM limit orders proxy runs" "$(slot_addr "$ORDERS" $IMPL_SLOT)" "$(addr_of "DLMM limit orders (implementation)")" "limit orders implementation"
check "DAMM factory proxy runs" "$(slot_addr "$DAMM_F" $IMPL_SLOT)" "$(addr_of "DAMM factory (implementation)")" "DAMM factory implementation"
echo
echo "  ${B}Pool beacons${N} ${DIM}(every new pool is a beacon proxy running this code)${N}"
check "DLMM factory creates pools from" "$(call "$DLMM_F" 'beacon()(address)')" "$DLMM_B" "DLMM pool beacon"
check "DLMM pool beacon runs" "$(call "$DLMM_B" 'implementation()(address)')" "$(addr_of "DLMM pool (implementation)")" "DLMM pool implementation"
check "DAMM factory creates pools from" "$(call "$DAMM_F" 'beacon()(address)')" "$DAMM_B" "DAMM pool beacon"
check "DAMM pool beacon runs" "$(call "$DAMM_B" 'implementation()(address)')" "$(addr_of "DAMM pool (implementation)")" "DAMM pool implementation"
echo
echo "  ${B}Module links${N}"
check "Limit orders accept pools from" "$(call "$ORDERS" 'factory()(address)')" "$DLMM_F" "DLMM factory"
check "DLMM factory registers pools in" "$(call "$DLMM_F" 'hub()(address)')" "$HUB" "AethraHub (v1.0 core)"
check "DAMM factory registers pools in" "$(call "$DAMM_F" 'hub()(address)')" "$HUB" "AethraHub (v1.0 core)"

# ------------------------------------------------------------------ 5. control

pause "Next: who controls the contracts"
stage 5 "Control" "Proves only the Aethra deployer can upgrade, and no one can take over an implementation."
echo "  ${B}Owner${N} ${DIM}(must be the deployer $(short "$DEPLOYER"))${N}"
for l in "DLMM factory (proxy)" "DLMM pool beacon" "DLMM limit orders (proxy)" "DAMM factory (proxy)" "DAMM pool beacon"; do
  check "$l owner" "$(call "$(addr_of "$l")" 'owner()(address)')" "$DEPLOYER" "Aethra deployer"
done
echo
echo "  ${B}Implementations locked${N} ${DIM}(initializers disabled at deploy, so they cannot be claimed)${N}"
MAXU64=18446744073709551615
for i in "${!ADDRS[@]}"; do
  [ "${ROLES[$i]}" = impl ] || continue
  v="$(cast to-dec "$(cast storage "${ADDRS[$i]}" $INIT_SLOT --rpc-url "$RPC" 2>/dev/null)" 2>/dev/null)"
  v="$(node -e "console.log((BigInt(process.argv[1] || 0) & ((1n << 64n) - 1n)).toString())" "${v:-0}")"
  if [ "$v" = "$MAXU64" ]; then
    printf "  ${OK} %-52s ${C}→${N} %-30s\n" "${LABELS[$i]}" "locked"; pass
  else
    printf "  ${BAD} %-52s ${R}→ initializer version %s${N}\n" "${LABELS[$i]}" "$v"; fail
  fi
  pace
done

# ------------------------------------------------------------------ 6. release gate

pause "Next: is v1.1 open?"
stage 6 "Release gate" "Proves v1.1 is live: the hub only accepts new pools from factories it allows."
gate() { # $1 label, $2 factory
  if [ "$(call "$HUB" 'isRegistrar(address)(bool)' "$2")" = true ]; then
    printf "  ${OK} %-52s ${G}${B}OPEN${N}\n" "$1"; pass
  else
    printf "  ${BAD} %-52s ${R}${B}LOCKED${N}\n" "$1"; fail
  fi
  pace
}
gate "DLMM pools + limit orders (DLMM factory)" "$DLMM_F"
gate "DAMM pools (DAMM factory)" "$DAMM_F"
count() { call "$1" 'poolCount()(uint256)' | awk '{print $1}'; }
echo
echo "  ${DIM}Pools created so far: DLMM $(count "$DLMM_F") · DAMM $(count "$DAMM_F")${N}"

# ------------------------------------------------------------------ summary

TOTAL_CHECKS=$((PASS + FAIL))
echo
echo "$RULE"
if [ "$FAIL" -eq 0 ]; then
  echo
  echo "  ${G}${B}✓ Aethra Fi v1.1 verified: ${PASS} of ${TOTAL_CHECKS} checks passed${N}"
  echo "  ${DIM}${VERIFIED}/${TOTAL} contracts source-verified · proxies and beacons run verified code"
  echo "  · deployer-owned · implementations locked · DLMM and DAMM open on ${NAME}${N}"
else
  echo
  echo "  ${Y}${B}${PASS} of ${TOTAL_CHECKS} checks passed, ${FAIL} failed${N}"
fi
echo

mkdir -p "$(dirname "$REPORT")"
{
  echo "# Aethra Fi v1.1 contract verification: ${NAME}"
  echo
  echo "Chain ID ${CHAIN}, block ${BLOCK}. Checked with \`bash scripts/verify-v11.sh\` on $(date -u +%Y-%m-%d): ${PASS} of ${TOTAL_CHECKS} checks passed."
  echo
  echo "| # | Contract | Address | Explorer | Sourcify |"
  echo "|---|---|---|---|---|"
  for i in "${!ADDRS[@]}"; do
    echo "| $((i + 1)) | ${LABELS[$i]} | \`${ADDRS[$i]}\` | [source code]($(explorer "${ADDRS[$i]}")) | [files]($(sourcify_page "${ADDRS[$i]}")) |"
  done
} >"$REPORT"
echo "  ${DIM}Report saved to docs/verification/mainnet-v1.1.md${N}"
echo

# ------------------------------------------------------------------ explore

if [ "$TTY" = 1 ]; then
  opener="$(command -v xdg-open || command -v open || true)"
  menu() {
    echo "  ${B}Contracts${N}"
    for i in "${!ADDRS[@]}"; do
      printf "   ${C}%2d${N}  %-36s %s\n" "$((i + 1))" "${LABELS[$i]}" "$(hyperlink "$(explorer "${ADDRS[$i]}")" "${ADDRS[$i]}")"
    done
    echo
    echo "  ${DIM}Type a number to open it on the explorer, s + number for Sourcify (e.g. s3), l to list again, q to quit.${N}"
  }
  menu
  while :; do
    printf "  ${C}▸${N} "
    read -r pick || break
    case "$pick" in
      q | Q) break ;;
      l | L) echo; menu; continue ;;
      s[0-9]* | S[0-9]*) n="${pick:1}"; site=sourcify ;;
      *) n="$pick"; site=explorer ;;
    esac
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$TOTAL" ]; then
      a="${ADDRS[$((n - 1))]}"
      if [ "$site" = sourcify ]; then url="$(sourcify_page "$a")"; else url="$(explorer "$a")"; fi
      echo "    ${OK} ${LABELS[$((n - 1))]}  ${DIM}${url}${N}"
      [ -n "$opener" ] && "$opener" "$url" >/dev/null 2>&1 &
    else
      echo "    ${DIM}pick 1-${TOTAL}, s1-s${TOTAL}, l or q${N}"
    fi
  done
  echo
fi
[ "$FAIL" -eq 0 ]
