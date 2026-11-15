#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# deed-template-sync.sh, carry the template's edits to template-owned clauses
# into a minted repo's deed at a template upgrade.
#
# A template upgrade keeps the child's deed, because the deed is the child's
# identity. But some clauses are the template's text, copied in at mint: the
# (ply) directory tree. When the template fixes such a clause (#356 wrapped a
# (ply) line over the 998-octet deed line limit), the fix must reach the
# child too, or the child's DEED syntax check stays red after the upgrade.
#
# Usage:
#   deed-template-sync.sh DEED BASE NEW
#
# DEED is the child's deed. BASE and NEW are the template's own deed at the
# commit the child was cut from (or last upgraded to) and at the upgrade
# target, e.g. `git -C <template> show <pin>:rsr-template-repo_chora.deed`.
#
# A three-way rule on (ply), after each deed's self-name (<name>_chora.deed)
# is renamed to the child's, as the mint renames it:
#   child == NEW   nothing to do;
#   child == BASE  replace the clause with NEW's text;
#   otherwise      the child changed the clause: it is left alone, and the
#                  script fails so that the clause is merged by hand.
# snip: (ply) only. Its one self-reference is <name>_chora.deed; a clause that
# also names the repo slug (e.g. (documents)) needs repo-init's full
# self-name pass before it can be added here.
#
# Exit: 0 (ply) is in step; 1 (ply) needs a hand merge or is absent;
# 2 usage error, unreadable deed, or a deed without :canonical-name.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ $# -eq 3 ] || { sed -n '14,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
deed="$1"; base="$2"; new="$3"; clause=ply
# name DEED: its :canonical-name, or exit 2 naming the deed.
name() {
    [ -r "$1" ] || { echo "deed-template-sync: no readable deed: '$1'" >&2; exit 2; }
    bash "$here/deed-field.sh" "$1" "" canonical-name \
        || { echo "deed-template-sync: $1 has no :canonical-name" >&2; exit 2; }
}
child_name="$(name "$deed")"; base_name="$(name "$base")"; new_name="$(name "$new")"

# get prints the clause with its leading comments; the rename is literal.
mine="$(bash "$here/deed-clause.sh" get "$deed" "$clause")" \
    || { echo "deed-template-sync: ($clause) is absent from $deed" >&2; exit 1; }
old="$(bash "$here/deed-clause.sh" get "$base" "$clause")" || old=""
upd="$(bash "$here/deed-clause.sh" get "$new" "$clause")" \
    || { echo "deed-template-sync: ($clause) is absent from the template deed $new" >&2; exit 1; }
old="${old//"${base_name}_chora.deed"/"${child_name}_chora.deed"}"
upd="${upd//"${new_name}_chora.deed"/"${child_name}_chora.deed"}"
if [ "$mine" = "$upd" ]; then
    echo "deed-template-sync: ($clause) already matches the template"
elif [ -n "$old" ] && [ "$mine" = "$old" ]; then
    printf '%s' "$upd" | bash "$here/deed-clause.sh" replace "$deed" "$clause" -
    echo "deed-template-sync: ($clause) updated to the template's text"
else
    echo "deed-template-sync: ($clause) differs from the template at both commits; merge it by hand" >&2
    exit 1
fi
