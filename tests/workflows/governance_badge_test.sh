#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Silence + Firing test suite for the governance-badge scheme.
#
# Two halves:
#
#   1. governance_badge_test.js - hermetic behaviour tests for
#      scripts/governance-badge.js (state -> badge table, byte-equality no-op,
#      API-error classification, conflict reconciliation, orphan creation,
#      guards). It runs the helper against an in-process mock of the GitHub
#      REST API, so nothing here touches github.com or a real branch.
#
#   2. the wiring checks below - the workflow must actually call that helper,
#      must publish for skipped lanes too, must serialise publications, must
#      keep least privilege, and must not regress to inline `gh api` writes.
#      Each group is also run against a deliberately broken copy of the
#      workflow, so the checks are proven to be able to fail.
#
# Usage: bash tests/workflows/governance_badge_test.sh
# Exit: 0 pass, 1 failure, 2 setup error (no Bun and no Node).

# NB: GitHub runs a `run:` step as `bash -e`, and errexit set by the CALLER is
# not cleared by `set -uo pipefail`. This script owns its exit status through
# its own counters, so errexit is switched off explicitly; otherwise the first
# non-zero status that is not inside an `if` aborts the run with no report.
set +e
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$REPO_DIR/.github/workflows/dogfood-gate.yml"
LOCK="$REPO_DIR/.github/workflows/actions.lock"
README="$REPO_DIR/README.adoc"
HELPER="$REPO_DIR/scripts/governance-badge.js"
PAGES="$REPO_DIR/.github/workflows/pages.yml"
JS_SUITE="$REPO_DIR/tests/workflows/governance_badge_test.js"

fail=0

# --- runtime ---------------------------------------------------------------
# Bun is the estate's first-choice runtime; the helper and suite use node:
# builtins only, so Node is an acceptable fallback and keeps this runnable
# outside CI (where Bun is installed by estate-rules, verified by sha256).
RUNTIME=""
for candidate in "${GOVERNANCE_BADGE_TEST_RUNTIME:-}" bun node; do
    [[ -n "$candidate" ]] || continue
    if command -v "$candidate" >/dev/null 2>&1; then
        RUNTIME="$candidate"
        break
    fi
done
if [[ -z "$RUNTIME" ]]; then
    echo "FAIL: neither bun nor node is available to run the badge tests" >&2
    exit 2
fi

echo "=== 1. Behaviour: rendering, publication decisions, API errors ==="
echo "runtime: $RUNTIME ($("$RUNTIME" --version 2>&1 | head -1))"
echo "repo:    $REPO_DIR"
echo "shell:   $BASH_VERSION (errexit $(case $- in *e*) echo on;; *) echo off;; esac))"
if "$RUNTIME" "$JS_SUITE"; then
    echo "PASS: behaviour suite"
else
    echo "FAIL: behaviour suite" >&2
    # Workflow commands are only interpreted on stdout.  # NOSONAR
    echo "::error::governance-badge behaviour suite failed (see the FAIL lines above)"
    fail=1
fi

# --- static wiring ---------------------------------------------------------
# job_block FILE JOB -> the YAML block of a top-level job (2-space indent).
job_block() { # job_block FILE JOB
    local file="$1" name="$2"
    awk -v name="$name" '
        $0 == "  " name ":" { inside = 1 }
        inside && $0 ~ /^  [A-Za-z0-9_-]+:$/ && $0 != "  " name ":" { exit }
        inside { print }
    ' "$file"
}

WIRE_FAIL=0
wire_pass() { echo "  PASS: $1"; }
wire_fail() {
    local message="$1"
    echo "  FAIL: $message" >&2
    # Workflow commands are only interpreted on stdout, so this line cannot
    # follow the "errors go to stderr" rule.  # NOSONAR
    echo "::error::governance-badge wiring: $message"
    WIRE_FAIL=1
}

has() { # has DESC PATTERN FILE
    local desc="$1" pattern="$2" file="$3"
    if grep -Eq -- "$pattern" "$file"; then
        wire_pass "$desc"
    else
        wire_fail "$desc (no match for /$pattern/)"
    fi
}

hasnt() { # hasnt DESC PATTERN FILE
    local desc="$1" pattern="$2" file="$3"
    if grep -Eq -- "$pattern" "$file"; then
        wire_fail "$desc (unexpected match for /$pattern/)"
    else
        wire_pass "$desc"
    fi
}

# wiring_checks WORKFLOW -> 0 if every wiring rule holds, 1 otherwise.
# Kept separate from the driver so the same checks can be pointed at a mutated
# copy: an instrument that cannot fail is not an instrument.
wiring_checks() {
    local workflow="$1"
    local tmpdir badge_job download_step publish_step generate_step
    WIRE_FAIL=0
    tmpdir="$(mktemp -d)"
    badge_job="$tmpdir/badges.yml"
    download_step="$tmpdir/download.yml"
    publish_step="$tmpdir/publish.yml"
    generate_step="$tmpdir/generate.yml"

    job_block "$workflow" badges > "$badge_job"
    # The download step: from the step that uses download-artifact up to the
    # next step boundary.
    awk '/- name: Download the lane grid/ { inside = 1 }
         inside && /^      - name:/ && !/Download the lane grid/ { exit }
         inside { print }' "$badge_job" > "$download_step"
    awk '/- name: Publish badges\/k9.json/ { inside = 1 }
         inside && /^      - name:/ && !/Publish badges/ { exit }
         inside { print }' "$badge_job" > "$publish_step"
    awk '/- name: Generate K9 badge/ { inside = 1 }
         inside && /^      - name:/ && !/Generate K9 badge/ { exit }
         inside { print }' "$workflow" > "$generate_step"

    echo "  --- badges job exists and is wired to the lane ---"
    if [[ -s "$badge_job" ]]; then
        wire_pass "the badges job exists"
    else
        wire_fail "the badges job is missing"
    fi
    has "the badges job has its own steps: key (a lost key invalidates the whole workflow)" '^    steps:$' "$badge_job"
    has "the badges job needs the K9 lane" '^    needs: k9-validate$' "$badge_job"
    has "the badges job always runs, even after a failed or cancelled lane" '^    if: always\(\)' "$badge_job"
    has "the badges job only publishes from main" "github\.ref == 'refs/heads/main'" "$badge_job"
    has "the badges job only publishes on push" "github\.event_name == 'push'" "$badge_job"
    hasnt "a skipped lane is NOT excluded (it must publish grey)" "!=\s*'skipped'" "$badge_job"

    echo "  --- least privilege ---"
    if grep -Eq '^permissions:$' "$workflow" &&
        awk '/^permissions:$/ { getline; exit !($0 ~ /^  contents: read$/) }' "$workflow"; then
        wire_pass "workflow-wide permissions stay read-only"
    else
        wire_fail "workflow-wide permissions must stay 'contents: read'"
    fi
    has "the badges job needs only contents: read (it writes no branch)" '^      contents: read$' "$badge_job"
    hasnt "no job in the workflow asks for contents: write" 'contents: write' "$workflow"

    echo "  --- the lane artifact is still the evidence ---"
    local upload_step
    upload_step="$tmpdir/upload.yml"
    awk '/- name: Upload K9 grid/ { inside = 1 }
         inside && /^      - name:/ && !/Upload K9 grid/ { exit }
         inside { print }' "$workflow" > "$upload_step"
    has "the artifact is uploaded even when validation fails" '^        if: always\(\)$' "$upload_step"
    has "a missing artifact fails the upload" '^          if-no-files-found: error$' "$upload_step"
    has "the upload publishes the helper's badge.json" 'badge\.json$' "$upload_step"
    has "the download asks for the same artifact" '^          name: k9-grid$' "$download_step"

    echo "  --- the helper owns rendering and publishing ---"
    has "the lane artifact is rendered by the helper" 'governance-badge\.js render' "$generate_step"
    has "the artifact records the validation step's outcome" '\$\{\{ steps\.validate\.outcome \}\}' "$generate_step"
    has "the stager is the helper" 'governance-badge\.js stage' "$publish_step"
    hasnt "the helper's branch-write route is not used by the workflow" 'governance-badge\.js publish' "$badge_job"
    has "the staged badge is uploaded for the Pages deployment" 'name: governance-badge-site' "$badge_job"
    has "the stager is told the lane's actual result" 'needs\.k9-validate\.result' "$publish_step"
    has "the stager receives the artifact as evidence" 'ARTIFACT: \$\{\{ runner\.temp \}\}/k9-grid/badge\.json' "$publish_step"
    hasnt "no inline gh api writes remain" 'gh api' "$badge_job"
    hasnt "no inline contents PUT remains" '-X PUT' "$badge_job"
    hasnt "a publication fault must fail the step" 'continue-on-error: true' "$publish_step"
    has "a missing artifact is not fatal at download time" '^        continue-on-error: true$' "$download_step"

    echo "  --- actions stay pinned ---"
    local unpinned
    unpinned="$(grep -E '^\s+-? ?uses:' "$badge_job" | grep -Ev '@[a-f0-9]{40}( |$)' || true)"
    if [[ -z "$unpinned" ]]; then
        wire_pass "every action in the badges job is pinned to a 40-hex SHA"
    else
        wire_fail "unpinned action(s) in the badges job: $unpinned"
    fi
    local uses unlocked=0
    while IFS= read -r uses; do
        [[ -n "$uses" ]] || continue
        if ! grep -Fq "'$uses'" "$LOCK"; then
            wire_fail "action $uses is missing from actions.lock"
            unlocked=1
        fi
    done < <(grep -E '^\s+-? ?uses:' "$badge_job" | sed -E 's/^\s+-? ?uses: //; s/\s+#.*$//' | sort -u)
    if [[ "$unlocked" -eq 0 ]]; then
        wire_pass "actions.lock records the badges job's actions"
    fi

    echo "  --- the Pages deployment carries the staged badge ---"
    local pages_wf="$PAGES"
    has "pages.yml deploys after Dogfood Gate completes" 'workflows: \["Dogfood Gate"\]' "$pages_wf"
    hasnt "pages.yml has no bare push trigger (it would erase the badge)" '^  push:' "$pages_wf"
    has "pages.yml fetches the staged badge from the triggering run" 'run-id: \$\{\{ github\.event\.workflow_run\.id \}\}' "$pages_wf"
    has "pages.yml only deploys the default branch's current head (freshness gate)" 'needs\.gate\.outputs\.current == '"'"'true'"'"'' "$pages_wf"
    has "pages.yml build can read the Pages config" '^      pages: read' "$pages_wf"
    has "pages.yml adds badges/k9.json to the site" '_site/badges/k9\.json' "$pages_wf"

    echo "  --- the helper's invariants survive ---"
    # The template's README carries the tokens; a minted child's carries its
    # own owner and repo. Either is the stable raw URL.
    if bash "$(dirname "$README")/scripts/is-template-tree.sh" "$(dirname "$README")"; then
    has "README reads the stable Pages URL" 'https://(\{\{OWNER\}\}|[A-Za-z0-9_.-]+)\.github\.io/(\{\{REPO\}\}|[A-Za-z0-9_.-]+)/badges/k9\.json' "$README"
    hasnt "README no longer reads the ruleset-blocked branch" 'governance-badges/badges/k9\.json' "$README"
    else echo "  SKIP: README badge URL (not the template tree)"; fi
    has "the orphan commit is built with no parents" 'parents: \[\]' "$HELPER"
    hasnt "the helper never names a source branch as a ref" 'refs/heads/(main|master)' "$HELPER"

    rm -rf "$tmpdir"
    return "$WIRE_FAIL"
}

echo ""
echo "=== 2. Wiring: the workflow uses the helper and keeps the contract ==="
if wiring_checks "$WORKFLOW"; then
    echo "PASS: workflow wiring"
else
    echo "FAIL: workflow wiring"
    fail=1
fi

echo ""
echo "=== 3. Firing: the wiring checks fail on a broken workflow ==="
# Negative controls: each mutation breaks exactly one rule the checks above
# assert, so a check that cannot fail is caught here rather than in production.
fire_case() {
    local label="$1" mutation="$2" tmp copy
    tmp="$(mktemp -d)"
    copy="$tmp/dogfood-gate.yml"
    sed -E "$mutation" "$WORKFLOW" > "$copy"
    if cmp -s "$WORKFLOW" "$copy"; then
        echo "  FAIL: mutation had no effect: $label" >&2
        # Workflow commands are only interpreted on stdout.  # NOSONAR
        echo "::error::governance-badge firing control: mutation had no effect: $label"
        fail=1
        rm -rf "$tmp"
        return
    fi
    if wiring_checks "$copy" >/dev/null 2>&1; then
        echo "  FAIL: $label was not caught by the wiring checks" >&2
        # Workflow commands are only interpreted on stdout.  # NOSONAR
        echo "::error::governance-badge firing control: $label was not caught"
        fail=1
    else
        echo "  PASS: $label is caught"
    fi
    rm -rf "$tmp"
}

fire_case "dropping always() from the badges job" \
    "s/if: always\(\) && github\.event_name/if: github.event_name/"
fire_case "re-excluding skipped lanes" \
    "s/(github\.ref == 'refs\/heads\/main')/\\1 \&\& needs.k9-validate.result != 'skipped'/"
fire_case "losing the badges job's steps: key" \
    "/^  badges:\$/,/^  [a-z0-9-]+:\$/ s/^    steps:\$//"
fire_case "giving the badges job a branch-write permission again" \
    "s/^      contents: read\$/      contents: write/"
fire_case "failing the artifact download instead of publishing grey" \
    "s/^        continue-on-error: true$/        continue-on-error: false/"
fire_case "pointing the publisher back at inline gh api" \
    "s/bun scripts\/governance-badge\.js stage/gh api repos\/\$GITHUB_REPOSITORY\/contents\/\$DEST/"

# ---------------------------------------------------------------------------
# 4. The Pages deploy job re-checks freshness right before deploying
# ---------------------------------------------------------------------------
# pages_freshness_checks PAGES_YML -> 0 if the deploy job refuses a stale run.
# Structural checks, then the re-check step's real shell is extracted from the
# YAML and RUN against a stub `gh`: a stale run must write current=false and a
# current run current=true, and neither may fail the step.
pages_freshness_checks() {
    local pages="$1" tmp block step rc
    WIRE_FAIL=0
    tmp="$(mktemp -d)"
    block="$tmp/deploy.yml"
    job_block "$pages" deploy > "$block"
    has "the deploy job can read the default branch head" '^      contents: read' "$block"
    has "the deploy job has the re-check step" 'id: fresh' "$block"
    has "deploying is conditional on the re-check" "if: steps\\.fresh\\.outputs\\.current == 'true'" "$block"

    # Extract the re-check step's run: body (indent 12 -> 0).
    awk '/id: fresh/ { seen = 1 }
         seen && /^        run: \|$/ { grab = 1; next }
         grab && /^      - name:/ { exit }
         grab { if ($0 ~ /^          /) { sub(/^          /, ""); print } else if ($0 !~ /^$/) { exit } }' "$block" > "$tmp/step.sh"
    if [[ ! -s "$tmp/step.sh" ]]; then
        wire_fail "could not extract the re-check step's script"
        rm -rf "$tmp"; return 1
    fi

    mkdir -p "$tmp/bin"
    cat > "$tmp/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
echo "$FAKE_HEAD"
FAKE_GH
    chmod +x "$tmp/bin/gh"

    local head="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" other="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" out
    for case in current stale; do
        out="$tmp/out-$case"; : > "$out"
        local run_sha="$head"; [[ "$case" = stale ]] && run_sha="$other"
        PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=o/r GITHUB_OUTPUT="$out" FAKE_HEAD="$head" RUN_SHA="$run_sha" \
            bash "$tmp/step.sh" >/dev/null 2>&1
        rc=$?
        if [[ "$rc" -ne 0 ]]; then
            wire_fail "the re-check step failed (exit $rc) for a $case run; a superseded run must be skipped, not failed"
        elif [[ "$case" = current ]] && grep -qx 'current=true' "$out"; then
            wire_pass "a current run is allowed to deploy"
        elif [[ "$case" = stale ]] && grep -qx 'current=false' "$out"; then
            wire_pass "a superseded run is refused"
        else
            wire_fail "the re-check gave the wrong verdict for a $case run: $(cat "$out")"
        fi
    done
    rm -rf "$tmp"
    return "$WIRE_FAIL"
}

echo ""
echo "=== 4. Pages deploy: a stale run is refused right before deploying ==="
if pages_freshness_checks "$PAGES"; then
    echo "PASS: deploy freshness re-check"
else
    echo "FAIL: deploy freshness re-check"
    fail=1
fi

echo ""
echo "=== 5. Firing: the freshness checks fail on a broken pages.yml ==="
pages_fire_case() {
    local label="$1" mutation="$2" tmp copy
    tmp="$(mktemp -d)"
    copy="$tmp/pages.yml"
    sed -E "$mutation" "$PAGES" > "$copy"
    if cmp -s "$PAGES" "$copy"; then
        echo "  FAIL: mutation had no effect: $label" >&2
        echo "::error::governance-badge pages firing control: mutation had no effect: $label"
        fail=1; rm -rf "$tmp"; return
    fi
    if pages_freshness_checks "$copy" >/dev/null 2>&1; then
        echo "  FAIL: $label was not caught" >&2
        echo "::error::governance-badge pages firing control: $label was not caught"
        fail=1
    else
        echo "  PASS: $label is caught"
    fi
    rm -rf "$tmp"
}
pages_fire_case "deploying without consulting the re-check" \
    "/^      - name: Deploy to GitHub Pages/,/uses:/ s/^        if: steps\.fresh\.outputs\.current == 'true'\$/        if: always()/"
pages_fire_case "a re-check that lets a stale run through" \
    "s/^          if \[ \"\\\$head\" = \"\\\$RUN_SHA\" \]; then\$/          if true; then/"
pages_fire_case "a re-check that fails a superseded run instead of skipping it" \
    "s/not deploying its badge\.\"\$/not deploying its badge.\"; exit 1/"

echo ""
if [[ "$fail" -ne 0 ]]; then
    echo "FAIL: governance badge suite" >&2
    exit 1
fi
echo "PASS: governance badge suite (behaviour + wiring + firing controls)"
