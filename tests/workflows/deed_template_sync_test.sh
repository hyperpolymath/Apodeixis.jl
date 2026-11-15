#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# deed_template_sync_test.sh: controls for scripts/deed-template-sync.sh, which
# carries a template fix to a template-owned clause into a child's deed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$here/scripts/deed-template-sync.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

# deed NAME PLY-BODY > file: a minimal deed whose (ply) holds PLY-BODY.
deed() {
  printf '(repo-deed\n  :canonical-name "%s"\n  (ply\n    %s)\n  (status :phase "active"))\n' "$1" "$2"
}
deed old '(directory :id "a" :path "old_chora.deed" :description "one long line")' > "$scratch/base"
deed tpl '(directory :id "a" :path "tpl_chora.deed"
      :description "wrapped")' > "$scratch/new"

# 1. A child whose clause is the old template text takes the new text, renamed;
# the template itself was renamed (old -> tpl) between BASE and NEW.
deed kid '(directory :id "a" :path "kid_chora.deed" :description "one long line")' > "$scratch/kid"
bash "$T" "$scratch/kid" "$scratch/base" "$scratch/new" >/dev/null
[ "$(cat "$scratch/kid")" = "$(deed kid '(directory :id "a" :path "kid_chora.deed"
      :description "wrapped")')" ] && ok "unchanged clause takes the template fix" || bad "clause not updated: $(cat "$scratch/kid")"

# 2. A second run is a no-op.
before=$(sha256sum < "$scratch/kid")
bash "$T" "$scratch/kid" "$scratch/base" "$scratch/new" >/dev/null
[ "$(sha256sum < "$scratch/kid")" = "$before" ] && ok "second run changes nothing" || bad "second run changed the deed"

# 3. A clause the child edited is left alone and the run fails.
deed kid '(directory :id "a" :path "kid_chora.deed" :description "my own")' > "$scratch/own"
before=$(sha256sum < "$scratch/own")
rc=0; bash "$T" "$scratch/own" "$scratch/base" "$scratch/new" 2>/dev/null >/dev/null || rc=$?
[ "$rc" -eq 1 ] && [ "$(sha256sum < "$scratch/own")" = "$before" ] && ok "edited clause: rc=1, deed untouched" || bad "edited clause: rc=$rc or deed changed"

# 4. A deed without :canonical-name is a setup error (rc=2), not a merge conflict.
printf '(repo-deed\n  (ply\n    (directory :id "a")))\n' > "$scratch/noname"
rc=0; bash "$T" "$scratch/noname" "$scratch/base" "$scratch/new" 2>/dev/null >/dev/null || rc=$?
[ "$rc" -eq 2 ] && ok "missing :canonical-name: rc=2" || bad "missing :canonical-name: rc=$rc"

[ "$fails" -eq 0 ] || { echo "$fails control(s) failed"; exit 1; }
echo "all deed-template-sync controls hold"
