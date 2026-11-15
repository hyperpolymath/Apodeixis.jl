#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# docs/status/TEST-NEEDS.adoc names the template in its title. It was listed in
# .machine_readable/mint-verbatim.txt only because one prose line quoted a
# lowercase brace token, and a verbatim file skips every rewrite pass, the
# self-name pass included, so a minted child kept "= TEST-NEEDS:
# rsr-template-repo" (Codex review on atoma#14). The line is reworded, so the
# document is minted like any other and the child's title carries its own name.
#
# Guard, in three parts:
#   1. TEST-NEEDS.adoc is not in the verbatim list;
#   2. it carries no brace token, which is what forced the listing;
#   3. the recipe's own self-name program turns its title into the child's name
#      and leaves no template name behind.
# Controls: a re-added token, a re-added verbatim entry and a no-op rewrite are
# each refused.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="${1:-$ROOT/docs/status/TEST-NEEDS.adoc}"
LIST="${2:-$ROOT/.machine_readable/mint-verbatim.txt}"
recipe="$ROOT/build/just/repo-init.just"

prov=$(grep -m1 -E "^ +SELF_PROV='" "$recipe") || { echo "FAIL: no SELF_PROV line in $recipe" >&2; exit 1; }
prog=$(grep -m1 -E '^ +SELF_NAME_SED="' "$recipe") || { echo "FAIL: no SELF_NAME_SED line in $recipe" >&2; exit 1; }
rule_script=$(mktemp)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$rule_script"' EXIT
printf '%s\n%s\n' "$prov" "$prog" > "$rule_script"
# shellcheck disable=SC2034  # read by the sourced recipe lines
TEMPLATE_OWNER=hyperpolymath TEMPLATE_REPO=rsr-template-repo
# shellcheck disable=SC2034
TEMPLATE_SLUG="${TEMPLATE_OWNER}/${TEMPLATE_REPO}"
# shellcheck disable=SC2034
OWNER=example-owner REPO=mint-check
# shellcheck disable=SC1090
. "$rule_script"

# verdict DOC LIST MODE — MODE is "sed" (the recipe program) or "none".
verdict() {
    local doc="$1" list="$2" mode="$3" after
    if sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$list" | grep -qxF 'docs/status/TEST-NEEDS.adoc'; then
        echo "TEST-NEEDS.adoc is listed verbatim, so the self-name pass skips it"; return 1
    fi
    if grep -qE '\{\{[A-Za-z_][A-Za-z0-9_]*\}\}' "$doc"; then
        echo "TEST-NEEDS.adoc carries a brace token again"; return 1
    fi
    if [ "$mode" = sed ]; then after="$(sed -E "$SELF_NAME_SED" "$doc")"; else after="$(cat "$doc")"; fi
    grep -qxF '= TEST-NEEDS: mint-check' <<<"$after" || { echo "the title does not become the child's name"; return 1; }
    ! grep -qF 'rsr-template-repo' <<<"$after" || { echo "the template name survives the rewrite"; return 1; }
    return 0
}

if ! msg="$(verdict "$DOC" "$LIST" sed)"; then echo "FAIL: $msg" >&2; exit 1; fi

# Control 1: a brace token in prose is refused.
{ cat "$DOC"; printf 'Converted from `%s` placeholders\n' '{{project}}'; } > "$TMP/token.adoc"
if verdict "$TMP/token.adoc" "$LIST" sed >/dev/null 2>&1; then echo "FAIL: a brace token was accepted" >&2; exit 1; fi

# Control 2: listing the file verbatim again is refused.
{ cat "$LIST"; echo 'docs/status/TEST-NEEDS.adoc   # prose'; } > "$TMP/list.txt"
if verdict "$DOC" "$TMP/list.txt" sed >/dev/null 2>&1; then echo "FAIL: a verbatim entry was accepted" >&2; exit 1; fi

# Control 3: a rewrite that changes nothing (what verbatim does) is refused.
if verdict "$DOC" "$LIST" none >/dev/null 2>&1; then echo "FAIL: an unrewritten title was accepted" >&2; exit 1; fi

echo "PASS: TEST-NEEDS.adoc is minted, not carried verbatim (3 controls)"
