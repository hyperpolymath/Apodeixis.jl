#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# proof-claims-rows.sh FILE — print the rows of the "== Claims" table of a
# PROOF-STATUS.adoc, header row excluded. `just proof-status` uses it.
#
# PROOF-STATUS.adoc has no overall total (a total is a percentage, and the
# policy reports a census with its denominator, not a percentage), so the old
# recipe, which grepped for a Total row, printed "No summary row" everywhere.
#
# Rows are read only between the |=== delimiters of the Claims table, with or
# without a space after the first pipe.
#
# Exit: 0 rows printed (a "No claims yet" row counts, it is the honest empty
#       state); 1 the file has no "== Claims" section or no table in it; 2 usage.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $(basename "$0") PROOF-STATUS.adoc" >&2; exit 2; }
[ -f "$1" ] || { echo "proof-claims-rows: no such file: $1" >&2; exit 2; }
rows="$(awk '
  /^== /        { in_claims = ($0 == "== Claims"); in_table = 0; next }
  in_claims && /^\|===[[:space:]]*$/ { in_table = !in_table; next }
  in_table && /^\|/ { if ($0 ~ /^\|[[:space:]]*ID[[:space:]]/) next; print }
' "$1")"
if [ -z "$rows" ]; then
  echo "proof-claims-rows: $1 has no rows in a '== Claims' table" >&2
  exit 1
fi
printf '%s\n' "$rows"
