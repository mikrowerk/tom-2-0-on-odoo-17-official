#!/usr/bin/env bash
# Mirrors the official multi-arch Odoo 17 image to ghcr.io as a frozen base for the TOM build (TOM-232).
#
#   scripts/mirror-odoo-base.sh [--date YYYYMMDD] [--dry-run]
#
# Without --date the dated tag 17.0-YYYYMMDD that docker.io/library/odoo:17.0 currently points to is used
# (same index digest). The manifest list is copied registry to registry with `docker buildx imagetools create`,
# so all platform manifests keep their digests. An existing target tag is never overwritten: the script
# reports it and exits 0. Needs docker buildx, curl and jq, and `docker login ghcr.io` with write:packages.
#
# MIRROR_TARGET_REPO overrides the target repository (default ghcr.io/mikrowerk/odoo-17-official-multiarch),
# e.g. for a test against a local registry.
set -euo pipefail

UPSTREAM_REPO="docker.io/library/odoo"
UPSTREAM_SERIES="17.0"
TARGET_REPO="${MIRROR_TARGET_REPO:-ghcr.io/mikrowerk/odoo-17-official-multiarch}"
SOURCE_URL="https://github.com/mikrowerk/tom-2-0-on-odoo-17-official"
HUB_TAGS_URL="https://hub.docker.com/v2/namespaces/library/repositories/odoo/tags"

date=""
dry_run=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --date) date="${2:-}"; shift 2 ;;
        --date=*) date="${1#--date=}"; shift ;;
        --dry-run) dry_run=true; shift ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
summary() {
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$*" >>"${GITHUB_STEP_SUMMARY}"; fi
}

# Index digest of a reference; empty when it does not exist. Other errors (auth, network) abort, so that
# a failing lookup is never mistaken for a missing tag.
index_digest() {
    local ref="$1" out
    if out="$(docker buildx imagetools inspect "${ref}" --format '{{json .Manifest}}' 2>&1)"; then
        jq -r '.digest' <<<"${out}"
    elif grep -qiE 'not found|manifest unknown|name unknown' <<<"${out}"; then
        echo ""
    else
        die "cannot inspect ${ref}: ${out}"
    fi
}

# Sorted "digest platform" lines of all manifests in an index (platform images and attestations)
manifest_digests() {
    docker buildx imagetools inspect --raw "$1" \
        | jq -r '.manifests[] | "\(.digest) \(.platform.os)/\(.platform.architecture)"' | sort
}

if [[ -n "${date}" ]]; then
    [[ "${date}" =~ ^[0-9]{8}$ ]] || die "--date must be YYYYMMDD, got '${date}'"
    upstream_tag="${UPSTREAM_SERIES}-${date}"
    upstream_digest="$(index_digest "${UPSTREAM_REPO}:${upstream_tag}")"
    [[ -n "${upstream_digest}" ]] || die "${UPSTREAM_REPO}:${upstream_tag} does not exist"
else
    upstream_digest="$(index_digest "${UPSTREAM_REPO}:${UPSTREAM_SERIES}")"
    [[ -n "${upstream_digest}" ]] || die "${UPSTREAM_REPO}:${UPSTREAM_SERIES} does not exist"
    upstream_tag="$(curl -fsSL "${HUB_TAGS_URL}?name=${UPSTREAM_SERIES}-&page_size=100&ordering=last_updated" \
        | jq -r --arg d "${upstream_digest}" --arg s "${UPSTREAM_SERIES}" \
            '[.results[] | select(.digest == $d and (.name | test("^" + ($s | gsub("\\."; "\\.")) + "-[0-9]{8}$")))][0].name // empty')"
    [[ -n "${upstream_tag}" ]] \
        || die "no dated tag ${UPSTREAM_SERIES}-YYYYMMDD has the digest of ${UPSTREAM_SERIES} (${upstream_digest}) yet"
    date="${upstream_tag#"${UPSTREAM_SERIES}"-}"
fi

source_ref="${UPSTREAM_REPO}:${upstream_tag}"
target_ref="${TARGET_REPO}:${date}"
log "upstream: ${source_ref} (index ${upstream_digest})"
log "target:   ${target_ref}"
summary "### Odoo base image mirror" "" "- upstream: \`${source_ref}\` (index \`${upstream_digest}\`)" "- target: \`${target_ref}\`"

target_digest="$(index_digest "${target_ref}")"
if [[ -n "${target_digest}" ]]; then
    log "skipped: ${target_ref} already exists (index ${target_digest}); mirrored tags are never overwritten"
    summary "- skipped: target exists (index \`${target_digest}\`), never overwritten"
    exit 0
fi

create=(docker buildx imagetools create --tag "${target_ref}"
        --annotation "index:org.opencontainers.image.source=${SOURCE_URL}"
        --annotation "index:org.opencontainers.image.base.name=${source_ref}"
        --annotation "index:org.opencontainers.image.base.digest=${upstream_digest}"
        "${source_ref}@${upstream_digest}")
if ${dry_run}; then
    log "dry run, would run: ${create[*]}"
    summary "- dry run, nothing pushed"
    exit 0
fi

"${create[@]}"

# The annotations change the index digest; the platform manifests must be identical to upstream
new_digest="$(index_digest "${target_ref}")"
[[ -n "${new_digest}" ]] || die "${target_ref} not found after the push"
if ! diff <(manifest_digests "${source_ref}@${upstream_digest}") <(manifest_digests "${target_ref}") >&2; then
    die "manifests of ${target_ref} differ from ${source_ref}"
fi
for p in linux/amd64 linux/arm64; do
    manifest_digests "${target_ref}" | grep -q " ${p}$" || die "${target_ref} has no ${p} manifest"
done
log "mirrored: ${target_ref} (index ${new_digest}), platform manifests identical to upstream"
manifest_digests "${target_ref}" | sed 's/^/  /'
summary "- mirrored: index \`${new_digest}\`, platform manifests identical to upstream"
