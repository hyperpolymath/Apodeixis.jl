#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# The vocabulary in docs/status/PROOF-STATUS.adoc must agree with itself. It
# said `ungraded` was for a theory theorem below PWG-3 and `n/a` for engineering
# proofs, while another sentence said any claim without a receipt stays
# `ungraded`. An engineering obligation that is still `open` therefore had two
# answers, and downstream repositories split on it. Owner ruling: every open row
# is `ungraded`; `n/a` is for a row that already has a result.
#
# Guard, in three parts:
#   1. the `ungraded` bullet covers `open` rows;
#   2. the `n/a` bullet says an `open` engineering obligation stays `ungraded`;
#   3. the sentence "a claim that has none stays `ungraded`" is still there.
# Fixtures first: the old wording and a half-fixed one must fail.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="${1:-$ROOT/docs/status/PROOF-STATUS.adoc}"

# bullet FILE WORD — the vocabulary bullet that starts with the given word.
bullet() {
    local file="$1" word="$2"
    awk -v w="$word" '
        $0 ~ "^\\*\\* `" w "`" { on = 1; print; next }
        on && /^(\*|$)/       { on = 0 }
        on                    { print }
    ' "$file"
}

verdict() {
    local file="$1" ung na flat uflat
    ung="$(bullet "$file" 'ungraded')"
    na="$(bullet "$file" 'n/a')"
    [[ -n "$ung" && -n "$na" ]] || { echo "no ungraded or n/a bullet"; return 1; }
    uflat="$(tr -s "[:space:]" " " <<<"$ung")"
    grep -qF 'an `open` row included' <<<"$uflat" || { echo "the ungraded bullet does not say an open row is included"; return 1; }
    flat="$(tr -s "[:space:]" " " <<<"$na")"
    grep -qF 'an `open` engineering obligation stays `ungraded`' <<<"$flat" || { echo "the n/a bullet does not say an open engineering obligation stays ungraded"; return 1; }
    grep -qF 'a claim that has none stays `ungraded`' "$file" || { echo "the no-receipt sentence is gone"; return 1; }
    return 0
}

if ! msg="$(verdict "$TARGET")"; then
    echo "FAIL: $msg" >&2
    exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Control 1: the old wording is refused.
cat >"$TMP/old.adoc" <<'DOC'
* *PWG*:
** `ungraded`: a theory theorem below `PWG-3`;
** `n/a`: not a theory theorem (a test, a refusal fixture, an assumption, or an
   engineering proof in Idris2, SPARK, Creusot or Verus). §8.1 puts these off the
   ladder.
* *Recheck legs*
a claim that has none stays `ungraded`.
DOC
if verdict "$TMP/old.adoc" >/dev/null 2>&1; then echo "FAIL: the old wording was accepted" >&2; exit 1; fi

# Control 2: fixing only the ungraded bullet is refused (n/a still silent on open).
sed 's/^\*\* `n\/a`.*//' "$TARGET" > "$TMP/half.adoc"
if verdict "$TMP/half.adoc" >/dev/null 2>&1; then echo "FAIL: a missing n/a bullet was accepted" >&2; exit 1; fi

# Control 4: the inverse rule (open row must not be ungraded) is refused.
sed 's/stays `ungraded`/must not be `ungraded`/' "$TARGET" > "$TMP/inverse.adoc"
if verdict "$TMP/inverse.adoc" >/dev/null 2>&1; then echo "FAIL: the inverse wording was accepted" >&2; exit 1; fi

# Control 5: the ungraded bullet saying the opposite (an open row is never included) is refused.
perl -0pe 's/an\s+`open` row included/an `open` row is never included/' "$TARGET" > "$TMP/ungraded_inverse.adoc"
if verdict "$TMP/ungraded_inverse.adoc" >/dev/null 2>&1; then echo "FAIL: the inverse ungraded wording was accepted" >&2; exit 1; fi

# Control 3: dropping the no-receipt sentence is refused.
sed 's/a claim that has none stays `ungraded`/a claim stays open/' "$TARGET" > "$TMP/nosentence.adoc"
if verdict "$TMP/nosentence.adoc" >/dev/null 2>&1; then echo "FAIL: a missing no-receipt sentence was accepted" >&2; exit 1; fi

echo "PASS: the PROOF-STATUS vocabulary agrees with itself (5 controls)"
