#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# The "Fork governance verdict" job must run after its needs fail, but must NOT
# run when the workflow run is cancelled. `if: always()` alone also runs on
# cancel, so a newer push cancelled the run and the verdict job then went red.
# Guard: the verdict job's `if` is exactly `always() && !cancelled()`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WF="${1:-$ROOT/.github/workflows/fork-governance.yml}"

# Print the job-level `if:` of the verdict job (2-space job key, 4-space keys).
verdict_if() {
    local file="$1"
    awk '
        /^  verdict:[[:space:]]*$/ { injob=1; next }
        injob && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { injob=0 }
        injob && /^    if:/ { sub(/^    if:[[:space:]]*/, ""); print; exit }
    ' "$file"
}

check() {
    local file="$1" got
    got="$(verdict_if "$file")"
    case "$got" in
        *'always()'*'!cancelled()'*) return 0 ;;
        *) echo "verdict if is '$got'" >&2; return 1 ;;
    esac
}

check "$WF" || { echo "FAIL: verdict job must use always() && !cancelled()" >&2; exit 1; }

# Controls: the old form and a missing condition must both be refused.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sed 's/^    if: \${{ always() && !cancelled() }}$/    if: always()/' "$WF" > "$TMP/old.yml"
if check "$TMP/old.yml" 2>/dev/null; then echo "FAIL: accepted bare always()" >&2; exit 1; fi
sed '/^  verdict:/,/^    runs-on/{/^    if:/d}' "$WF" > "$TMP/none.yml"
if check "$TMP/none.yml" 2>/dev/null; then echo "FAIL: accepted a missing if" >&2; exit 1; fi
cmp -s "$WF" "$TMP/old.yml" && { echo "FAIL: control did not mutate" >&2; exit 1; }

echo "PASS: verdict job skips on cancel (2 controls refused)"
