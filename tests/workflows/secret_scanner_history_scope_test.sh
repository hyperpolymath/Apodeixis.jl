#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# secret_scanner_history_scope_test.sh — the gitleaks full-history pass is
# bounded on pull requests and full everywhere else, and it can still FAIL in
# both modes. (metadatastician/standards#1587)
#
# WHY THIS EXISTS
#
#   gitleaks' git mode, given no --log-opts, walks every commit on every
#   branch (`git log -p -U0 --full-history --all`). This workflow ran that on
#   every pull request, so the scan's cost grew with the repository's age
#   rather than the change, and timed out on large repos. The "History scope"
#   step now picks the range from the event. A bounded gate is only worth
#   having if the bound cannot quietly become "nothing", so every case asserts
#   what was scanned AND that a planted secret in that scope still fails.
#
# WHAT IT TESTS AGAINST
#
#   Both step bodies ("History scope" and "Gitleaks full-history pass") are
#   extracted from the shipping workflow with yq and run as written.
#
# Needs: git, yq (mikefarah v4), curl, and gitleaks. When no gitleaks is on
# PATH and GITLEAKS_BIN is unset, the version and checksum in the gitleaks
# job's env are downloaded and verified, so the test and the gate use the
# same binary.
#
# Usage: bash tests/workflows/secret_scanner_history_scope_test.sh [workflow]
# Exit:  0 = all cases behaved, 1 = a case failed, 2 = a prerequisite is missing.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WF="${1:-$REPO_DIR/.github/workflows/secret-scanner.yml}"

for tool in git yq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "::error::$tool is required" >&2; exit 2; }
done
[[ -f "$WF" ]] || { echo "::error::workflow not found at $WF" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export RUNNER_TEMP="$WORK/runner"
mkdir -p "$RUNNER_TEMP"

step_body() {
  local name="$1"
  yq -e "[.jobs.gitleaks.steps[] | select(.name == \"$name\")][0] | .run" "$WF"
}

# --- gitleaks: the pinned binary, or one the caller provides ---------------
if [[ -n "${GITLEAKS_BIN:-}" ]]; then
  cp "$GITLEAKS_BIN" "$RUNNER_TEMP/gitleaks"
elif command -v gitleaks >/dev/null 2>&1; then
  cp "$(command -v gitleaks)" "$RUNNER_TEMP/gitleaks"
else
  ver="$(yq -e '.jobs.gitleaks.env.GITLEAKS_VERSION' "$WF")" &&
    sum="$(yq -e '.jobs.gitleaks.env.GITLEAKS_SHA256' "$WF")" || {
      echo "::error::could not read the gitleaks pin from the workflow" >&2; exit 2; }
  tb="gitleaks_${ver}_linux_x64.tar.gz"
  if ! { curl -sSfL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 \
           -o "$RUNNER_TEMP/$tb" \
           "https://github.com/gitleaks/gitleaks/releases/download/v${ver}/${tb}" &&
         echo "${sum}  $RUNNER_TEMP/$tb" | sha256sum -c - &&
         tar -xzf "$RUNNER_TEMP/$tb" -C "$RUNNER_TEMP" gitleaks; } >/dev/null 2>&1; then
    echo "::error::could not install the pinned gitleaks (network?)" >&2; exit 2
  fi
fi
chmod +x "$RUNNER_TEMP/gitleaks"

step_body 'History scope' > "$WORK/scope.sh" || { echo "::error::no 'History scope' step" >&2; exit 1; }
step_body 'Gitleaks full-history pass' > "$WORK/history.sh" || { echo "::error::no full-history step" >&2; exit 1; }

# A token shaped like a GitHub PAT, assembled at run time so that this file
# itself never contains one.
SECRET="ghp_""A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"

pass=0
fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1" >&2; fail=$((fail + 1)); }

commit() {
  local repo="$1" msg="$2"
  git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm "$msg"
}
merge() {
  local repo="$1"
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid merge -q --no-ff feature -m merge
}

# repo with an OLD secret committed then deleted on main, then clean work.
make_repo() {
  local r="$WORK/$1"
  rm -rf "$r"; mkdir -p "$r"
  git -C "$r" init -q -b main
  printf '[extend]\nuseDefault = true\n' > "$r/.gitleaks-estate.toml"
  echo "readme" > "$r/README.txt"; commit "$r" base
  printf 'token = "%s"\n' "$SECRET" > "$r/old.txt"; commit "$r" "old secret"
  rm "$r/old.txt"; commit "$r" "old secret removed"
  echo "$r"
}

# run_case NAME REPO EVENT [PR_BASE] [MG_BASE] -> sets RANGE, SCAN_RC
run_case() {
  local repo=$2 out="$WORK/out.$1"
  : > "$WORK/gh_output"
  if ! ( cd "$repo" && EVENT_NAME=$3 PR_BASE_SHA=${4:-} MG_BASE_SHA=${5:-} \
           GITHUB_OUTPUT="$WORK/gh_output" bash "$WORK/scope.sh" ) > "$out" 2>&1; then
    RANGE="<scope step failed>"; SCAN_RC=99; cat "$out" >&2; return
  fi
  RANGE="$(sed -n 's/^range=//p' "$WORK/gh_output")"
  ( cd "$repo" && SCAN_RANGE=$RANGE bash "$WORK/history.sh" ) >> "$out" 2>&1
  SCAN_RC=$?
}

echo "=== History scope of the gitleaks full-history pass ==="

# 1. PR on a merge commit, clean change: the old secret on main does not block it.
r="$(make_repo pr_clean)"
git -C "$r" checkout -q -b feature
echo "clean" > "$r/feature.txt"; commit "$r" "clean feature"
git -C "$r" checkout -q main; merge "$r"
run_case pr_clean "$r" pull_request
if [[ "$RANGE" = "HEAD^1..HEAD" ]] && [[ "$SCAN_RC" -eq 0 ]]; then ok "PR merge commit, clean change: DIFF scope, passes"
else bad "PR merge commit, clean change: range=$RANGE rc=$SCAN_RC"; fi

# 2. PR that adds a secret and deletes it in a later commit: still caught.
r="$(make_repo pr_secret)"
git -C "$r" checkout -q -b feature
printf 'key = "%s"\n' "$SECRET" > "$r/new.txt"; commit "$r" "add secret"
rm "$r/new.txt"; commit "$r" "hide secret"
git -C "$r" checkout -q main; merge "$r"
run_case pr_secret "$r" pull_request
if [[ "$RANGE" = "HEAD^1..HEAD" ]] && [[ "$SCAN_RC" -ne 0 ]]; then ok "PR adds then deletes a secret: DIFF scope, fails"
else bad "PR adds then deletes a secret: range=$RANGE rc=$SCAN_RC"; fi

# 3-4. push and schedule: full history, so the old deleted secret is found.
r="$(make_repo full)"
for ev in push schedule workflow_dispatch; do
  run_case "full_$ev" "$r" "$ev"
  if [[ "$RANGE" = "--all" ]] && [[ "$SCAN_RC" -ne 0 ]]; then ok "$ev: FULL scope, finds the old secret"
  else bad "$ev: range=$RANGE rc=$SCAN_RC"; fi
done

# 4b. A secret committed and deleted ONLY on an unmerged branch is still found
#     by the full scan (every ref, not just HEAD's ancestors).
r="$WORK/stray"; rm -rf "$r"; mkdir -p "$r"
git -C "$r" init -q -b main
printf '[extend]\nuseDefault = true\n' > "$r/.gitleaks-estate.toml"
echo "readme" > "$r/README.txt"; commit "$r" base
git -C "$r" checkout -q -b stray
printf 'k = "%s"\n' "$SECRET" > "$r/s.txt"; commit "$r" "stray secret"
rm "$r/s.txt"; commit "$r" "stray secret removed"
git -C "$r" checkout -q main
run_case stray "$r" push
if [[ "$RANGE" = "--all" ]] && [[ "$SCAN_RC" -ne 0 ]]; then ok "push: FULL scope finds a secret on an unmerged branch"
else bad "push: secret on an unmerged branch missed (range=$RANGE rc=$SCAN_RC)"; fi

# 5. PR checkout that is not a merge commit, with a known base: base..HEAD.
r="$(make_repo pr_linear)"
base="$(git -C "$r" rev-parse HEAD)"
echo "clean" > "$r/x.txt"; commit "$r" "linear clean"
run_case pr_linear "$r" pull_request "$base"
if [[ "$RANGE" = "$base..HEAD" ]] && [[ "$SCAN_RC" -eq 0 ]]; then ok "PR without merge commit: base..HEAD, passes"
else bad "PR without merge commit: range=$RANGE rc=$SCAN_RC"; fi

# 6. PR whose base cannot be resolved: FULL, never nothing.
run_case pr_nobase "$r" pull_request "0000000000000000000000000000000000000000"
if [[ "$RANGE" = "--all" ]] && [[ "$SCAN_RC" -ne 0 ]]; then ok "PR with unresolvable base: falls back to FULL"
else bad "PR with unresolvable base: range=$RANGE rc=$SCAN_RC"; fi

# 7. An empty range (base == HEAD) falls back to FULL instead of scanning 0 commits.
run_case pr_empty "$r" pull_request "$(git -C "$r" rev-parse HEAD)"
if [[ "$RANGE" = "--all" ]] && [[ "$SCAN_RC" -ne 0 ]]; then ok "PR with empty range: falls back to FULL"
else bad "PR with empty range: range=$RANGE rc=$SCAN_RC"; fi

# 8. merge_group: base_sha..HEAD.
run_case mg "$r" merge_group "" "$base"
if [[ "$RANGE" = "$base..HEAD" ]] && [[ "$SCAN_RC" -eq 0 ]]; then ok "merge_group: base_sha..HEAD"
else bad "merge_group: range=$RANGE rc=$SCAN_RC"; fi

# 9. The history step refuses an empty scope rather than scanning nothing.
if ( cd "$r" && SCAN_RANGE='' bash "$WORK/history.sh" ) >/dev/null 2>&1; then
  bad "history step accepted an empty SCAN_RANGE"
else ok "history step refuses an empty SCAN_RANGE"; fi

echo
echo "history-scope: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
