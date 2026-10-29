#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/testnet-upgrade.sh [--broadcast]
# Upgrades the three testnet contracts whose source changed in the 2026-10-30 security fixes (hub, hook, router).
# Without --broadcast: validates against the deployed code and simulates on the live testnet (nothing sent).
# With --broadcast: prompts for the `deployer` keystore password and sends 3 implementation deployments + 3 upgrades.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ -d packages/contracts/upgrades/v0-testnet ] || bash scripts/snapshot-build.sh 3be51c6 v0-testnet
bash scripts/upgrade.sh testnet hub,hook,router v0-testnet "${1:-}"
