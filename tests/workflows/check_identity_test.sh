#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Controls for scripts/check-identity.sh (standards A1 v0.4.5 T30, ruling Q2):
# a v8 #uuid and a #u8 pass in both identity fields; a v5 id, a #u5 literal,
# an upper-case or v4 id and a missing :repo-uuid fail, each named. The v5 and
# #u5 inputs are assembled at run time, so no committed file carries one in an
# identity field (standards scripts/check-uuid-v8.sh reads files by name).
set -euo pipefail

CHECKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/check-identity.sh"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

V8='#uuid"8e515699-3fb9-8785-8883-ef2a100c2e02"'
ESTATE='#uuid"0889b37b-defb-831f-973c-e119500db00e"'
U8='#u8"chora-registry:github.com/example-owner/x"'
U5="#u5\"github.com/example-owner/x\""
# Joined from parts so no committed line holds a v4, v5 or upper-case UUID.
P1="0d3a0e5b-1b1a"; P2="9e2f-112233445566"
V5="#uuid\"$P1-5c3d-$P2\""
V4="#uuid\"$P1-4c3d-$P2\""
UPPER="#uuid\"$(printf '%s' 8e515699-3fb9-8785-8883-ef2a100c2e02 | tr a-f A-F)\""

# deed REPO_UUID [BEHOLDING] -> path of a minimal repo deed
n=0
deed() {
  local id="$1" behold="${2:-}"
  n=$((n + 1))
  local f="$FIXTURE/case$n/x_chora.deed"
  mkdir -p "$(dirname "$f")"
  {
    printf ';; SPDX-License-Identifier: CC-BY-SA-4.0\n(repo-deed :schema-version "1.0.0" :canonical-name "x"'
    [[ -n "$behold" ]] && printf '\n  :beholding-chora %s' "$behold"
    [[ -n "$id" ]] && printf '\n  :repo-uuid %s' "$id"
    printf '\n  (identity :primary-forge github))\n'
  } > "$f"
  printf '%s' "$f"
}

# expect_pass WHAT DEED
expect_pass() {
  local what="$1" f="$2"
  bash "$CHECKER" "$f" > "$FIXTURE/out" 2>&1 || { echo "FAIL: checker refused $what" >&2; cat "$FIXTURE/out" >&2; exit 1; }
}
# expect_fail WHAT DEED NEEDLE
expect_fail() {
  local what="$1" f="$2" needle="$3" rc=0
  bash "$CHECKER" "$f" > "$FIXTURE/out" 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] || { echo "FAIL: checker gave $rc, not 1, for $what" >&2; cat "$FIXTURE/out" >&2; exit 1; }
  grep -qF -- "$needle" "$FIXTURE/out" || { echo "FAIL: checker did not say '$needle' for $what" >&2; cat "$FIXTURE/out" >&2; exit 1; }
}

expect_pass "a v8 #uuid :repo-uuid" "$(deed "$V8")"
expect_pass "a v8 :repo-uuid and a v8 :beholding-chora" "$(deed "$V8" "$ESTATE")"
expect_pass "a #u8 :repo-uuid (S2)" "$(deed "$U8")"
expect_pass "a #u8 :beholding-chora (S2)" "$(deed "$V8" "#u8\"chora:estate/github.com/example-owner\"")"
expect_fail "a v5 :repo-uuid (lax is not a warning tier)" "$(deed "$V5")" "v5-identity"
expect_fail "a #u5 :repo-uuid" "$(deed "$U5")" "u5-identity"
expect_fail "a #u5 :beholding-chora beside a good id" "$(deed "$V8" "#u5\"estate/chora\"")" ":beholding-chora"
expect_fail "a v5 :beholding-chora" "$(deed "$V8" "$V5")" "v5-identity"
expect_fail "a v4 :repo-uuid" "$(deed "$V4")" "not a lowercase version 5 or 8"
expect_fail "an upper-case :repo-uuid" "$(deed "$UPPER")" "not a lowercase version 5 or 8"
expect_fail "a missing :repo-uuid" "$(deed "")" ":repo-uuid is missing"

# Usage errors are 2, never a silent pass.
rc=0; bash "$CHECKER" >/dev/null 2>&1 || rc=$?; [[ "$rc" -eq 2 ]] || { echo "FAIL: no argument gave $rc, not 2" >&2; exit 1; }
rc=0; bash "$CHECKER" "$FIXTURE/none.deed" >/dev/null 2>&1 || rc=$?; [[ "$rc" -eq 2 ]] || { echo "FAIL: a missing deed gave $rc, not 2" >&2; exit 1; }

# The template's own deed passes. Only the template tree (scripts/is-template-tree.sh)
# carries it under this name: a minted repository's deed is <name>_chora.deed, and this
# test is carried into every child, so other trees skip this one control with a notice.
ROOT="$(cd "$(dirname "$CHECKER")/.." && pwd)"
if bash "$ROOT/scripts/is-template-tree.sh" "$ROOT"; then
    expect_pass "the template's own deed" "$ROOT/rsr-template-repo_chora.deed"
else
    echo "SKIP: the template's-own-deed control (not the template tree; is-template-tree.sh says no)"
fi

echo "PASS: check-identity controls (v8 and #u8 pass; v5, #u5, v4, upper-case and missing fail; usage is 2)"
