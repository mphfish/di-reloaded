#!/bin/bash
# Benchmarks ScanKit against `du` on a generated fixture tree, on the same machine,
# and fails if ScanKit loses too much of its lead. Comparing against `du` rather than
# a fixed time keeps the check meaningful on noisy, shared CI runners.
#
#   scripts/bench-check.sh [files] [max-ratio]
set -euo pipefail

FILES=${1:-200000}
MAX_RATIO=${2:-0.6}   # ScanKit time / du time must stay below this
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BENCH="$ROOT/Packages/Core/.build/release/dir-bench"
FIXTURE=$(mktemp -d)/fixture
trap 'rm -rf "$(dirname "$FIXTURE")"' EXIT

swift build -c release --package-path "$ROOT/Packages/Core" >/dev/null
"$BENCH" --generate "$FIXTURE" --files "$FILES"

best_du() {
    local best=999999
    for _ in 1 2 3; do
        local start end
        start=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
        du -sk "$FIXTURE" >/dev/null
        end=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
        best=$(echo "$end - $start" | bc -l | awk -v b="$best" '{print ($1 < b) ? $1 : b}')
    done
    echo "$best"
}

du -sk "$FIXTURE" >/dev/null # warm the cache
DU=$(best_du)
SCAN_JSON=$("$BENCH" "$FIXTURE" --runs 3 --logical --json) # fixture files are sparse
SCAN=$(echo "$SCAN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["seconds"])')
LAYOUT=$(echo "$SCAN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["layoutMilliseconds"])')
ENTRIES=$(echo "$SCAN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["entries"])')
RATIO=$(echo "$SCAN / $DU" | bc -l)

printf "entries:   %s\n" "$ENTRIES"
printf "du:        %.3fs\n" "$DU"
printf "ScanKit:   %.3fs  (%.2f× of du, limit %.2f×)\n" "$SCAN" "$RATIO" "$MAX_RATIO"
printf "layout:    %.1fms\n" "$LAYOUT"

if (( $(echo "$RATIO > $MAX_RATIO" | bc -l) )); then
    echo "::error::ScanKit took ${RATIO}× as long as du (limit ${MAX_RATIO}×)"
    exit 1
fi
