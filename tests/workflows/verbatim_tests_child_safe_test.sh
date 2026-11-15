#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# A test carried into every child (.machine_readable/mint-verbatim.txt) must not
# die on a path the mint removes. The mint deletes archetypes/, build/templates
# and build/docs-seed, so a carried test that reads one of them fails in every
# minted repository, a red build for a test about the parent. This was
# tests/workflows/julia_library_test.sh (Codex review on bactrian#28, #29); its
# siblings under tests/e2e/ already skip loudly when archetypes/ is absent.
#
# Guard: copy the working tree, delete what the mint deletes, run every
# verbatim-listed test that names a removed path, and refuse a run whose output
# shows the missing-fixture signature ("can't read", "No such file or
# directory"). A test that fails for another reason, such as a missing tool, is
# not this defect and is not judged here.
# Controls: an unguarded test that reads archetypes/ is refused; the same test
# behind a skip is accepted.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REMOVED_RE='archetypes/|build/docs-seed|build/templates'

# child_copy SRC DEST — a git work tree of SRC with the mint's removals applied.
child_copy() {
    local src="$1" dest="$2"
    mkdir -p "$dest"
    (cd "$src" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf -) | tar -x -C "$dest"
    rm -rf "$dest/archetypes" "$dest/build/docs-seed" "$dest/build/templates"
    git -C "$dest" init -q .
}

# defect DEST TESTFILE — 0 when running the test in DEST shows the signature.
defect() {
    local out
    out="$(cd "$1" && timeout 300 bash "$2" 2>&1 || true)"
    grep -qE "can't read|No such file or directory" <<<"$out"
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Control fixtures first: the check must be able to fail.
child_copy "$ROOT" "$TMP/ctl"
mkdir -p "$TMP/ctl/tests"
cat >"$TMP/ctl/tests/unguarded.sh" <<'T'
#!/usr/bin/env bash
repo=$(git rev-parse --show-toplevel)
sed -n 1p "$repo/archetypes/julia-library/overlay/Project.toml.in"
T
cat >"$TMP/ctl/tests/guarded.sh" <<'T'
#!/usr/bin/env bash
repo=$(git rev-parse --show-toplevel)
[ -d "$repo/archetypes" ] || { echo "SKIP: minted"; exit 0; }
sed -n 1p "$repo/archetypes/julia-library/overlay/Project.toml.in"
T
defect "$TMP/ctl" tests/unguarded.sh || { echo "FAIL: an unguarded read of archetypes/ was not detected" >&2; exit 1; }
if defect "$TMP/ctl" tests/guarded.sh; then echo "FAIL: a guarded test was flagged" >&2; exit 1; fi

child_copy "$ROOT" "$TMP/child"
bad=0 checked=0
while IFS= read -r f; do
    [[ -f "$ROOT/$f" ]] || continue
    grep -qE "$REMOVED_RE" "$ROOT/$f" || continue
    checked=$((checked + 1))
    if defect "$TMP/child" "$f"; then
        echo "FAIL: $f is carried verbatim but dies on a path the mint removes" >&2; bad=1
    fi
done < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$ROOT/.machine_readable/mint-verbatim.txt" | grep -E '^tests/.*\.sh$')
[[ "$bad" -eq 0 ]] || exit 1
echo "PASS: $checked carried tests that name a removed path survive a child tree (2 controls)"
