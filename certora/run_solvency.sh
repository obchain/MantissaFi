#!/bin/bash
# Run Certora verification for solvency invariant
# Requires: CERTORAKEY environment variable set

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

if [ -z "$CERTORAKEY" ]; then
    echo "Error: CERTORAKEY environment variable not set"
    echo "Get your key from: https://www.certora.com/"
    exit 1
fi

echo "Running Certora verification for OptionVault solvency..."
certoraRun certora/conf/Solvency.conf

echo "Verification complete. Check the Certora dashboard for results."
