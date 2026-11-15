#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# tests/aspect_tests.sh is listed in .machine_readable/mint-verbatim.txt, so
# the mint never substitutes inside it. An active line that carries an
# upper-case brace token (the project placeholder) therefore prints the
# literal token in every minted child. Guard: no non-comment line of the
# script contains an upper-case brace token. Comments may name tokens.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="${1:-$ROOT/tests/aspect_tests.sh}"

active_tokens() {
    local file="$1"
    # Lines that are not comments, with an upper-case brace token.
    grep -nE '^[[:space:]]*[^#[:space:]].*\{\{[A-Z][A-Z0-9_]*\}\}' "$file" || true
}

hits="$(active_tokens "$TARGET")"
if [[ -n "$hits" ]]; then
    echo "FAIL: active line(s) carry an unsubstituted brace token:" >&2
    echo "$hits" >&2
    exit 1
fi

# Build a brace token at run time so this file carries no literal token.
tok() { printf "%s%s%s" "{""{" "$1" "}""}"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Control 1: the old banner must be refused.
printf '%s\n' "echo \"  $(tok PROJECT) — Aspect Tests\"" > "$TMP/old.sh"
[[ -n "$(active_tokens "$TMP/old.sh")" ]] || { echo "FAIL: old banner was accepted" >&2; exit 1; }

# Control 2: a comment that names the token is allowed.
printf '%s\n' "# a symbol may carry the $(tok PROJECT) token" > "$TMP/comment.sh"
[[ -z "$(active_tokens "$TMP/comment.sh")" ]] || { echo "FAIL: a comment was refused" >&2; exit 1; }

# Control 3: the lower-case token (symbol names) is not this gate's concern.
printf '%s\n' "sym=\"$(tok project)_init\"" > "$TMP/lower.sh"
[[ -z "$(active_tokens "$TMP/lower.sh")" ]] || { echo "FAIL: lower-case token was refused" >&2; exit 1; }

echo "PASS: no active unsubstituted token in aspect_tests.sh (3 controls)"
