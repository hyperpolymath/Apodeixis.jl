#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-identity.sh DEED — the identity literals of a repo deed (standards A1
# v0.4.5 7.1 and T30, owner ruling Q2 of 2026-11-14; A7 S2, rollout 1c, YP04).
#
#   :repo-uuid        required. #uuid"<lowercase RFC 9562 id>" of version 8, or
#                     the computed form #u8"domain:name".
#   :beholding-chora  optional. The same forms.
#
# A version 5 id inside #uuid is v5-identity, and a #u5"…" literal is
# u5-identity. Both are errors in every mode, lax included: there is no
# warning tier. Prints one line per finding on stderr and exits 1 if there is any,
# 2 on a usage error or an unreadable deed, 0 otherwise.
set -uo pipefail

[[ $# -eq 1 && -n "$1" ]] || { echo "usage: check-identity.sh DEED" >&2; exit 2; }
DEED="$1"
[[ -f "$DEED" ]] || { echo "check-identity.sh: no such deed: $DEED" >&2; exit 2; }
READ="$(dirname "${BASH_SOURCE[0]}")/deed-field.sh"

bad=0
# check FIELD REQUIRED
check() {
  local field="$1" required="$2" lit rc=0
  lit="$(bash "$READ" --typed "$DEED" '' "$field")" || rc=$?
  [[ "$rc" -le 1 ]] || { echo "check-identity.sh: cannot read :$field from $DEED" >&2; exit 2; }
  if [[ -z "$lit" ]]; then
    [[ "$required" = 1 ]] && { echo "$DEED: :$field is missing" >&2; bad=1; }
    return
  fi
  case "$lit" in
    '#uuid"'*'"')
      if ! printf '%s' "$lit" | grep -Eq '^#uuid"[0-9a-f]{8}-[0-9a-f]{4}-[58][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"$'; then
        echo "$DEED: :$field $lit is not a lowercase version 5 or 8 RFC 9562 id" >&2; bad=1
      elif printf '%s' "$lit" | grep -Eq '^#uuid"[0-9a-f]{8}-[0-9a-f]{4}-5'; then
        echo "$DEED: :$field $lit is v5-identity: a version 5 id is an error in every mode; the chora id is #uuid\"<v8 id of the birth path>\" (A1 T30, Q2)" >&2; bad=1
      fi ;;
    '#u8"'?*:?*'"') ;;
    '#u5"'*)
      echo "$DEED: :$field $lit is u5-identity: a #u5 literal is an error in every mode; write #uuid\"<v8 id>\" or #u8\"domain:name\" (A1 T30, Q2)" >&2; bad=1 ;;
    *)
      echo "$DEED: :$field $lit is not a #uuid or #u8 literal" >&2; bad=1 ;;
  esac
}

check repo-uuid 1
check beholding-chora 0
exit "$bad"
