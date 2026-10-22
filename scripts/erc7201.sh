#!/usr/bin/env bash
# Usage: scripts/erc7201.sh <namespace id>  -> prints the ERC-7201 storage slot
set -euo pipefail
inner=$(cast keccak "$1")
minus1=$(python3 -I -c "print(hex(int('$inner',16)-1))")
outer=$(cast keccak "$(cast abi-encode 'f(uint256)' "$minus1")")
python3 -I -c "print('0x%064x' % (int('$outer',16) & ~0xff))"
