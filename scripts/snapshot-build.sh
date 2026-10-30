#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/snapshot-build.sh <git-ref> <name>
# Builds the contracts exactly as they were at <git-ref> and saves the build-info to
#   packages/contracts/upgrades/<name>/
# Use it as the reference ("what is deployed today") when validating an upgrade:
#   REFERENCE_BUILD_INFO=upgrades/<name> REFERENCE_NAME=<name> forge script script/upgrade/Upgrade.s.sol ...
# (OpenZeppelin names the reference by the directory's short name, so <name> must differ from "build-info".)
set -euo pipefail
REF="${1:?usage: snapshot-build.sh <git-ref> <name>}"
NAME="${2:?usage: snapshot-build.sh <git-ref> <name>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/packages/contracts/upgrades/$NAME"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git -C "$ROOT" rev-parse --verify --quiet "$REF^{commit}" >/dev/null || { echo "unknown git ref: $REF"; exit 1; }
mkdir -p "$TMP/contracts"
# sources at that ref (submodules are empty in the archive, so reuse the libraries of this checkout)
git -C "$ROOT" archive "$REF" packages/contracts | tar -x -C "$TMP/contracts" --strip-components=2
rm -rf "$TMP/contracts/lib"
ln -s "$ROOT/packages/contracts/lib" "$TMP/contracts/lib"

cd "$TMP/contracts"
# same build profile as the upgrade script (the ref may predate it, so add it here)
grep -q '^\[profile.upgrade\]' foundry.toml || cat >> foundry.toml <<'TOML'

[profile.upgrade]
out = "out-upgrade"
cache_path = "cache-upgrade"
skip = ["*/test/**"]
additional_compiler_profiles = []
compilation_restrictions = []
TOML
FOUNDRY_PROFILE=upgrade forge build --build-info --force >/dev/null
rm -rf "$DEST"
mkdir -p "$DEST"
cp out-upgrade/build-info/*.json "$DEST/"
echo "saved reference build of $REF to packages/contracts/upgrades/$NAME"
