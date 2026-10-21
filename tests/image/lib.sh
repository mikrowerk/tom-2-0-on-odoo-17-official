#!/usr/bin/env bash
# Shared helpers for the image tests (TOM-232). Sourced by the test scripts, not executed directly.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # used by the sourcing scripts
REPO_DIR="$(cd "${TESTS_DIR}/../.." && pwd)"
FAILURES=0

ok()   { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
info() { printf '%s\n' "$*"; }

# check <ok-message> <fail-message> <command...>: runs the command (e.g. test) and records the result
check() {
    local ok_msg="$1" fail_msg="$2"
    shift 2
    if "$@"; then ok "${ok_msg}"; else fail "${fail_msg}"; fi
}

# Image under test: first argument or $IMAGE
require_image() {
    IMAGE="${1:-${IMAGE:-}}"
    if [[ -z "${IMAGE}" ]]; then
        echo "usage: $(basename "$0") <image>" >&2
        exit 2
    fi
    if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
        echo "image ${IMAGE} not found locally (build or pull it first)" >&2
        exit 2
    fi
}

# Run a shell snippet inside the image without the Odoo entrypoint
in_image() {
    docker run --rm --entrypoint /bin/sh "${IMAGE}" -c "$1"
}

# Non-comment, non-empty lines of a list file
read_list() {
    grep -v -E '^[[:space:]]*(#|$)' "$1"
}

finish() {
    if (( FAILURES > 0 )); then
        info "$(basename "$0"): ${FAILURES} check(s) failed"
        exit 1
    fi
    info "$(basename "$0"): all checks passed"
}
