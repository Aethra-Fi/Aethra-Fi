#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/mainnet-seed-stock.sh
# Opens three more Aethra pools on mainnet with minimal funds (script/mainnet/SeedStock.s.sol): TSLA/WETH, TSLA/USDG and
# NVDA/WETH, ORACLE mode, full range. TSLA is bought first (ETH -> USDG -> TSLA through external v4 pools); NVDA uses the
# dust the deployer already holds. Needs fresh Chainlink feeds (stock feeds go stale 24h after their last update), so the
# script checks every feed age first and simulates the whole run before sending anything. Asks for confirmation and the
# keystore password once; the password lives only in a private temp file deleted on exit.
# Rehearsed on a mainnet fork on 2026-10-31: 3 pools, ≈ 0.00024 ETH (≈ $0.54) all-in.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC="${MAINNET_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
DEPLOYER_ADDRESS="0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C"
KEYSTORE="${KEYSTORE:-$HOME/.foundry/keystores/deployer}"
export SIDE_USD_E6="${SIDE_USD_E6:-100000}"                 # $0.10 per side of each TSLA pool
export ETH_FOR_USDG="${ETH_FOR_USDG:-160000000000000}"      # 0.00016 ETH
MIN_FRESH_LEFT=1800                                          # refuse when a feed has under 30 min of freshness left

[ "$(cast chain-id --rpc-url "$RPC")" = "4663" ] || { echo "RPC is not Robinhood Chain mainnet (4663)"; exit 1; }
HUB="$(node -e "console.log(require('$ROOT/packages/sdk/src/addresses/mainnet.json').hub)")"
ETH_BAL="$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC")"
echo "Deployer:    $(cast from-wei "$ETH_BAL") ETH"
echo "Plan:        buy TSLA with $(cast from-wei "$ETH_FOR_USDG") ETH, then open TSLA/WETH, TSLA/USDG, NVDA/WETH ($SIDE_USD_E6 / 1e6 USD per side)"

# feed freshness: every asset in the plan must keep a fresh price for at least 30 more minutes
now="$(date +%s)"
for row in "TSLA 0x322F0929c4625eD5bAd873c95208D54E1c003b2d 0x4A1166a659A55625345e9515b32adECea5547C38" \
           "NVDA 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15" \
           "WETH 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9" \
           "USDG 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2"; do
  set -- $row
  max="$(cast call "$HUB" 'asset(address)(uint8,bool,address,uint32)' "$2" --rpc-url "$RPC" | sed -n 4p | awk '{print $1}')"
  upd="$(cast call "$3" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$RPC" | sed -n 4p | awk '{print $1}')"
  left=$(( upd + max - now ))
  echo "  $1 feed: $(( (now - upd) / 60 )) min old, fresh for $(( left / 60 )) more min"
  [ "$left" -gt "$MIN_FRESH_LEFT" ] || { echo "STOP: the $1 feed is stale or about to be. Wait for the market to update it. Nothing was sent."; exit 1; }
done

cd "$ROOT/packages/contracts"
echo "Simulating against live state..."
forge script script/mainnet/SeedStock.s.sol:SeedStock --rpc-url "$RPC" --sender "$DEPLOYER_ADDRESS" >/dev/null 2>&1 \
  || { echo "STOP: the simulation failed (run the same forge script without >/dev/null to see why). Nothing was sent."; exit 1; }
rm -rf broadcast/SeedStock.s.sol/4663/dry-run cache/SeedStock.s.sol/4663/dry-run
echo "Simulation ok."
read -rp "Open the three pools now? [y/N] " ok
[ "$ok" = y ] || { echo "Nothing sent."; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
read -rsp "Keystore password for 'deployer': " pass; echo
printf '%s' "$pass" >"$TMP/pw"; chmod 600 "$TMP/pw"; unset pass
ADDR="$(cast wallet address --keystore "$KEYSTORE" --password-file "$TMP/pw")"
if [ "$(echo "$ADDR" | tr 'A-F' 'a-f')" != "$(echo "$DEPLOYER_ADDRESS" | tr 'A-F' 'a-f')" ]; then
  echo "STOP: keystore is $ADDR, expected $DEPLOYER_ADDRESS. Nothing was sent."; exit 1
fi
forge script script/mainnet/SeedStock.s.sol:SeedStock --rpc-url "$RPC" --keystore "$KEYSTORE" --password-file "$TMP/pw" \
  --sender "$DEPLOYER_ADDRESS" --broadcast --slow
echo "Done. Remaining: $(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC" -e) ETH. The indexer lists the pools within a few minutes."
