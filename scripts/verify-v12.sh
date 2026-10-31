#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/verify-v12.sh
# Release v1.2 verification on Robinhood Chain mainnet (stock pools with the oracle guard), made for screen recording.
# Read-only: sends no transaction and needs no keystore. v1.2 is configuration in the hub, so it checks the three
# contracts that run the oracle guard (hub, v4 hook, router) and the Chainlink feeds the hub reads. Each stage says
# what it proves, then checks it live:
#   1. network          the RPC answers as chain 4663
#   2. bytecode         the Aethra contracts, the 5 Chainlink feeds and the 3 stock tokens have code on-chain
#   3. source code      Sourcify recompiled the published source to the exact deployed bytecode
#   4. wiring           proxies run those verified implementations, hook and router read the same hub
#   5. price feeds      the hub knows a Chainlink feed per asset (feed, class, staleness window) and reads a live price
#   6. release gate     TSLA, NVDA and AAPL are enabled in the hub, which is what "v1.2 open" means on-chain
# Ends with a score, saves docs/verification/mainnet-v1.2.md and lets you open any contract on the explorer or Sourcify.
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
REPORT="$ROOT/docs/verification/mainnet-v1.2.md"
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

# ------------------------------------------------------------------ the v1.2 contracts

for f in "$MANIFEST" "$ADDRESSES"; do
  [ -f "$f" ] || { echo "missing ${f#"$ROOT"/}"; exit 1; }
done
# label|address|role, in release order; addresses come from the deploy record
mapfile -t ROWS < <(node -e '
  const m = require(process.argv[1]);
  const want = [
    ["AethraHub (proxy)", "proxy"], ["AethraHub (implementation)", "impl"],
    ["AethraHook (proxy)", "proxy"], ["AethraHook (implementation)", "impl"],
    ["AethraRouter (proxy)", "proxy"], ["AethraRouter (implementation)", "impl"],
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
PM="$(node -p "require('$ADDRESSES').poolManager")"

# assets the hub reads a feed for: symbol|token|feed|class (1 canonical, 2 stock); tokens and feeds come from the address file
mapfile -t ASSETS < <(node -e '
  const j = require(process.argv[1]);
  for (const s of ["TSLA", "NVDA", "AAPL", "WETH", "USDG"]) {
    const t = j.tokens[s], f = j.oracles[s];
    if (!t || !f) { console.error("not in mainnet.json: " + s); process.exit(1); }
    console.log([s, t.address, f, t.kind === "stock" ? 2 : 1].join("|"));
  }' "$ADDRESSES") || exit 1
# external contracts (Chainlink feeds, Robinhood stock tokens): bytecode only, they are not Aethra source
XLABELS=(); XADDRS=()
for r in "${ASSETS[@]}"; do
  IFS='|' read -r s t f c <<<"$r"
  XLABELS+=("$s / USD Chainlink feed"); XADDRS+=("$f")
done
for r in "${ASSETS[@]}"; do
  IFS='|' read -r s t f c <<<"$r"
  [ "$c" = 2 ] && { XLABELS+=("$s stock token"); XADDRS+=("$t"); }
done
XTOTAL=${#XADDRS[@]}
ALL_LABELS=("${LABELS[@]}" "${XLABELS[@]}"); ALL_ADDRS=("${ADDRS[@]}" "${XADDRS[@]}")
ALLTOTAL=${#ALL_ADDRS[@]}

# ------------------------------------------------------------------ intro

[ "$TTY" = 1 ] && clear
cat <<EOF

  ${L}${B}   ▄▀█ █▀▀ ▀█▀ █ █ █▀█ ▄▀█   █▀▀ █${N}
  ${L}${B}   █▀█ ██▄  █  █▀█ █▀▄ █▀█   █▀  █${N}

  ${B}Release v1.2 · contract verification${N}   ${DIM}stock pools · oracle guard${N}
$RULE
  Network     ${B}${NAME}${N} ${DIM}· chain ${CHAIN}${N}
  Explorer    ${EXPLORER}
  Verifier    Sourcify ${DIM}(independent source-code verification)${N}
  Contracts   ${B}${TOTAL}${N} ${DIM}Aethra contracts behind the oracle guard${N}
  Oracles     ${B}${XTOTAL}${N} ${DIM}Chainlink feeds and Robinhood stock tokens they price${N}

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
stage 2 "Bytecode on-chain" "Proves each contract exists at its address (code size and code hash)."
codecheck() { local code; code="$(cast code "$1" --rpc-url "$RPC")"; echo "$(((${#code} - 2) / 2)) $(cast keccak "$code")"; }
for i in "${!ALL_ADDRS[@]}"; do
  a="${ALL_ADDRS[$i]}"
  [ "$i" = "$TOTAL" ] && { echo; echo "  ${DIM}Chainlink price feeds and the Robinhood stock tokens they price (not Aethra source):${N}"; }
  spin "$(printf "%2d/%d  %-36s reading code…" "$((i + 1))" "$ALLTOTAL" "${ALL_LABELS[$i]}")" codecheck "$a"
  read -r size hash <"$TMP/out"
  if [ "${size:-0}" -gt 0 ] 2>/dev/null; then
    printf "  ${OK} ${DIM}%2d/%d${N}  %-36s ${DIM}%s${N}  %6s bytes  ${DIM}hash %s${N}\n" "$((i + 1))" "$ALLTOTAL" "${ALL_LABELS[$i]}" "$(short "$a")" "$size" "$(short "$hash")"; pass
  else
    printf "  ${BAD} ${DIM}%2d/%d${N}  %-36s ${DIM}%s${N}  ${R}no code${N}\n" "$((i + 1))" "$ALLTOTAL" "${ALL_LABELS[$i]}" "$(short "$a")"; fail
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
stage 4 "Wiring" "Proves the live proxies run the verified code above, and hook and router read the same hub."
check() { # $1 label, $2 actual, $3 expected, $4 expected name
  if [ "$(lc "$2")" = "$(lc "$3")" ]; then
    printf "  ${OK} %-52s ${C}→${N} %-30s ${DIM}%s${N}\n" "$1" "$4" "$(short "$3")"; pass
  else
    printf "  ${BAD} %-52s ${R}→ %s${N} ${DIM}(expected %s)${N}\n" "$1" "$(short "$2")" "$(short "$3")"; fail
  fi
  pace
}
HOOK="$(addr_of "AethraHook (proxy)")"; ROUTER="$(addr_of "AethraRouter (proxy)")"

echo "  ${B}Upgradeable proxies${N} ${DIM}(ERC-1967 implementation slot)${N}"
check "Hub proxy runs" "$(slot_addr "$HUB" $IMPL_SLOT)" "$(addr_of "AethraHub (implementation)")" "AethraHub implementation"
check "Hook proxy runs" "$(slot_addr "$HOOK" $IMPL_SLOT)" "$(addr_of "AethraHook (implementation)")" "AethraHook implementation"
check "Router proxy runs" "$(slot_addr "$ROUTER" $IMPL_SLOT)" "$(addr_of "AethraRouter (implementation)")" "AethraRouter implementation"
echo
echo "  ${B}Module links${N}"
check "Oracle hook reads prices and assets from" "$(call "$HOOK" 'hub()(address)')" "$HUB" "AethraHub"
check "Router reads routes from" "$(call "$ROUTER" 'hub()(address)')" "$HUB" "AethraHub"
check "Oracle hook is a Uniswap v4 hook of" "$(call "$HOOK" 'poolManager()(address)')" "$PM" "Uniswap v4 PoolManager"
if [ "$(call "$HUB" 'isRegistrar(address)(bool)' "$HOOK")" = true ]; then
  printf "  ${OK} %-52s ${C}→${N} %-30s\n" "Hub accepts v4 pools from the hook" "registrar"; pass
else
  printf "  ${BAD} %-52s ${R}→ not a registrar${N}\n" "Hub accepts v4 pools from the hook"; fail
fi
pace

# ------------------------------------------------------------------ 5. price feeds

pause "Next: the Chainlink price feeds"
stage 5 "Price feeds" "Proves the hub holds a Chainlink feed for each asset, with a staleness window, and reads a live price.
  ${DIM}A stock pool needs a fresh feed for both of its tokens. When a feed is older than its window the pool stops swapping.${N}"
NOW="$(cast block latest --field timestamp --rpc-url "$RPC" 2>/dev/null)"
STALE=0
feed_row() { # symbol token feed class
  local sym="$1" token="$2" feed="$3" cls="$4" desc dec round answer updated reg_cls reg_en reg_feed reg_win p fresh line fmt
  desc="$(call "$feed" 'description()(string)' | tr -d '"')"
  dec="$(call "$feed" 'decimals()(uint8)')"
  round="$(call "$feed" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)')"
  answer="$(sed -n 2p <<<"$round" | awk '{print $1}')"; updated="$(sed -n 4p <<<"$round" | awk '{print $1}')"
  mapfile -t reg < <(call "$HUB" 'asset(address)(uint8,bool,address,uint32)' "$token" | awk '{print $1}')
  reg_cls="${reg[0]:-0}"; reg_en="${reg[1]:-false}"; reg_feed="${reg[2]:-0x0}"; reg_win="${reg[3]:-0}"
  fresh="$(call "$HUB" 'tryGetPrice(address)(uint256,bool,bool)' "$token" | sed -n 2p | awk '{print $1}')"
  fmt="$(node -e '
    const [ans, dec, upd, now, win] = process.argv.slice(1).map(BigInt);
    const p = Number(ans) / 10 ** Number(dec);
    const age = Number(now - upd), h = age / 3600, w = Number(win) / 3600;
    console.log([p.toLocaleString("en-US", { style: "currency", currency: "USD" }), h < 1 ? Math.round(age / 60) + "m" : h < 48 ? h.toFixed(1) + "h" : (h / 24).toFixed(1) + "d", w + "h"].join(" "));
  ' "${answer:-0}" "${dec:-8}" "${updated:-0}" "$NOW" "$reg_win")"
  read -r price age win <<<"$fmt"
  if [ "$reg_cls" = "$cls" ] && [ "$reg_en" = true ] && [ "$(lc "$reg_feed")" = "$(lc "$feed")" ] && [ "${answer:-0}" -gt 0 ] 2>/dev/null; then
    if [ "$fresh" = true ]; then st="${G}live${N}"; else st="${Y}paused${N}"; STALE=$((STALE + 1)); fi
    printf "  ${OK} %-6s %-24s ${B}%11s${N}  ${DIM}updated %5s ago · window %-4s${N} %s\n" "$sym" "$desc" "$price" "$age" "$win" "$st"; pass
  else
    printf "  ${BAD} %-6s ${R}hub entry differs from the feed in the address file${N} ${DIM}(class %s, enabled %s, feed %s)${N}\n" "$sym" "$reg_cls" "$reg_en" "$(short "$reg_feed")"; fail
  fi
  pace
}
for r in "${ASSETS[@]}"; do
  IFS='|' read -r sym token feed cls <<<"$r"
  spin "$(printf "%-6s reading feed…" "$sym")" sleep 0.1
  feed_row "$sym" "$token" "$feed" "$cls"
done
if [ "$STALE" -gt 0 ]; then
  echo
  echo "  ${Y}!${N} ${DIM}${STALE} feed(s) are paused: stock feeds follow US market hours (weekend gap). Pools halt on purpose until"
  echo "    the feed updates again, and liquidity can always be withdrawn.${N}"
fi

# ------------------------------------------------------------------ 6. release gate

pause "Next: is v1.2 open?"
stage 6 "Release gate" "Proves v1.2 is live: the hub only lets a stock token into a pool once it is enabled."
gate() { # $1 label, $2 token
  local en; en="$(call "$HUB" 'asset(address)(uint8,bool,address,uint32)' "$2" | sed -n 2p | awk '{print $1}')"
  if [ "$en" = true ]; then
    printf "  ${OK} %-52s ${G}${B}OPEN${N}\n" "$1"; pass
  else
    printf "  ${BAD} %-52s ${R}${B}LOCKED${N}\n" "$1"; fail
  fi
  pace
}
for r in "${ASSETS[@]}"; do
  IFS='|' read -r sym token feed cls <<<"$r"
  [ "$cls" = 2 ] && gate "$sym stock pools (oracle guard on)" "$token"
done
echo
echo "  ${DIM}Pools registered in the hub so far: $(call "$HUB" 'poolCount()(uint256)' | awk '{print $1}')${N}"

# ------------------------------------------------------------------ summary

TOTAL_CHECKS=$((PASS + FAIL))
echo
echo "$RULE"
if [ "$FAIL" -eq 0 ]; then
  echo
  echo "  ${G}${B}✓ Aethra Fi v1.2 verified: ${PASS} of ${TOTAL_CHECKS} checks passed${N}"
  echo "  ${DIM}${VERIFIED}/${TOTAL} contracts source-verified · proxies run verified code"
  echo "  · Chainlink feeds wired · stock pools open on ${NAME}${N}"
else
  echo
  echo "  ${Y}${B}${PASS} of ${TOTAL_CHECKS} checks passed, ${FAIL} failed${N}"
fi
echo

mkdir -p "$(dirname "$REPORT")"
{
  echo "# Aethra Fi v1.2 contract verification: ${NAME}"
  echo
  echo "Chain ID ${CHAIN}, block ${BLOCK}. Checked with \`bash scripts/verify-v12.sh\` on $(date -u +%Y-%m-%d): ${PASS} of ${TOTAL_CHECKS} checks passed."
  echo
  echo "| # | Contract | Address | Explorer | Sourcify |"
  echo "|---|---|---|---|---|"
  for i in "${!ADDRS[@]}"; do
    echo "| $((i + 1)) | ${LABELS[$i]} | \`${ADDRS[$i]}\` | [source code]($(explorer "${ADDRS[$i]}")) | [files]($(sourcify_page "${ADDRS[$i]}")) |"
  done
  echo
  echo "Chainlink price feeds and Robinhood stock tokens read by the hub (not Aethra source):"
  echo
  echo "| Contract | Address | Explorer |"
  echo "|---|---|---|"
  for i in "${!XADDRS[@]}"; do
    echo "| ${XLABELS[$i]} | \`${XADDRS[$i]}\` | [explorer]($(explorer "${XADDRS[$i]}")) |"
  done
} >"$REPORT"
echo "  ${DIM}Report saved to docs/verification/mainnet-v1.2.md${N}"
echo

# ------------------------------------------------------------------ explore

if [ "$TTY" = 1 ]; then
  opener="$(command -v xdg-open || command -v open || true)"
  menu() {
    echo "  ${B}Contracts${N}"
    for i in "${!ALL_ADDRS[@]}"; do
      printf "   ${C}%2d${N}  %-36s %s\n" "$((i + 1))" "${ALL_LABELS[$i]}" "$(hyperlink "$(explorer "${ALL_ADDRS[$i]}")" "${ALL_ADDRS[$i]}")"
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
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$ALLTOTAL" ]; then
      a="${ALL_ADDRS[$((n - 1))]}"
      if [ "$site" = sourcify ]; then url="$(sourcify_page "$a")"; else url="$(explorer "$a")"; fi
      echo "    ${OK} ${ALL_LABELS[$((n - 1))]}  ${DIM}${url}${N}"
      [ -n "$opener" ] && "$opener" "$url" >/dev/null 2>&1 &
    else
      echo "    ${DIM}pick 1-${ALLTOTAL}, s1-s${ALLTOTAL}, l or q${N}"
    fi
  done
  echo
fi
[ "$FAIL" -eq 0 ]
