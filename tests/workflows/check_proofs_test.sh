#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check_proofs_test.sh — positive and negative controls for scripts/check-proofs.sh.
#
# The gate shells out to a real prover. These controls put a FAKE prover first on
# PATH, so they test the gate's own verdict logic (manifest coverage, quarantine,
# toolchain absence, escape hatches, exit-0-with-an-error) and not the prover.
# This is a test of the gate, not a proof that any proof checks. Nothing here
# runs idris2, lean, agda or coqc.
#
# The fake treats a source file as a compile failure when it contains the word
# BROKEN, prints an `error:` line but exits 0 when it contains SILENTERR, and
# otherwise exits 0 quietly.
#
# Exit: 0 all controls hold; 1 a control failed.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A PATH with the shell tools the gate needs and NO prover; fakes are added per case.
BASEBIN="$WORK/basebin"; mkdir -p "$BASEBIN"
for t in bash sed grep find sort comm mktemp cat head dirname basename rm tr cut wc awk env; do
    p="$(command -v "$t" 2>/dev/null || true)"
    [ -n "$p" ] && ln -s "$p" "$BASEBIN/$t"
done
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
for t in coqc lean agda; do
    cat >"$FAKEBIN/$t" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "fake 0"; exit 0; fi
f="${@: -1}"
if grep -q BROKEN "$f" 2>/dev/null; then echo "error: fake compile failure in $f"; exit 1; fi
if grep -q SILENTERR "$f" 2>/dev/null; then echo "error: fake reports an error but exits 0"; exit 0; fi
exit 0
FAKE
    chmod +x "$FAKEBIN/$t"
done

FAILED=0; CHECKS=0
# fixture NAME — a throwaway repo root holding only the gate and its scanner.
fixture() {
    local d="$WORK/$1"; mkdir -p "$d/scripts" "$d/verification/proofs/coq"
    cp "$REPO_DIR/scripts/check-proofs.sh" "$REPO_DIR/scripts/scan-dangerous.sh" "$d/scripts/"
    echo "$d"
}
# run LABEL WANT_RC DIR PROVER WITH_FAKES PATTERN
run() {
    local label="$1" want="$2" dir="$3" prover="$4" fakes="$5" pat="${6:-}" rc=0 out p
    p="$BASEBIN"; [ "$fakes" = yes ] && p="$FAKEBIN:$BASEBIN"
    out="$(PATH="$p" bash "$dir/scripts/check-proofs.sh" $prover 2>&1)" || rc=$?
    CHECKS=$((CHECKS + 1))
    if [ "$rc" -ne "$want" ]; then
        FAILED=$((FAILED + 1)); echo "  FAIL  $label (want rc=$want, got rc=$rc)"; sed 's/^/        /' <<<"$out" | tail -12
    elif [ -n "$pat" ] && ! grep -qF -- "$pat" <<<"$out"; then
        FAILED=$((FAILED + 1)); echo "  FAIL  $label (rc ok, output lacks: $pat)"; sed 's/^/        /' <<<"$out" | tail -12
    else
        echo "  PASS  $label"
    fi
}

# --- positive controls ---------------------------------------------------------
d="$(fixture ok)"; echo 'Lemma a : True. Proof. exact I. Qed.' >"$d/verification/proofs/coq/a.v"
echo 'verification/proofs/coq|a.v|gated|' >"$d/verification/proofs/coq/MANIFEST"
run "a gated module that compiles passes" 0 "$d" coq yes "RESULT: PASS"

d="$(fixture quar)"; echo 'BROKEN' >"$d/verification/proofs/coq/b.v"
echo 'verification/proofs/coq|b.v|quarantine| known broken' >"$d/verification/proofs/coq/MANIFEST"
run "a quarantined module that still fails passes" 0 "$d" coq yes "expected"

d="$(fixture none)"
run "no proofs and no MANIFEST passes" 0 "$d" coq yes "nothing to check"

# --- negative controls ---------------------------------------------------------
d="$(fixture notool)"; echo 'x' >"$d/verification/proofs/coq/a.v"
echo 'verification/proofs/coq|a.v|gated|' >"$d/verification/proofs/coq/MANIFEST"
run "a missing toolchain FAILS, it does not skip" 1 "$d" coq no "not found on PATH"

d="$(fixture gatedbad)"; echo 'BROKEN' >"$d/verification/proofs/coq/a.v"
echo 'verification/proofs/coq|a.v|gated|' >"$d/verification/proofs/coq/MANIFEST"
run "a gated module that does not compile fails" 1 "$d" coq yes "RESULT: FAIL"

d="$(fixture quarok)"; echo 'fine' >"$d/verification/proofs/coq/b.v"
echo 'verification/proofs/coq|b.v|quarantine| was broken' >"$d/verification/proofs/coq/MANIFEST"
run "a quarantined module that now compiles fails" 1 "$d" coq yes "UNEXPECTED"

d="$(fixture unlisted)"; echo 'fine' >"$d/verification/proofs/coq/a.v"; echo 'fine' >"$d/verification/proofs/coq/new.v"
echo 'verification/proofs/coq|a.v|gated|' >"$d/verification/proofs/coq/MANIFEST"
run "a proof on disk absent from the MANIFEST fails" 1 "$d" coq yes "absent from"

d="$(fixture stale)"; echo 'fine' >"$d/verification/proofs/coq/a.v"
printf 'verification/proofs/coq|a.v|gated|\nverification/proofs/coq|gone.v|gated|\n' >"$d/verification/proofs/coq/MANIFEST"
run "a MANIFEST entry for a missing file fails" 1 "$d" coq yes "stale entries"

d="$(fixture nomanifest)"; echo 'fine' >"$d/verification/proofs/coq/a.v"
run "proofs with no MANIFEST fail" 1 "$d" coq yes "has no MANIFEST"

d="$(fixture badstatus)"; echo 'fine' >"$d/verification/proofs/coq/a.v"
echo 'verification/proofs/coq|a.v|maybe|' >"$d/verification/proofs/coq/MANIFEST"
run "an unknown status fails" 1 "$d" coq yes "neither 'gated' nor 'quarantine'"

d="$(fixture notsource)"; echo 'text' >"$d/verification/proofs/coq/README.adoc"
echo 'verification/proofs/coq|README.adoc|quarantine| pretend' >"$d/verification/proofs/coq/MANIFEST"
run "a quarantined non-source file cannot pass as a proof" 1 "$d" coq yes "not a .v proof source"

d="$(fixture exit0err)"; echo 'SILENTERR' >"$d/verification/proofs/coq/a.v"; mkdir -p "$d/verification/proofs/lean4"
echo 'SILENTERR' >"$d/verification/proofs/lean4/a.lean"
echo 'verification/proofs/lean4|a.lean|gated|' >"$d/verification/proofs/lean4/MANIFEST"
run "lean4: exit 0 with an error line fails" 1 "$d" lean4 yes "RESULT: FAIL"

d="$(fixture hatch)"; printf 'Lemma a : True. Proof. Admitted.\n' >"$d/verification/proofs/coq/a.v"
echo 'verification/proofs/coq|a.v|gated|' >"$d/verification/proofs/coq/MANIFEST"
run "a module that compiles but uses Admitted fails" 1 "$d" coq yes "RESULT: FAIL"

d="$(fixture usage)"
run "an unknown prover is a usage error (rc 2)" 2 "$d" nonsense yes "usage:"

echo "$CHECKS controls, $FAILED failed"
[ "$FAILED" -eq 0 ]
