#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check_no_md_in_docs_test.sh — positive and negative controls for
# scripts/check-no-md-in-docs.sh. A gate with no failing input cannot be
# reviewed by reading it, so each verdict is shown on a fixture.
#
# Exit: 0 all controls hold; 1 a control failed.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO_DIR/scripts/check-no-md-in-docs.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
CHECKS=0
# names_literally OUTPUT PATTERN — fixed-string match, so a '.' in a filename is
# not a regex wildcard and a near-miss like docs/NOTESXmd cannot satisfy it.
names_literally() { local out="$1" pat="$2"; grep -qF -- "$pat" <<<"$out"; }

check() { # LABEL EXPECTED_RC DIR [STDERR_PATTERN]
    local label="$1" want="$2" dir="$3" pat="${4:-}" rc=0 out
    out="$(bash "$GATE" "$dir" 2>&1)" || rc=$?
    CHECKS=$((CHECKS + 1))
    if [[ "$rc" -ne "$want" ]]; then
        FAILED=$((FAILED + 1)); echo "  FAIL  $label (want rc=$want, got rc=$rc)"; echo "$out" | sed 's/^/        /'
    elif [[ -n "$pat" ]] && ! names_literally "$out" "$pat"; then
        FAILED=$((FAILED + 1)); echo "  FAIL  $label (rc ok, output lacks: $pat)"; echo "$out" | sed 's/^/        /'
    else
        echo "  PASS  $label"
    fi
}

mk() { local d="$1"; rm -rf "$WORK/$d"; mkdir -p "$WORK/$d"; }

# Positive: no docs/ directory at all.
mk nodocs
check "no docs/ directory passes" 0 "$WORK/nodocs" "no docs/ directory"

# Positive: only .adoc under docs/.
mk adoc; mkdir -p "$WORK/adoc/docs/sub"; : >"$WORK/adoc/docs/a.adoc"; : >"$WORK/adoc/docs/sub/b.adoc"
check "only .adoc under docs/ passes" 0 "$WORK/adoc"

# Positive: a root-level .md (community-health file) is not under docs/.
mk rootmd; mkdir -p "$WORK/rootmd/docs"; : >"$WORK/rootmd/CONTRIBUTING.md"
check "a root .md passes" 0 "$WORK/rootmd"

# Positive: the wiki-sync trees are allow-listed.
mk wiki; mkdir -p "$WORK/wiki/docs/berrywiki" "$WORK/wiki/docs/wikis/x"
: >"$WORK/wiki/docs/berrywiki/Home.md"; : >"$WORK/wiki/docs/wikis/x/Page.md"
check "docs/berrywiki and docs/wikis .md pass" 0 "$WORK/wiki"

# Negative: an .md directly under docs/.
mk bad1; mkdir -p "$WORK/bad1/docs"; : >"$WORK/bad1/docs/NOTES.md"
check "docs/NOTES.md fails and is named" 1 "$WORK/bad1" "docs/NOTES.md"

# Negative: a nested .md.
mk bad2; mkdir -p "$WORK/bad2/docs/deep/er"; : >"$WORK/bad2/docs/deep/er/x.md"
check "a nested docs .md fails" 1 "$WORK/bad2" "docs/deep/er/x.md"

# Negative: an allow-listed tree does not hide a sibling .md.
mk bad3; mkdir -p "$WORK/bad3/docs/wikis"; : >"$WORK/bad3/docs/wikis/ok.md"; : >"$WORK/bad3/docs/stray.md"
check "a stray .md beside an allow-listed tree fails" 1 "$WORK/bad3" "docs/stray.md"

# Negative: a lookalike directory name is not allow-listed.
mk bad4; mkdir -p "$WORK/bad4/docs/wikis-old"; : >"$WORK/bad4/docs/wikis-old/p.md"
check "docs/wikis-old is not allow-listed" 1 "$WORK/bad4" "docs/wikis-old/p.md"

# Control: the filename match is literal. A near-miss must not satisfy it.
CHECKS=$((CHECKS + 2))
if names_literally "docs/NOTESXmd" "docs/NOTES.md"; then
    FAILED=$((FAILED + 1)); echo "  FAIL  a near-miss filename satisfied the literal match"
else
    echo "  PASS  a near-miss filename does not satisfy the literal match"
fi
if names_literally "docs/NOTES.md" "docs/NOTES.md"; then
    echo "  PASS  the exact filename satisfies the literal match"
else
    FAILED=$((FAILED + 1)); echo "  FAIL  the exact filename did not satisfy the literal match"
fi

echo "$CHECKS controls, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
