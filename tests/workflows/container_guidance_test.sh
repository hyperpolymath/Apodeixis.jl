#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# The base-image guidance must agree with the gate that enforces it.
# scripts/check-container-pins.sh rejects a tag with no digest (`:latest` and
# version tags included). It accepts `@sha256:<digest>` and also a tag followed by
# a digest; this guidance asks for the digest alone, because the tag adds nothing. Guidance that tells a
# reader or an assistant to use `:latest` therefore sends every child to a red
# gate (seen as a CodeRabbit finding on two downstream pull requests).
#
# A guidance line that names a wolfi-base or static image (bare, `:latest` or a
# version tag) must also say it is pinned by digest. Controls run on a fixture first: the old
# wording must FAIL and the new wording must PASS, so the check cannot go green
# by matching nothing.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Words that mark an image reference as an example to AVOID. Only the text
# directly before the token counts, so "use X:latest, do not pin" is not excused.
PROHIBIT_BEFORE='(do not use|don'"'"'t use|never use|must not use|avoid|instead of|rather than)[[:space:]]*[`"'"'"']?$'

# stale_lines FILE... — print "file:line:text" for each floating reference.
# Each image token is judged on its own, not by the words around it:
#   * a token written as a prohibited example ("do not use X:latest") is skipped;
#   * a token with a digest is accepted only when the digest is well formed:
#     exactly 64 lowercase hex characters (what check-container-pins.sh requires)
#     or the documentation placeholder <digest>;
#   * a token with a tag and no @sha256: digest is flagged whatever the line says
#     (`wolfi-base:latest` stays flagged even beside the words "pin by digest");
#   * a bare token is accepted only when its line, or the next line of the same
#     paragraph (wrapped prose), also says it is pinned by digest.
stale_lines() {
    local f entry n line next tok suffix prefix
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        while IFS= read -r entry; do
            n="${entry%%:*}"; line="${entry#*:}"
            next="$(sed -n "$((n + 1))p" "$f")"
            while IFS= read -r tok; do
                [[ -n "$tok" ]] || continue
                prefix="${line%%"$tok"*}"
                if grep -qiE "$PROHIBIT_BEFORE" <<<"$prefix"; then
                    continue
                elif [[ "$tok" == *@sha256:* ]]; then
                    suffix="${tok##*@sha256:}"
                    if [[ "$suffix" != '<digest>' && ! "$suffix" =~ ^[0-9a-f]{64}$ ]]; then
                        echo "$f:$line"; break
                    fi
                elif [[ "$tok" == *:* ]]; then
                    echo "$f:$line"; break
                elif ! grep -qiE 'sha256|digest' <<<"$line" && ! grep -qiE 'sha256|digest' <<<"$next"; then
                    echo "$f:$line"; break
                fi
            done < <(grep -oE 'cgr\.dev/chainguard/(wolfi-base|static)[^[:space:]`"'"'"')]*' <<<"$line" || true)
        done < <(grep -nE 'cgr\.dev/chainguard/(wolfi-base|static)' "$f" || true)
    done
}

zeros=0000000000000000000000000000000000000000000000000000000000000000
low=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '%s\n' '- Base image: `cgr.dev/chainguard/wolfi-base:latest`.' > "$scratch/old.md"
printf '%s\n' '- Base image: `cgr.dev/chainguard/wolfi-base`, pinned by digest (`@sha256:<digest>`).' > "$scratch/new.md"
[[ -n "$(stale_lines "$scratch/old.md")" ]] || fail 'control: the old wording was not flagged'
printf '%s\n' '- Base image: `cgr.dev/chainguard/wolfi-base`.' > "$scratch/bare.md"
printf '%s\n' '- Base image: `cgr.dev/chainguard/wolfi-base:2026.11.14`.' > "$scratch/ver.md"
printf '%s\n' '- Runtime: `cgr.dev/chainguard/static:latest`.' > "$scratch/static.md"
[[ -n "$(stale_lines "$scratch/bare.md")" ]] || fail 'control: a bare reference was not flagged'
[[ -n "$(stale_lines "$scratch/ver.md")" ]] || fail 'control: a version-tagged reference was not flagged'
[[ -n "$(stale_lines "$scratch/static.md")" ]] || fail 'control: a static:latest reference was not flagged'
printf '%s\n' '- Base image: `cgr.dev/chainguard/wolfi-base:latest`; pin by digest with scripts/pin-container-digests.sh (sha256).' > "$scratch/mixed.md"
[[ -n "$(stale_lines "$scratch/mixed.md")" ]] || fail 'control: a floating tag beside digest wording was not flagged'
printf '%s\n' "- Base image: \`cgr.dev/chainguard/wolfi-base:latest@sha256:$zeros\`." > "$scratch/tagdigest.md"
[[ -z "$(stale_lines "$scratch/tagdigest.md")" ]] || fail 'control: a tag plus digest was flagged'
[[ -z "$(stale_lines "$scratch/new.md")" ]] || fail 'control: the new wording was flagged'
# Malformed digests are refused: short, uppercase, empty.
printf '%s\n' '- Base image: `cgr.dev/chainguard/wolfi-base@sha256:deadbeef`.' > "$scratch/short.md"
printf '%s\n' "- Base image: \`cgr.dev/chainguard/wolfi-base@sha256:${low^^}\`." > "$scratch/upper.md"
printf '%s\n' '- Base image: `cgr.dev/chainguard/wolfi-base@sha256:`.' > "$scratch/empty.md"
[[ -n "$(stale_lines "$scratch/short.md")" ]] || fail 'control: a short digest was not flagged'
[[ -n "$(stale_lines "$scratch/upper.md")" ]] || fail 'control: an uppercase digest was not flagged'
[[ -n "$(stale_lines "$scratch/empty.md")" ]] || fail 'control: an empty digest was not flagged'
printf '%s\n' "- Base image: \`cgr.dev/chainguard/wolfi-base@sha256:$low\`." > "$scratch/good.md"
[[ -z "$(stale_lines "$scratch/good.md")" ]] || fail 'control: a well-formed digest was flagged'
# Wrapped prose: the pinning words on the next line count; unrelated next lines do not.
printf '%s\n' '- Base image: `cgr.dev/chainguard/wolfi-base`' '  pinned by digest.' > "$scratch/wrap.md"
printf '%s\n' '- Base image: `cgr.dev/chainguard/wolfi-base`' '  is small.' > "$scratch/nowrap.md"
[[ -z "$(stale_lines "$scratch/wrap.md")" ]] || fail 'control: a wrapped digest requirement was flagged'
[[ -n "$(stale_lines "$scratch/nowrap.md")" ]] || fail 'control: an unpinned bare reference with an unrelated next line was not flagged'
# Examples to avoid: accepted only when the prohibition comes before the token.
printf '%s\n' '- Do not use `cgr.dev/chainguard/wolfi-base:latest`; pin by digest.' > "$scratch/avoid.md"
printf '%s\n' '- Use `cgr.dev/chainguard/wolfi-base:latest`, do not pin it.' > "$scratch/afterwards.md"
[[ -z "$(stale_lines "$scratch/avoid.md")" ]] || fail 'control: a prohibited example was flagged'
[[ -n "$(stale_lines "$scratch/afterwards.md")" ]] || fail 'control: a prohibition after the token excused a floating reference'
echo 'PASS: controls (old wording flagged, new wording accepted, 15 controls)'

files=(
    "$repo/.clinerules"
    "$repo/.github/copilot-instructions.md"
    "$repo/build/container/README.adoc"
    "$repo/docs/practice/AI-CONVENTIONS.adoc"
)
found=$(stale_lines "${files[@]}")
if [[ -n "$found" ]]; then
    printf '%s\n' "$found" >&2
    fail 'base-image guidance recommends a floating reference without a digest pin'
fi
echo 'PASS: base-image guidance says digest-pinned'
