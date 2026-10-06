#!/usr/bin/env bash
# Tests the start order of start-all-services.sh with --dry-run on a fixture with a second
# Odoo instance (odoo-test2, without backup) next to odoo-griffity-prod (with backup).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

WORK="$(make_tmp start-order)"
trap 'rm -rf "${WORK}"' EXIT

FIX="${WORK}/services"
mkdir -p "${FIX}"
(cd "${SERVICES_DIR}" && tar --exclude ./tests --exclude '.env' -cf - .) | (cd "${FIX}" && tar -xf -)
mkdir -p "${FIX}/odoo-test2"
cp "${FIX}/odoo-griffity-prod/compose.yaml" "${FIX}/odoo-test2/compose.yaml"

echo "== start-all-services.sh --dry-run"
out="$("${SERVICES_DIR}/start-all-services.sh" --root "${FIX}" --dry-run)"

# order of the started stacks (relative directories)
order="$(grep -E '^\+ docker compose' <<<"${out}" | sed -E "s#.*--project-directory ${FIX}/([^ ]+) .*#\1#" | paste -sd ' ' -)"
assert_eq "start order" "database odoo-griffity-prod odoo-test2 odoo-griffity-prod/backup ingress" "${order}"

first="$(grep -E '^\+ ' <<<"${out}" | head -n 1)"
if [[ "${first}" == *"setup.sh --root ${FIX}" ]]; then pass "setup.sh runs first"; else fail "setup.sh not first: ${first}"; fi

db_line="$(grep -E "project-directory ${FIX}/database " <<<"${out}")"
if [[ "${db_line}" == *"up -d --wait --wait-timeout"* ]]; then pass "database waits until healthy"; else fail "database without --wait: ${db_line}"; fi

if grep -q "project-directory ${FIX}/odoo-test2/backup" <<<"${out}"; then
    fail "backup started for odoo-test2 without backup/"
else
    pass "no backup for an instance without backup/"
fi

# without an Odoo instance only database and ingress remain
rm -rf "${FIX}/odoo-griffity-prod" "${FIX}/odoo-test2"
out="$("${SERVICES_DIR}/start-all-services.sh" --root "${FIX}" --dry-run)"
order="$(grep -E '^\+ docker compose' <<<"${out}" | sed -E "s#.*--project-directory ${FIX}/([^ ]+) .*#\1#" | paste -sd ' ' -)"
assert_eq "start order without odoo instances" "database ingress" "${order}"

finish
