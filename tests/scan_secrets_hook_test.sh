#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# scan_secrets_hook_test.sh — contract test for .github/hooks/scan-secrets.sh.
#
# Uses a fake scanner that records its arguments and exits with a chosen code,
# so it tests the hook's own logic (flags passed, depth-limit handling, scanner
# probing, exit handling). It does NOT test TruffleHog's detection or its real
# depth behaviour; that needs the real binary.
#
# SCRIPT=<path> runs the test against another copy of the hook (used to check
# that the test fails on an older hook).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO_ROOT/.github/hooks/scan-secrets.sh}"
ZERO="0000000000000000000000000000000000000000"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
check() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then echo "  PASS: $name"; else echo "  FAIL: $name (expected '$want', got '$got')"; fail=1; fi
}

cat > "$T/th" <<'FAKE_SCANNER'
#!/bin/sh
if [ "$1" = "--version" ]; then echo "trufflehog 3.96.0"; exit 0; fi
if [ "$1" = "--help" ]; then
  echo "usage: trufflehog [flags]"
  echo "  --fail  Exit with code 183 if results are found."
  [ "${NO_FLAG_SUPPORT:-0}" = "1" ] || echo "  --fail-on-scan-errors  Exit non-zero if an error occurs during the scan."
  exit 0
fi
echo "$@" >> "$TH_LOG"
exit "${TH_RC:-0}"
FAKE_SCANNER
chmod +x "$T/th"

# Isolate scanner discovery: the hook falls back to `trufflehog` on PATH and to
# mise installs, so a real scanner on a developer machine would otherwise be
# selected instead of the fake. Shadow it with a rejecting stub and give mise an
# empty data dir, so only $TRUFFLEHOG can ever be chosen.
mkdir -p "$T/bin" "$T/mise"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/trufflehog"; chmod +x "$T/bin/trufflehog"

git init -q "$T/repo"
git -C "$T/repo" config user.email t@example.invalid
git -C "$T/repo" config user.name t
git -C "$T/repo" config commit.gpgsign false
for i in 1 2 3; do echo "$i" > "$T/repo/f"; git -C "$T/repo" add f; git -C "$T/repo" commit -qm "c$i"; done
HEAD_SHA="$(git -C "$T/repo" rev-parse HEAD)"

run() { # ranges depth rc [no_flag_support] -> sets RC, CALLS, ARGS
  export TH_LOG="$T/log"; : > "$TH_LOG"
  RC=0
  PATH="$T/bin:$PATH" MISE_DATA_DIR="$T/mise" INPUT_PATH="$T/repo" TRUFFLEHOG="$T/th" K9_PUSH_RANGES="$1" K9_SECRETS_MAX_DEPTH="$2" TH_RC="${3:-0}" NO_FLAG_SUPPORT="${4:-0}" \
    bash "$SCRIPT" >"$T/out" 2>&1 || RC=$?
  CALLS="$(wc -l < "$TH_LOG" | tr -d ' ')"; ARGS="$(cat "$TH_LOG")"
}
NEW="refs/heads/x $HEAD_SHA refs/heads/x $ZERO"

echo "scan-secrets hook:"
run "$NEW" 500 0
check "clean new branch passes" "$RC" 0
check "scanner told to fail on scan errors" "$(grep -c -- '--fail-on-scan-errors' <<<"$ARGS")" 1

run "$NEW" 2 0
check "history larger than the depth limit is blocked" "$RC" 1
check "…and no partial scan is run" "$CALLS" 0

run "$NEW" 3 0
check "history EQUAL to the depth limit is blocked (the limit can cut the oldest commit)" "$RC" 1
run "$NEW" 4 0
check "history below the depth limit passes" "$RC" 0

# Shared history: the branch adds 1 commit on top of a commit that is already
# in a remote-tracking ref. The scanner still walks all 4 commits, so the
# guard must count 4, not 1.
git -C "$T/repo" update-ref refs/remotes/origin/main "$HEAD_SHA"
echo 4 > "$T/repo/f"; git -C "$T/repo" add f; git -C "$T/repo" commit -qm c4
TOP_SHA="$(git -C "$T/repo" rev-parse HEAD)"
run "refs/heads/y $TOP_SHA refs/heads/y $ZERO" 3 0
check "history shared with a remote ref still counts toward the limit" "$RC" 1
check "…and no partial scan is run for it" "$CALLS" 0

run "" 500 0
check "fallback scan passes" "$RC" 0
check "fallback scans HEAD explicitly" "$(grep -c -- '--branch HEAD' <<<"$ARGS")" 1

run "$NEW" 500 0 1
check "a scanner without --fail-on-scan-errors is rejected" "$RC" 1
check "…and it is never invoked to scan" "$CALLS" 0
check "…and the user is told it is too old" "$(grep -c 'too old' "$T/out")" 1

run "$NEW" 500 1
check "scanner error blocks" "$RC" 1
check "scanner error is reported as an error" "$(grep -c 'SCANNER ERROR' "$T/out")" 1
check "error report does not deny a possible finding" "$(grep -c 'may ALSO contain a detected secret' "$T/out")" 1
check "error report no longer says 'NOT a detected secret'" "$(grep -c 'NOT a detected secret' "$T/out")" 0

run "$NEW" 500 183
check "findings block" "$RC" 1

if [[ "$fail" -eq 0 ]]; then echo "PASS: scan-secrets hook contract"; else echo "FAIL: scan-secrets hook contract"; exit 1; fi
