#!/usr/bin/env bash
# T4: install the module list on a fresh database in a throwaway Postgres container.
#   tests/image/install.sh <image> [module-list]
# Fails on a non-zero exit code, on ERROR/CRITICAL/Traceback in the log or when a module is not installed.
source "$(dirname "$0")/lib.sh"
require_image "${1:-}"
modules_file="${2:-${TESTS_DIR}/modules.txt}"
modules="$(read_list "${modules_file}" | paste -sd, -)"
count="$(read_list "${modules_file}" | wc -l | tr -d ' ')"
info "T4 install: ${count} modules from $(basename "${modules_file}") in ${IMAGE}"

# Everything below is created for this run only and removed on exit; no port is published.
run_id="tom-image-test-$$-${RANDOM}"
pg_password="$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 24 || true)"
pg_image="${POSTGRES_IMAGE:-postgres:15}"
log_file="$(mktemp -t "${run_id}.XXXXXX")"
cleanup() {
    docker rm -f -v "${run_id}-db" >/dev/null 2>&1 || true
    docker network rm "${run_id}" >/dev/null 2>&1 || true
    rm -f "${log_file}"
}
trap cleanup EXIT

docker pull -q "${pg_image}" >/dev/null
docker network create "${run_id}" >/dev/null
docker run -d --name "${run_id}-db" --network "${run_id}" --network-alias db \
    -e POSTGRES_USER=odoo -e POSTGRES_PASSWORD="${pg_password}" -e POSTGRES_DB=postgres \
    "${pg_image}" >/dev/null
for _ in $(seq 1 60); do
    docker exec "${run_id}-db" pg_isready -U odoo -d postgres >/dev/null 2>&1 && break
    sleep 1
done
docker exec "${run_id}-db" pg_isready -U odoo -d postgres >/dev/null || { fail "postgres not ready"; finish; }

set +e
docker run --rm --network "${run_id}" -e HOST=db -e USER=odoo -e PASSWORD="${pg_password}" "${IMAGE}" \
    odoo -d test_image -i "${modules}" --stop-after-init --without-demo=all --log-level=info \
    >"${log_file}" 2>&1
rc=$?
set -e
check "odoo -i exit code 0" "odoo -i exit code ${rc}" test "${rc}" -eq 0

errors="$(grep -E ' (ERROR|CRITICAL) |^Traceback' "${log_file}" || true)"
if [[ -z "${errors}" ]]; then
    ok "no ERROR/CRITICAL/Traceback in the log"
else
    fail "errors in the log:"
    echo "${errors}" | head -20 >&2
fi
warnings="$(grep -c ' WARNING ' "${log_file}" || true)"
info "  info  ${warnings} WARNING line(s) in the log"
if [[ -n "${errors}" || ${rc} -ne 0 ]]; then
    info "  last log lines:"; tail -25 "${log_file}" | sed 's/^/    /' >&2
fi

quoted="'$(read_list "${modules_file}" | paste -sd, - | sed "s/,/','/g")'"
installed="$(docker exec "${run_id}-db" psql -U odoo -d test_image -X -t -A -c \
    "select count(*) from ir_module_module where state = 'installed' and name in (${quoted})" 2>/dev/null || echo 0)"
check "${installed}/${count} modules installed" "${installed}/${count} modules installed" \
    test "${installed}" = "${count}"

finish
