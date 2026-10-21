#!/usr/bin/env bash
# T1: the pushed tag is a manifest list with linux/amd64 and linux/arm64.
#   tests/image/manifest.sh <registry-ref>
source "$(dirname "$0")/lib.sh"
ref="${1:?usage: manifest.sh <registry-ref>}"
info "T1 manifest: ${ref}"

platforms="$(docker buildx imagetools inspect --raw "${ref}" \
    | jq -r '.manifests[]? | select(.platform.os != "unknown") | "\(.platform.os)/\(.platform.architecture)"' | sort -u)"
for p in linux/amd64 linux/arm64; do
    check "platform ${p}" "platform ${p} missing (found: ${platforms:-none})" grep -qx "${p}" <<<"${platforms}"
done

finish
