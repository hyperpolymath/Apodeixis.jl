#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# proof_claims_rows_test.sh — controls for scripts/proof-claims-rows.sh, the
# reader behind `just proof-status`. Positive fixtures must print the claim
# rows; negative fixtures must fail loudly instead of printing a reassuring line.
#
# Exit: 0 all controls hold; 1 a control failed.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO_DIR/scripts/proof-claims-rows.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FAILED=0; CHECKS=0

# check LABEL WANT_RC FILE [MUST_CONTAIN] [MUST_NOT_CONTAIN]  (fixed-string matches)
check() {
    local label="$1" want="$2" file="$3" has="${4:-}" hasnt="${5:-}" rc=0 out
    out="$(bash "$GATE" "$file" 2>&1)" || rc=$?
    CHECKS=$((CHECKS + 1))
    if [ "$rc" -ne "$want" ]; then FAILED=$((FAILED + 1)); echo "  FAIL  $label (want rc=$want, got rc=$rc)"; sed 's/^/        /' <<<"$out"
    elif [ -n "$has" ] && ! grep -qF -- "$has" <<<"$out"; then FAILED=$((FAILED + 1)); echo "  FAIL  $label (output lacks: $has)"; sed 's/^/        /' <<<"$out"
    elif [ -n "$hasnt" ] && grep -qF -- "$hasnt" <<<"$out"; then FAILED=$((FAILED + 1)); echo "  FAIL  $label (output has: $hasnt)"; sed 's/^/        /' <<<"$out"
    else echo "  PASS  $label"; fi
}

cat >"$WORK/rows.adoc" <<'DOC'
== Claims

[cols="1,3"]
|===
| ID | Claim
| C-1 | first claim
| C-2 | second claim
|===

== Trust boundary

|===
| ID | Not a claim
| X-1 | must not be printed
|===
DOC
check "claim rows are printed" 0 "$WORK/rows.adoc" "| C-2 | second claim"
check "the header row is not printed" 0 "$WORK/rows.adoc" "| C-1 | first claim" "| ID | Claim"
check "a table in another section is not printed" 0 "$WORK/rows.adoc" "| C-1 | first claim" "X-1"
check "the shipped status file prints at least one row" 0 "$REPO_DIR/docs/status/PROOF-STATUS.adoc"
# The empty state is a fixture, not the shipped file: an inherited repository
# that records its first real claim must not fail this test.
printf '== Claims\n\n|===\n| ID | Claim\n| - | No claims yet\n|===\n' >"$WORK/empty.adoc"
check "an empty-state row is printed" 0 "$WORK/empty.adoc" "No claims yet"

cat >"$WORK/compact.adoc" <<'DOC'
== Claims

|===
|ID |Claim
|C-1 |compact claim
|===
DOC
check "compact cells (no space after the pipe) are printed" 0 "$WORK/compact.adoc" "|C-1 |compact claim"
check "the compact header row is not printed" 0 "$WORK/compact.adoc" "compact claim" "|ID |Claim"

cat >"$WORK/sourceblock.adoc" <<'DOC'
== Claims

No table, only an example:

----
| X-1 | looks like a row
----
DOC
check "a pipe line outside a table is not a claim row" 1 "$WORK/sourceblock.adoc"

printf '== Overview\n\ntext only\n' >"$WORK/nosection.adoc"
check "no Claims section fails" 1 "$WORK/nosection.adoc"
printf '== Claims\n\nno table here\n\n== Next\n' >"$WORK/notable.adoc"
check "a Claims section with no table fails" 1 "$WORK/notable.adoc"
printf '== Summary\n\n| **Total** | 3 | 100%%\n' >"$WORK/oldtotal.adoc"
check "an old Total row is not mistaken for claims" 1 "$WORK/oldtotal.adoc"
check "a missing file is a usage error (rc 2)" 2 "$WORK/absent.adoc"

echo "$CHECKS controls, $FAILED failed"
[ "$FAILED" -eq 0 ]
