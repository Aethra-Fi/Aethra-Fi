#!/usr/bin/env bash
# Jalankan di: ROOT
# Anvil fork of Robinhood Chain Testnet as chain 31337 with auto-impersonation (no private keys locally).
set -euo pipefail
FORK_URL="${TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com}"
exec anvil --fork-url "$FORK_URL" --chain-id 31337 --auto-impersonate --port "${PORT:-8545}" --block-time "${BLOCK_TIME:-2}" "$@"
