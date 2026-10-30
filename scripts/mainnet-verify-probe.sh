#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/mainnet-verify-probe.sh
# Proves the mainnet verification path before the release: deploys the tiny VerificationProbe contract (≈130k gas,
# under $0.01) from the bytecode of its explorer source package, verifies it through Sourcify, and prints the explorer
# link. Open the link: the page must show "Contract source code verified (exact match)".
# Asks the keystore password once; the password lives only in a private temp file deleted on exit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC="${MAINNET_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
EXPLORER="https://robinhoodchain.blockscout.com"
SOURCIFY="https://sourcify.dev/server"
DEPLOYER_ADDRESS="0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C"
KEYSTORE="${KEYSTORE:-$HOME/.foundry/keystores/deployer}"
TARGET="src/utils/VerificationProbe.sol:VerificationProbe"
SOLC="$HOME/.local/share/svm/0.8.26/solc-0.8.26"

[ "$(cast chain-id --rpc-url "$RPC")" = "4663" ] || { echo "RPC is not Robinhood Chain mainnet (4663)"; exit 1; }
echo "deployer balance: $(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC" -e) ETH"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$ROOT/packages/contracts"

echo "1/4  Building the source package and its bytecode"
forge verify-contract 0x0000000000000000000000000000000000000001 "$TARGET" --chain 4663 --compiler-version 0.8.26 \
  --compilation-profile default --show-standard-json-input --verifier blockscout --verifier-url https://localhost/api/ \
  </dev/null 2>/dev/null | sed "s|$PWD/||g" >"$TMP/input.json"
if grep -q "$HOME" "$TMP/input.json"; then echo "STOP: the source package contains a local path"; exit 1; fi
CODE="$(node -e '
  const fs = require("fs"), cp = require("child_process");
  const [solc, file, target] = process.argv.slice(1);
  const [path, name] = target.split(":");
  const job = JSON.parse(fs.readFileSync(file, "utf8"));
  job.settings.outputSelection = { [path]: { [name]: ["evm.bytecode.object"] } };
  const out = JSON.parse(cp.spawnSync(solc, ["--standard-json"], { input: JSON.stringify(job), maxBuffer: 1 << 30 }).stdout);
  console.log("0x" + out.contracts[path][name].evm.bytecode.object);' "$SOLC" "$TMP/input.json" "$TARGET")"
echo "     $(( (${#CODE} - 2) / 2 )) bytes"

echo "2/4  Keystore check"
read -rsp "Keystore password for 'deployer': " pass; echo
printf '%s' "$pass" >"$TMP/pw"; chmod 600 "$TMP/pw"; unset pass
ADDR="$(cast wallet address --keystore "$KEYSTORE" --password-file "$TMP/pw")"
if [ "$(echo "$ADDR" | tr 'A-F' 'a-f')" != "$(echo "$DEPLOYER_ADDRESS" | tr 'A-F' 'a-f')" ]; then
  echo "STOP: keystore is $ADDR, expected $DEPLOYER_ADDRESS. Nothing was sent."
  exit 1
fi

echo "3/4  Deploying VerificationProbe to Robinhood Chain mainnet"
cast send --rpc-url "$RPC" --keystore "$KEYSTORE" --password-file "$TMP/pw" --create "$CODE" --json >"$TMP/receipt.json"
rm -f "$TMP/pw"
PROBE="$(node -e 'console.log(require(process.argv[1]).contractAddress)' "$TMP/receipt.json")"
TX="$(node -e 'console.log(require(process.argv[1]).transactionHash)' "$TMP/receipt.json")"
[ "$(node -e 'console.log(require(process.argv[1]).status)' "$TMP/receipt.json")" = "0x1" ] || { echo "STOP: deployment failed ($TX)"; exit 1; }
echo "     probe $PROBE (tx $TX)"

echo "4/4  Verifying through Sourcify"
node -e '
  const fs = require("fs");
  const [file, target, tx, out] = process.argv.slice(1);
  fs.writeFileSync(out, JSON.stringify({ stdJsonInput: JSON.parse(fs.readFileSync(file, "utf8")), compilerVersion: "0.8.26+commit.8a97fa7a", contractIdentifier: target, creationTransactionHash: tx }));' \
  "$TMP/input.json" "$TARGET" "$TX" "$TMP/body.json"
sleep 5
ID="$(curl -s -X POST "$SOURCIFY/v2/verify/4663/$PROBE" -H 'content-type: application/json' --data "@$TMP/body.json" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const j=JSON.parse(d);console.log(j.verificationId||"ERR "+JSON.stringify(j))})')"
case "$ID" in ERR*) echo "Sourcify refused: ${ID#ERR }"; exit 1 ;; esac
for i in $(seq 1 60); do
  sleep 3
  RES="$(curl -s "$SOURCIFY/v2/verify/$ID")"
  node -e 'process.exit(JSON.parse(process.argv[1]).isJobCompleted ? 0 : 1)' "$RES" && break
done
MATCH="$(node -e 'const j=JSON.parse(process.argv[1]);console.log((j.contract&&j.contract.match)||("failed: "+JSON.stringify(j.error||j)))' "$RES")"
echo "     Sourcify: $MATCH"
mkdir -p "$ROOT/docs/verification"
printf '%s\n' "probe=$PROBE" "tx=$TX" "sourcify=$MATCH" "explorer=$EXPLORER/address/$PROBE?tab=contract" >"$ROOT/docs/verification/mainnet-probe.txt"
echo
echo "Open this link in your browser (it can take a minute to appear):"
echo "  $EXPLORER/address/$PROBE?tab=contract"
echo "It must show: Contract source code verified (exact match)"
