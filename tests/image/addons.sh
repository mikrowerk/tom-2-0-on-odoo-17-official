#!/usr/bin/env bash
# T3: add-on inventory. The modules under /mnt/extra-addons must match expected-addons.txt exactly.
#   tests/image/addons.sh <image> [expected-list]
source "$(dirname "$0")/lib.sh"
require_image "${1:-}"
expected_file="${2:-${TESTS_DIR}/expected-addons.txt}"
info "T3 add-ons: ${IMAGE} against $(basename "${expected_file}")"

# shellcheck disable=SC2016  # expanded by the shell in the container
actual="$(in_image 'cd /mnt/extra-addons && for m in */__manifest__.py; do echo "${m%%/*}"; done' | sort)"
expected="$(read_list "${expected_file}" | sort)"
if diff_out="$(diff <(echo "${expected}") <(echo "${actual}"))"; then
    ok "$(echo "${actual}" | wc -l | tr -d ' ') add-ons as expected"
else
    fail "add-on list differs (< expected, > image):"
    echo "${diff_out}" | grep -E '^[<>]' >&2
fi

finish
