#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# The mint drops a line it has no answer for (`sed -i "/…token…/d" FILE` in
# build/just/repo-init.just: the OpenSSF badge in README.adoc, the ORCID line in
# CITATION.cff). That is only safe where the line is the WHOLE construct. It once
# ran on a six-column table, where the token's line was one cell; the row came out
# short and the render gate failed in every child minted without an OpenSSF id
# (fixed 2026-10-14, 0afa6c9; CoprocessorRuntime.jl#2 carried the old result).
#
# Guard: read every token-bearing deletion out of repo-init.just, find the lines it
# would delete in the shipped file, and require each to be a standalone construct:
#   *.adoc  one `image:…[…]` macro alone on its line, outside any table;
#   *.cff   one `key: "value"` line with nothing indented under it, not a list item.
# A deletion in a file type with no rule here fails closed, and so does finding no
# deletion or no matching line, so the guard cannot pass by matching nothing.
# Tokens are built at run time: this file must not itself carry a literal token.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The guard reads the TEMPLATE's token-bearing lines. In a repo minted from the
# template the mint has already filled or deleted them, so there is nothing to
# guard there (the same rule as tests/shape/rust_cli_root_shape_test.sh).
if ! bash "$ROOT/scripts/is-template-tree.sh" "$ROOT"; then
    echo "SKIP: mint scrub constructs (not the template tree; is-template-tree.sh says no)"
    exit 0
fi
RECIPE="$ROOT/build/just/repo-init.just"
LB=$(printf '\x7b\x7b'); RB=$(printf '\x7d\x7d')

# standalone_adoc FILE LINENO — 0 when the line is a lone image macro outside a table.
standalone_adoc() {
    local file="$1" n="$2" line fences
    line="$(sed -n "${n}p" "$file")"
    [[ "$line" =~ ^image:[^[:space:]]*\[.*\]$ ]] || return 1
    [[ "$(grep -o 'image:' <<<"$line" | wc -l)" -eq 1 ]] || return 1
    fences="$(head -n "$n" "$file" | grep -c '^|===')"
    (( fences % 2 == 0 )) || return 1
    return 0
}

# standalone_cff FILE LINENO — 0 when the line is a lone key: "value" with no children.
standalone_cff() {
    local file="$1" n="$2" line next ind nind
    line="$(sed -n "${n}p" "$file")"
    [[ "$line" =~ ^[[:space:]]*[A-Za-z_-]+:[[:space:]]*\"[^\"]*\"[[:space:]]*$ ]] || return 1
    next="$(sed -n "$((n + 1)),\$p" "$file" | grep -m1 -v '^[[:space:]]*$' || true)"
    [[ -z "$next" ]] && return 0
    ind="${line%%[![:space:]]*}"; nind="${next%%[![:space:]]*}"
    (( ${#nind} <= ${#ind} )) || return 1
    return 0
}

# judge FILE PATTERN — print a reason and return 1 unless every deleted line is whole.
judge() {
    local file="$1" pat="$2" hits n rc=0
    hits="$(grep -n -- "$pat" "$file" | cut -d: -f1 || true)"
    [[ -n "$hits" ]] || { echo "the deletion '$pat' matches no line of $(basename "$file"), so it guards nothing"; return 1; }
    for n in $hits; do
        case "$file" in
            *.adoc) standalone_adoc "$file" "$n" || { echo "$(basename "$file"):$n is not a lone image macro outside a table"; rc=1; } ;;
            *.cff)  standalone_cff  "$file" "$n" || { echo "$(basename "$file"):$n is not a lone key: \"value\" line"; rc=1; } ;;
            *)      echo "no standalone rule for $(basename "$file"); add one before scrubbing it"; return 1 ;;
        esac
    done
    return $rc
}

# deletions RECIPE — "FILE<TAB>PATTERN" for each token-bearing `sed -i "/…/d" FILE`.
deletions() {
    local recipe="$1"
    grep -E 'sed -i "/.*\$\{LB\}.*/d" [A-Za-z0-9_./-]+' "$recipe" | while IFS= read -r l; do
        pat="${l#*sed -i \"/}"; pat="${pat%%/d\"*}"
        file="$(sed -E 's#.*/d" ([A-Za-z0-9_./-]+).*#\1#' <<<"$l")"
        pat="${pat//\\\//\/}"; pat="${pat//\$\{LB\}/$LB}"; pat="${pat//\$\{RB\}/$RB}"
        printf '%s\t%s\n' "$file" "$pat"
    done
}

list="$(deletions "$RECIPE" || true)"
count="$(grep -c . <<<"$list" || true)"
(( count >= 2 )) || { echo "FAIL: found $count token-bearing deletions in repo-init.just; expected the README and CITATION ones" >&2; exit 1; }

bad=0
while IFS=$'\t' read -r file pat; do
    [[ -f "$ROOT/$file" ]] || { echo "FAIL: $file is scrubbed by repo-init.just but absent" >&2; bad=1; continue; }
    if ! msg="$(judge "$ROOT/$file" "$pat")"; then echo "FAIL: $msg" >&2; bad=1; fi
done <<<"$list"
(( bad == 0 )) || exit 1

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
tok="${LB}OPENSSF_BP_ID${RB}"
expect_refused() { # LABEL FILE PATTERN
    local label="$1" file="$2" pattern="$3"
    if judge "$file" "$pattern" >/dev/null 2>&1; then echo "FAIL: control accepted: $label" >&2; exit 1; fi
}
expect_accepted() {
    local label="$1" file="$2" pattern="$3"
    judge "$file" "$pattern" >/dev/null 2>&1 || { echo "FAIL: control refused: $label" >&2; exit 1; }
}
pat="bestpractices\\.dev/projects/$tok"
printf 'image:https://x/bestpractices.dev/projects/%s/badge[Badge,link="https://x"]\n' "$tok" > "$TMP/ok.adoc"
expect_accepted "a lone image macro" "$TMP/ok.adoc" "$pat"
printf '|===\n| a | b\n| image:https://x/bestpractices.dev/projects/%s/badge[B] | c\n|===\n' "$tok" > "$TMP/table.adoc"
expect_refused "the token inside a table row (the 2026-10-14 defect)" "$TMP/table.adoc" "$pat"
printf '* image:https://x/bestpractices.dev/projects/%s/badge[B]\n' "$tok" > "$TMP/list.adoc"
expect_refused "the token in a list item" "$TMP/list.adoc" "$pat"
printf 'See the badge image:https://x/bestpractices.dev/projects/%s/badge[B] for the status.\n' "$tok" > "$TMP/prose.adoc"
expect_refused "the token inside a sentence" "$TMP/prose.adoc" "$pat"
printf 'image:https://x/bestpractices.dev/projects/%s/badge[B] image:https://y[C]\n' "$tok" > "$TMP/two.adoc"
expect_refused "two macros on one line" "$TMP/two.adoc" "$pat"
printf 'nothing here\n' > "$TMP/none.adoc"
expect_refused "a deletion that matches no line" "$TMP/none.adoc" "$pat"
cpat="orcid\\.org/${LB}AUTHOR_ORCID${RB}"
printf 'authors:\n  - family-names: X\n    orcid: "https://orcid.org/%s"\n' "${LB}AUTHOR_ORCID${RB}" > "$TMP/ok.cff"
expect_accepted "a lone cff key" "$TMP/ok.cff" "$cpat"
printf 'orcid: "https://orcid.org/%s"\n  nested: 1\n' "${LB}AUTHOR_ORCID${RB}" > "$TMP/child.cff"
expect_refused "a cff key with a child line" "$TMP/child.cff" "$cpat"
printf -- '- "https://orcid.org/%s"\n' "${LB}AUTHOR_ORCID${RB}" > "$TMP/item.cff"
expect_refused "a cff list item" "$TMP/item.cff" "$cpat"
printf 'x\n' > "$TMP/other.txt"; printf 'orcid.org/%s\n' "${LB}AUTHOR_ORCID${RB}" > "$TMP/other.txt"
expect_refused "a file type with no rule" "$TMP/other.txt" "$cpat"

echo "PASS: every line the mint scrub can delete is a standalone construct ($count deletions, 10 controls)"
