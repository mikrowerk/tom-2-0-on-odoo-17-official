#!/usr/bin/env bash
# Tests for setup.sh on a copy of deployment/docker-services below tests/.tmp.
# setup.sh creates the real networks/volumes; those that did not exist before the test are
# removed again at the end.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd docker openssl

RESOURCES_NET=(db-net ingress-net)
RESOURCES_VOL=(postgres_data odoo_data certbot_www)
created_net=()
created_vol=()
for n in "${RESOURCES_NET[@]}"; do docker network inspect "${n}" >/dev/null 2>&1 || created_net+=("${n}"); done
for v in "${RESOURCES_VOL[@]}"; do docker volume inspect "${v}" >/dev/null 2>&1 || created_vol+=("${v}"); done

WORK="$(make_tmp setup)"
cleanup() {
    rm -rf "${WORK}"
    for n in ${created_net[@]+"${created_net[@]}"}; do docker network rm "${n}" >/dev/null 2>&1 || true; done
    for v in ${created_vol[@]+"${created_vol[@]}"}; do docker volume rm "${v}" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

FIX="${WORK}/services"
OUT="${WORK}/out.log"

# fresh fixture: copy of the stacks without tests, local .env files and DH parameters
fixture() {
    rm -rf "${FIX}"
    mkdir -p "${FIX}"
    (cd "${SERVICES_DIR}" && tar --exclude ./tests --exclude '.env' --exclude 'ssl-dhparams.pem' -cf - .) |
        (cd "${FIX}" && tar -xf -)
}

# valid .env files: every "changeme" replaced by the same test value, mode 600
valid_envs() {
    local example
    while IFS= read -r example; do
        sed 's/=changeme$/=test-value/' "${example}" >"$(dirname "${example}")/.env"
        chmod 600 "$(dirname "${example}")/.env"
    done < <(find "${FIX}" -name .env.example)
}

run_setup() { "${SERVICES_DIR}/setup.sh" --root "${FIX}" >"${OUT}" 2>&1; }

# expect <description> <exit-code> [<pattern in output>]
expect() {
    local desc="$1" code="$2" pattern="${3:-}" rc=0
    run_setup || rc=$?
    if [[ "${rc}" != "${code}" ]]; then
        fail "${desc}: exit ${rc}, expected ${code}"
        sed 's/^/        /' "${OUT}" >&2
    elif [[ -n "${pattern}" ]] && ! grep -qE "${pattern}" "${OUT}"; then
        fail "${desc}: output lacks /${pattern}/"
        sed 's/^/        /' "${OUT}" >&2
    else
        pass "${desc}"
    fi
}

echo "== setup.sh"

fixture
expect "missing .env files are reported" 1 "database/.env missing"

fixture
valid_envs
expect "valid fixture" 0 "ok \(0 warning"
for n in "${RESOURCES_NET[@]}"; do
    if docker network inspect "${n}" >/dev/null 2>&1; then pass "network ${n} exists"; else fail "network ${n} missing"; fi
done
DH="${FIX}/ingress/conf.d/ssl-dhparams.pem"
if openssl pkeyparam -in "${DH}" -noout >/dev/null 2>&1; then pass "ssl-dhparams.pem created"; else fail "ssl-dhparams.pem not created"; fi
sum_before="$(openssl dgst -sha256 "${DH}")"
expect "second run is idempotent" 0 "ssl-dhparams.pem: exists and valid"
assert_eq "existing ssl-dhparams.pem untouched" "${sum_before}" "$(openssl dgst -sha256 "${DH}")"

fixture
valid_envs
sed -i.bak '/^POSTGRESQL_PASSWORD=/d' "${FIX}/database/.env"
expect "missing variable" 1 "database/.env: POSTGRESQL_PASSWORD missing"

fixture
valid_envs
sed -i.bak 's/^POSTGRESQL_PASSWORD=.*/POSTGRESQL_PASSWORD=/' "${FIX}/database/.env"
expect "empty variable" 1 "POSTGRESQL_PASSWORD is empty"

fixture
valid_envs
sed -i.bak 's/^S3_BUCKET=.*/S3_BUCKET=changeme/' "${FIX}/odoo-griffity-prod/backup/.env"
expect "placeholder changeme" 1 "S3_BUCKET still has the placeholder"

fixture
valid_envs
sed -i.bak 's/^ODOO_DB_USER=.*/ODOO_DB_USER=someone-else/' "${FIX}/odoo-griffity-prod/backup/.env"
expect "db user differs between odoo and backup" 1 "ODOO_DB_USER differs"

fixture
valid_envs
printf -- '-----BEGIN DH PARAMETERS-----\n*** redacted ***\n-----END DH PARAMETERS-----\n' >"${DH}"
sum_before="$(openssl dgst -sha256 "${DH}")"
expect "invalid ssl-dhparams.pem" 1 "no valid DH parameter file"
assert_eq "invalid ssl-dhparams.pem not overwritten" "${sum_before}" "$(openssl dgst -sha256 "${DH}")"

fixture
valid_envs
chmod 644 "${FIX}/database/.env"
expect "wide permissions only warn" 0 "database/.env has mode 644"

finish
