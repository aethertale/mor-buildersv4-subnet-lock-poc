#!/usr/bin/env bash
# Run the fork PoC against a Base archive RPC you supply:
#   BASE_RPC_URL=https://... ./run.sh
# Equivalent one-liner:
#   forge test --fork-url "$BASE_RPC_URL" --fork-block-number 59534749
set -eu
cd "$(dirname "$0")" || exit 1
: "${BASE_RPC_URL:?set BASE_RPC_URL to a Base archive RPC URL}"
forge test --fork-url "$BASE_RPC_URL" --fork-block-number 59534749 -vvv
