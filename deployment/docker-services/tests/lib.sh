#!/usr/bin/env bash
# Shared helpers for the deployment tests. Source it, do not execute it.
# shellcheck disable=SC2034  # variables are used by the sourcing scripts

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SERVICES_DIR}/../.." && pwd)"
TMP_ROOT="${TESTS_DIR}/.tmp"

FAILURES=0

fail() {
    echo "  FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

pass() {
    echo "  ok:   $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 2
}

# assert_eq <description> <expected> <actual>
assert_eq() {
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1 (expected '$2', got '$3')"
    fi
}

# finish: print the summary and exit non-zero on failures
finish() {
    if ((FAILURES > 0)); then
        echo "${FAILURES} check(s) failed" >&2
        exit 1
    fi
    echo "all checks passed"
}

# make_tmp <name>: create a fresh scratch directory below tests/.tmp and print its path
make_tmp() {
    mkdir -p "${TMP_ROOT}"
    mktemp -d "${TMP_ROOT}/$1.XXXXXX"
}

require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || die "required command not found: ${cmd}"
    done
}

# compose_json <compose-file> [env-file]: effective compose configuration as JSON
compose_json() {
    local file="$1" env_file="${2:-}"
    local args=(-f "${file}")
    [[ -n "${env_file}" ]] && args=(--env-file "${env_file}" "${args[@]}")
    docker compose "${args[@]}" config --format json
}
