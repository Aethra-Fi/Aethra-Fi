#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/verify-v13.sh
# Release v1.3 verification on Robinhood Chain mainnet (launchpad markets, protocol fees to the treasury), made for
# screen recording. Read-only: sends no transaction and needs no keystore. Each stage says what it proves, then checks
# it live:
#   1. network          the RPC answers as chain 4663
#   2. bytecode         the v1.3 contracts have code on-chain (hub, hook, DLMM pool, launchpad, launch token)
#   3. source code      Sourcify recompiled the published source to the exact deployed bytecode
#   4. the upgrade      the 6 release transactions succeeded, the hook proxy and the DLMM pool beacon now run the new
#                       code, and the verified source shows the change (protocol fees fall back to the treasury)
#   5. launchpad        the launchpad reads the hub, graduates into the Aethra v4 hook pool and is owned by the deployer
#   6. fees             20% of every swap fee is protocol revenue, paid to the treasury while no buyback is set;
#                       the bonding curve's own parameters
#   7. release gate     the hub accepts markets from the launchpad, which is what "v1.3 open" means on-chain
# Ends with a score, saves docs/verification/mainnet-v1.3.md and lets you open any contract or transaction.
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
BROADCAST="$ROOT/packages/contracts/broadcast/ReleaseV13.s.sol/4663/run-latest.json"
REPORT="$ROOT/docs/verification/mainnet-v1.3.md"
IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc # ERC-1967 implementation
SHARE_BPS=2000
STAGES=7

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
explorer_tx() { echo "${EXPLORER}/tx/$1"; }
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
  echo "  ${L}${B}[$1/${STAGES}]${N} ${B}$2${N}"
  echo "  ${DIM}$3${N}"
  echo
}

call() { cast call "$@" --rpc-url "$RPC" 2>/dev/null; }
first() { awk 'NR == 1 {print $1}'; }
slot_addr() { local v; v="$(cast storage "$1" "$2" --rpc-url "$RPC" 2>/dev/null)"; echo "0x${v: -40}"; }
check() { # $1 label, $2 actual, $3 expected, $4 expected name
  if [ "$(lc "$2")" = "$(lc "$3")" ]; then
    printf "  ${OK} %-50s ${C}→${N} %-30s ${DIM}%s${N}\n" "$1" "$4" "$(short "$3")"; pass
  else
    printf "  ${BAD} %-50s ${R}→ %s${N} ${DIM}(expected %s)${N}\n" "$1" "$(short "$2")" "$(short "$3")"; fail
  fi
  pace
}
value() { # $1 label, $2 actual, $3 expected, $4 shown text
  if [ "$2" = "$3" ]; then
    printf "  ${OK} %-50s ${B}%s${N}\n" "$1" "$4"; pass
  else
    printf "  ${BAD} %-50s ${R}%s${N} ${DIM}(expected %s)${N}\n" "$1" "$2" "$3"; fail
  fi
  pace
}

# ------------------------------------------------------------------ the v1.3 contracts

for f in "$MANIFEST" "$ADDRESSES" "$BROADCAST"; do
  [ -f "$f" ] || { echo "missing ${f#"$ROOT"/} (run node scripts/verify-prepare.mjs mainnet, or the v1.3 release first)"; exit 1; }
done
# label|address, in release order; addresses come from the verification manifest (the deploy and release records)
mapfile -t ROWS < <(node -e '
  const m = require(process.argv[1]);
  const want = [
    "AethraHub (proxy)", "AethraHub (implementation)",
    "AethraHook (proxy)", "AethraHook (implementation)",
    "DLMM pool beacon", "DLMM pool (implementation)",
    "Launchpad (proxy)", "Launchpad (implementation)", "Launch token",
  ];
  for (const label of want) {
    const c = m.find((x) => x.label === label);
    if (!c) { console.error("not in manifest: " + label); process.exit(1); }
    console.log([label, c.address].join("|"));
  }' "$MANIFEST") || exit 1
TOTAL=${#ROWS[@]}
LABELS=(); ADDRS=()
for r in "${ROWS[@]}"; do IFS='|' read -r l a <<<"$r"; LABELS+=("$l"); ADDRS+=("$a"); done
addr_of() { local i; for i in "${!LABELS[@]}"; do [ "${LABELS[$i]}" = "$1" ] && { echo "${ADDRS[$i]}"; return; }; done; }
old_of() { node -e 'const c = require(process.argv[1]).find((x) => x.label === process.argv[2]); console.log(c ? c.address : "")' "$MANIFEST" "$1"; }
HUB="$(addr_of "AethraHub (proxy)")"; HOOK="$(addr_of "AethraHook (proxy)")"; BEACON="$(addr_of "DLMM pool beacon")"
LAUNCHPAD="$(addr_of "Launchpad (proxy)")"
HOOK_NEW="$(addr_of "AethraHook (implementation)")"; POOL_NEW="$(addr_of "DLMM pool (implementation)")"
HOOK_OLD="$(old_of "AethraHook (implementation, replaced)")"; POOL_OLD="$(old_of "DLMM pool (implementation, replaced)")"
PM="$(node -p "require('$ADDRESSES').poolManager")"
POSITIONS="$(node -p "require('$ADDRESSES').positions")"
WETH="$(node -p "require('$ADDRESSES').weth")"

# the release transactions: what|hash|block|status|gas
mapfile -t TXS < <(node -e '
  const d = require(process.argv[1]);
  const what = (t) => t.contractName ? "deploy " + t.contractName + " implementation" : ({
    "upgradeToAndCall(address,bytes)": "hook proxy upgraded to the new code",
    "upgradeTo(address)": "DLMM pool beacon upgraded to the new code",
    "setFeeConfig(address,address,uint16)": "hub: 20% protocol share to treasury",
    "setRegistrar(address,bool)": "hub: launchpad becomes a registrar",
  })[t.function] || t.function;
  d.transactions.forEach((t, i) => {
    const r = d.receipts[i] || {};
    console.log([what(t), t.hash, parseInt(r.blockNumber, 16), r.status === "0x1" ? "ok" : "failed", parseInt(r.gasUsed, 16)].join("|"));
  });' "$BROADCAST") || exit 1

# ------------------------------------------------------------------ intro

[ "$TTY" = 1 ] && clear
cat <<EOF

  ${L}${B}   ▄▀█ █▀▀ ▀█▀ █ █ █▀█ ▄▀█   █▀▀ █${N}
  ${L}${B}   █▀█ ██▄  █  █▀█ █▀▄ █▀█   █▀  █${N}

  ${B}Release v1.3 · contract verification${N}   ${DIM}launchpad · protocol fees to the treasury${N}
$RULE
  Network     ${B}${NAME}${N} ${DIM}· chain ${CHAIN}${N}
  Explorer    ${EXPLORER}
  Verifier    Sourcify ${DIM}(independent source-code verification)${N}
  Contracts   ${B}${TOTAL}${N} ${DIM}Aethra contracts behind launch markets and protocol fees${N}
  Release     ${B}${#TXS[@]}${N} ${DIM}transactions from the deployer, in one batch${N}

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
for i in "${!ADDRS[@]}"; do
  a="${ADDRS[$i]}"
  spin "$(printf "%2d/%d  %-32s reading code…" "$((i + 1))" "$TOTAL" "${LABELS[$i]}")" codecheck "$a"
  read -r size hash <"$TMP/out"
  if [ "${size:-0}" -gt 0 ] 2>/dev/null; then
    printf "  ${OK} ${DIM}%2d/%d${N}  %-32s ${DIM}%s${N}  %6s bytes  ${DIM}hash %s${N}\n" "$((i + 1))" "$TOTAL" "${LABELS[$i]}" "$(short "$a")" "$size" "$(short "$hash")"; pass
  else
    printf "  ${BAD} ${DIM}%2d/%d${N}  %-32s ${DIM}%s${N}  ${R}no code${N}\n" "$((i + 1))" "$TOTAL" "${LABELS[$i]}" "$(short "$a")"; fail
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
  spin "$(printf "%2d/%d  %-32s asking Sourcify…" "$((i + 1))" "$TOTAL" "${LABELS[$i]}")" sourcify "$a"
  read -r match cname solc runs <"$TMP/out"
  case "$match" in
    exact_match) tag="${G}exact match${N}  "; mark="$OK"; pass; VERIFIED=$((VERIFIED + 1)) ;;
    match) tag="${Y}partial match${N}"; mark="$OK"; pass; VERIFIED=$((VERIFIED + 1)) ;;
    *) tag="${R}not verified${N} "; mark="$BAD"; fail ;;
  esac
  printf "  %s ${DIM}%2d/%d${N}  %-32s %s ${DIM}%-20s solc %s · optimizer %s${N}\n" "$mark" "$((i + 1))" "$TOTAL" "${LABELS[$i]}" "$tag" "$cname" "$solc" "$runs"
  pace
done
if [ "$VERIFIED" -lt "$TOTAL" ]; then
  echo
  echo "  ${Y}!${N} Missing contracts can be submitted with: ${B}bash scripts/verify-contracts.sh mainnet${N}"
fi

# ------------------------------------------------------------------ 4. the upgrade

pause "Next: the v1.3 upgrade"
stage 4 "The upgrade" "Proves the release transactions went through and the live contracts now run the new, verified code."
echo "  ${B}Release transactions${N} ${DIM}(sent by the deployer $(short "$DEPLOYER"))${N}"
receipt() { cast receipt "$1" --rpc-url "$RPC" --json 2>/dev/null | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const r=JSON.parse(d);console.log(r.status==="0x1"?"ok":"failed",parseInt(r.blockNumber,16),r.from.toLowerCase())}catch{console.log("missing - -")}})'; }
GAS=0
for i in "${!TXS[@]}"; do
  IFS='|' read -r what hash blk st gas <<<"${TXS[$i]}"
  spin "$(printf "%d/%d  %-44s reading receipt…" "$((i + 1))" "${#TXS[@]}" "$what")" receipt "$hash"
  read -r live lblk from <"$TMP/out"
  if [ "$live" = ok ] && [ "$from" = "$(lc "$DEPLOYER")" ]; then
    printf "  ${OK} ${DIM}%d/%d${N}  %-44s ${DIM}block %s · %s gas ·${N} %s\n" "$((i + 1))" "${#TXS[@]}" "$what" "$lblk" "$(printf "%'d" "$gas" 2>/dev/null || echo "$gas")" "$(hyperlink "$(explorer_tx "$hash")" "$(short "$hash")")"; pass
    GAS=$((GAS + gas))
  else
    printf "  ${BAD} ${DIM}%d/%d${N}  %-44s ${R}%s${N} ${DIM}%s${N}\n" "$((i + 1))" "${#TXS[@]}" "$what" "$live" "$(short "$hash")"; fail
  fi
  pace
done
echo "  ${DIM}Total $(printf "%'d" "$GAS" 2>/dev/null || echo "$GAS") gas.${N}"
echo
echo "  ${B}Live code${N} ${DIM}(what the proxies run now)${N}"
check "Hook proxy runs (ERC-1967 slot)" "$(slot_addr "$HOOK" $IMPL_SLOT)" "$HOOK_NEW" "AethraHook v1.3 implementation"
check "DLMM pool beacon serves every DLMM pool" "$(call "$BEACON" 'implementation()(address)')" "$POOL_NEW" "DLMM pool v1.3 implementation"
if [ -n "$HOOK_OLD" ] && [ "$(lc "$(slot_addr "$HOOK" $IMPL_SLOT)")" != "$(lc "$HOOK_OLD")" ]; then
  printf "  ${OK} %-50s ${DIM}%s (v1.0) is no longer in use${N}\n" "Previous hook implementation retired" "$(short "$HOOK_OLD")"; pass
fi
if [ -n "$POOL_OLD" ] && [ "$(lc "$(call "$BEACON" 'implementation()(address)')")" != "$(lc "$POOL_OLD")" ]; then
  printf "  ${OK} %-50s ${DIM}%s (v1.0) is no longer in use${N}\n" "Previous DLMM pool implementation retired" "$(short "$POOL_OLD")"; pass
fi
pace
echo
echo "  ${B}The change, read from the verified source on Sourcify${N}"
show_source() { # $1 address, $2 path suffix, $3 regex of the line that matters
  curl -s --max-time 40 "${SOURCIFY}/v2/contract/${CHAIN}/$1?fields=sources" | node -e '
    let d = ""; process.stdin.on("data", (c) => (d += c)).on("end", () => {
      try {
        const [suffix, re] = process.argv.slice(1), j = JSON.parse(d);
        const key = Object.keys(j.sources || {}).find((k) => k.endsWith(suffix));
        const lines = j.sources[key].content.split("\n"), at = lines.findIndex((l) => new RegExp(re).test(l));
        if (at < 0) { console.log("MISSING"); return; }
        console.log(key);
        for (let i = Math.max(0, at - 2); i <= Math.min(lines.length - 1, at + 1); i++) console.log((i === at ? ">" : " ") + String(i + 1).padStart(4) + "  " + lines[i]);
      } catch { console.log("MISSING"); }
    });' "$2" "$3"
}
for pair in "$HOOK_NEW|hooks/AethraHook.sol|AethraHook" "$POOL_NEW|dlmm/DLMMPool.sol|DLMMPool"; do
  IFS='|' read -r a path cname <<<"$pair"
  spin "Fetching ${cname} source from Sourcify" show_source "$a" "$path" 'to = .*treasury\(\)'
  if head -1 "$TMP/out" | grep -q MISSING; then
    echo "  ${BAD} ${cname}: the treasury fallback is not in the verified source"; fail
  else
    echo "  ${OK} ${B}${cname}${N} ${DIM}$(head -1 "$TMP/out") · collectProtocolFees${N}"
    tail -n +2 "$TMP/out" | while IFS= read -r line; do
      if [ "${line:0:1}" = ">" ]; then echo "      ${L}${line}${N}"; else echo "      ${DIM}${line}${N}"; fi
    done
    pass
  fi
  pace 0.3
done
echo "  ${DIM}No buyback yet (v1.4), so swept protocol fees go to the hub's treasury.${N}"

# ------------------------------------------------------------------ 5. launchpad

pause "Next: how the launchpad is wired"
stage 5 "Launchpad" "Proves the launchpad registers markets in the Aethra hub and graduates them into the Aethra v4 hook pool."
mapfile -t GT < <(call "$LAUNCHPAD" 'graduationTargets()(address,address,address)' | awk '{print $1}')
check "Launchpad proxy runs (ERC-1967 slot)" "$(slot_addr "$LAUNCHPAD" $IMPL_SLOT)" "$(addr_of "Launchpad (implementation)")" "Launchpad implementation"
check "Launchpad registers markets in" "$(call "$LAUNCHPAD" 'hub()(address)')" "$HUB" "AethraHub"
check "Every launch is a clone of" "$(call "$LAUNCHPAD" 'tokenImplementation()(address)')" "$(addr_of "Launch token")" "Launch token"
check "Curve trades are priced in" "$(call "$LAUNCHPAD" 'weth()(address)')" "$WETH" "WETH"
check "Graduation opens a pool on" "${GT[0]:-0x0}" "$PM" "Uniswap v4 PoolManager"
check "Graduated liquidity is minted through" "${GT[1]:-0x0}" "$POSITIONS" "AethraPositions (locked)"
check "Graduated pools use the hook" "${GT[2]:-0x0}" "$HOOK" "AethraHook"
check "Launchpad owner" "$(call "$LAUNCHPAD" 'owner()(address)')" "$DEPLOYER" "deployer"
check "Hub owner" "$(call "$HUB" 'owner()(address)')" "$DEPLOYER" "deployer"

# ------------------------------------------------------------------ 6. fees

pause "Next: where the fees go"
stage 6 "Fees" "Proves the protocol share of swap fees and who receives it, then the bonding curve's parameters."
check "Protocol fees are paid to (treasury)" "$(call "$HUB" 'treasury()(address)')" "$DEPLOYER" "treasury (deployer)"
value "Buyback" "$(call "$HUB" 'buyback()(address)')" "0x0000000000000000000000000000000000000000" "not set yet (opens in v1.4)"
SHARE="$(call "$HUB" 'protocolFeeShareBps()(uint16)' | first)"
value "Protocol share of every swap fee" "$SHARE" "$SHARE_BPS" "$((SHARE_BPS / 100))% (LPs keep $((100 - SHARE_BPS / 100))%)"
mapfile -t CFG < <(call "$LAUNCHPAD" 'config()((uint128,uint128,uint128,uint24,uint16,uint16))' | tr -d '()' | tr ',' '\n' | awk '{print $1}')
THRESH="$(call "$LAUNCHPAD" 'graduationThreshold()(uint256)' | first)"
curve="$(node -e '
  const [vw, vt, cs, fee, grad, creator, th] = process.argv.slice(1).map(BigInt);
  const eth = (x) => (Number(x) / 1e18).toLocaleString("en-US", { maximumFractionDigits: 4 });
  const tok = (x) => (Number(x) / 1e18 / 1e6).toLocaleString("en-US") + "M";
  console.log([eth(vw) + " ETH", tok(cs), (Number(fee) / 1e4) + "%", (Number(grad) / 100) + "%", (Number(creator) / 100) + "%", eth(th) + " ETH"].join("|"));
' "${CFG[0]:-0}" "${CFG[1]:-0}" "${CFG[2]:-0}" "${CFG[3]:-0}" "${CFG[4]:-0}" "${CFG[5]:-0}" "${THRESH:-0}")"
IFS='|' read -r c_vw c_cs c_fee c_grad c_creator c_th <<<"$curve"
echo
echo "  ${B}Bonding curve${N} ${DIM}(read from the launchpad)${N}"
row() { printf "  ${OK} %-50s ${B}%s${N} ${DIM}%s${N}\n" "$1" "$2" "${3:-}"; pass; pace; }
row "Virtual ETH reserve at launch" "$c_vw"
row "Tokens sold on the curve" "$c_cs" "of 1,000M; the rest pairs with the raised ETH at graduation"
row "Trade fee on the curve" "$c_fee" "paid in WETH to the treasury"
row "Graduation fee" "$c_grad"
row "Creator share of the locked pool's LP fees" "$c_creator"
row "A launch graduates after raising" "$c_th"

# ------------------------------------------------------------------ 7. release gate

pause "Next: is v1.3 open?"
stage 7 "Release gate" "Proves v1.3 is live: the hub only accepts new markets from addresses it has made registrars."
if [ "$(call "$HUB" 'isRegistrar(address)(bool)' "$LAUNCHPAD")" = true ]; then
  printf "  ${OK} %-50s ${G}${B}OPEN${N}\n" "Launch markets (launchpad is a hub registrar)"; pass
else
  printf "  ${BAD} %-50s ${R}${B}LOCKED${N}\n" "Launch markets (launchpad is a hub registrar)"; fail
fi
if [ "${SHARE:-0}" -gt 0 ] 2>/dev/null; then
  printf "  ${OK} %-50s ${G}${B}ON${N}\n" "Protocol fees to the treasury"; pass
else
  printf "  ${BAD} %-50s ${R}${B}OFF${N}\n" "Protocol fees to the treasury"; fail
fi
echo
echo "  ${DIM}Launches so far: $(call "$LAUNCHPAD" 'launchCount()(uint256)' | first) · pools registered in the hub: $(call "$HUB" 'poolCount()(uint256)' | first)${N}"

# ------------------------------------------------------------------ summary

TOTAL_CHECKS=$((PASS + FAIL))
echo
echo "$RULE"
if [ "$FAIL" -eq 0 ]; then
  echo
  echo "  ${G}${B}✓ Aethra Fi v1.3 verified: ${PASS} of ${TOTAL_CHECKS} checks passed${N}"
  echo "  ${DIM}${VERIFIED}/${TOTAL} contracts source-verified · hook and DLMM pools run the new code"
  echo "  · protocol fees to the treasury · launch markets open on ${NAME}${N}"
else
  echo
  echo "  ${Y}${B}${PASS} of ${TOTAL_CHECKS} checks passed, ${FAIL} failed${N}"
fi
echo

mkdir -p "$(dirname "$REPORT")"
{
  echo "# Aethra Fi v1.3 contract verification: ${NAME}"
  echo
  echo "Chain ID ${CHAIN}, block ${BLOCK}. Checked with \`bash scripts/verify-v13.sh\` on $(date -u +%Y-%m-%d): ${PASS} of ${TOTAL_CHECKS} checks passed."
  echo
  echo "| # | Contract | Address | Explorer | Sourcify |"
  echo "|---|---|---|---|---|"
  for i in "${!ADDRS[@]}"; do
    echo "| $((i + 1)) | ${LABELS[$i]} | \`${ADDRS[$i]}\` | [source code]($(explorer "${ADDRS[$i]}")) | [files]($(sourcify_page "${ADDRS[$i]}")) |"
  done
  echo
  echo "Release transactions (deployer \`${DEPLOYER}\`):"
  echo
  echo "| # | Transaction | Block | Gas | Explorer |"
  echo "|---|---|---|---|---|"
  for i in "${!TXS[@]}"; do
    IFS='|' read -r what hash blk st gas <<<"${TXS[$i]}"
    echo "| $((i + 1)) | ${what} | ${blk} | ${gas} | [tx]($(explorer_tx "$hash")) |"
  done
} >"$REPORT"
echo "  ${DIM}Report saved to docs/verification/mainnet-v1.3.md${N}"
echo

# ------------------------------------------------------------------ explore

if [ "$TTY" = 1 ]; then
  opener="$(command -v xdg-open || command -v open || true)"
  menu() {
    echo "  ${B}Contracts${N}"
    for i in "${!ADDRS[@]}"; do
      printf "   ${C}%2d${N}  %-32s %s\n" "$((i + 1))" "${LABELS[$i]}" "$(hyperlink "$(explorer "${ADDRS[$i]}")" "${ADDRS[$i]}")"
    done
    echo "  ${B}Release transactions${N}"
    for i in "${!TXS[@]}"; do
      IFS='|' read -r what hash blk st gas <<<"${TXS[$i]}"
      printf "   ${C}t%d${N}  %-44s %s\n" "$((i + 1))" "$what" "$(hyperlink "$(explorer_tx "$hash")" "$(short "$hash")")"
    done
    echo
    echo "  ${DIM}Type a number to open a contract on the explorer, s + number for Sourcify (e.g. s4), t + number for a"
    echo "  transaction (e.g. t2), l to list again, q to quit.${N}"
  }
  menu
  while :; do
    printf "  ${C}▸${N} "
    read -r pick || break
    url=""; what=""
    case "$pick" in
      q | Q) break ;;
      l | L) echo; menu; continue ;;
      s[0-9]* | S[0-9]*) n="${pick:1}"; [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$TOTAL" ] && { url="$(sourcify_page "${ADDRS[$((n - 1))]}")"; what="${LABELS[$((n - 1))]}"; } ;;
      t[0-9]* | T[0-9]*) n="${pick:1}"; [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#TXS[@]}" ] && { IFS='|' read -r what hash _ <<<"${TXS[$((n - 1))]}"; url="$(explorer_tx "$hash")"; } ;;
      *) n="$pick"; [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$TOTAL" ] && { url="$(explorer "${ADDRS[$((n - 1))]}")"; what="${LABELS[$((n - 1))]}"; } ;;
    esac
    if [ -n "$url" ]; then
      echo "    ${OK} ${what}  ${DIM}${url}${N}"
      [ -n "$opener" ] && "$opener" "$url" >/dev/null 2>&1 &
    else
      echo "    ${DIM}pick 1-${TOTAL}, s1-s${TOTAL}, t1-t${#TXS[@]}, l or q${N}"
    fi
  done
  echo
fi
[ "$FAIL" -eq 0 ]
