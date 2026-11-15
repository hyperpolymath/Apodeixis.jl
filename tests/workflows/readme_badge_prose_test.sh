#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# README.adoc is substituted by the mint, so a token written into PROSE of the
# "Governance badges" section turns into the child's own owner and repository
# name inside a sentence that is about placeholders ("replaces the <owner> and
# <repo> placeholders"). Guard: that section carries no brace token. Badge
# image lines elsewhere keep theirs, because there the token is the point.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="${1:-$ROOT/README.adoc}"

section_tokens() {
    local file="$1"
    awk '
        /^== /            { in_sec = ($0 == "== Governance badges"); next }
        in_sec && /\{\{[A-Za-z_]+\}\}/ { print NR ": " $0 }
    ' "$file"
}

hits="$(section_tokens "$TARGET")"
if [[ -n "$hits" ]]; then
    echo "FAIL: the Governance badges prose carries a brace token:" >&2
    echo "$hits" >&2
    exit 1
fi

# The section must exist, or the guard would pass on a renamed heading.
grep -qx '== Governance badges' "$TARGET" || { echo "FAIL: no '== Governance badges' section" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
tok() { local name="$1"; printf "%s%s%s" "{""{" "$name" "}""}"; }

# Control 1: the old sentence is refused.
printf '== Governance badges\n\nrepo-init replaces the %s and %s placeholders\n' "$(tok OWNER)" "$(tok REPO)" > "$TMP/old.adoc"
[[ -n "$(section_tokens "$TMP/old.adoc")" ]] || { echo "FAIL: old sentence was accepted" >&2; exit 1; }

# Control 2: a token in another section (a badge line) is not this gate's concern.
printf '== Other\n\nimage:x[%s]\n\n== Governance badges\n\nplain prose\n' "$(tok OWNER)" > "$TMP/other.adoc"
[[ -z "$(section_tokens "$TMP/other.adoc")" ]] || { echo "FAIL: a token outside the section was refused" >&2; exit 1; }

# Control 3: a renamed heading must not pass silently.
printf '== Badges\n\nplain\n' > "$TMP/renamed.adoc"
if bash "$0" "$TMP/renamed.adoc" >/dev/null 2>&1; then echo "FAIL: a renamed heading passed" >&2; exit 1; fi

echo "PASS: no brace token in the Governance badges prose (3 controls)"
