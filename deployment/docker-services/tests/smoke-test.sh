#!/usr/bin/env bash
# shellcheck disable=SC2016  # commands for `sh -c` inside containers use their own variables
# End-to-end smoke test of all stacks on the local Docker host (plan step 11).
#
# Runs on a copy of deployment/docker-services below tests/.tmp with dummy .env files, a test
# odoo.conf (workers = 0), a self-signed certificate and native images (see the spec, section
# "Smoke-Test auf Apple Silicon"):
#   postgres  docker.io/bitnamilegacy/postgresql:15.10.0-debian-12-r2
#   odoo      docker.io/library/odoo:17.0 (official image, without TOM modules)
#   backup    tom-backup-image:smoke, built from ../tom-backup-image (fallback: production image)
# It proves the infrastructure (start order, robust nginx start, routing, ports, network
# isolation, websocket handshake, DB access of the backup, decoupling of the backup), not the
# TOM image itself.
#
# Needs free host ports 80, 443 and 15432 (SMOKE_PG_HOST_PORT). Aborts if the volumes postgres_data, odoo_data or
# certbot_www already exist; everything it creates is removed again (the image
# tom-backup-image:smoke is kept as build cache).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd docker curl openssl git

DOMAIN="tomagency.griffity.de"
DB_NAME="tomagency.griffity.de"
POSTGRES_IMAGE="docker.io/bitnamilegacy/postgresql:15.10.0-debian-12-r2"
ODOO_IMAGE="docker.io/library/odoo"
ODOO_IMAGE_TAG="17.0"
BACKUP_REPO="$(cd "${REPO_ROOT}/.." && pwd)/tom-backup-image"
BACKUP_BRANCH="feature/build-image-for-odoo-17"
BACKUP_IMAGE="tom-backup-image:smoke"
PG_HOST_PORT="${SMOKE_PG_HOST_PORT:-15432}"
VOLUMES=(postgres_data odoo_data certbot_www)
NETWORKS=(db-net ingress-net)
STACKS=(ingress odoo-griffity-prod/backup odoo-griffity-prod database)

for vol in "${VOLUMES[@]}"; do
    if docker volume inspect "${vol}" >/dev/null 2>&1; then
        die "volume ${vol} already exists - the smoke test does not touch existing data"
    fi
done
created_net=()
for net in "${NETWORKS[@]}"; do docker network inspect "${net}" >/dev/null 2>&1 || created_net+=("${net}"); done

WORK="$(make_tmp smoke)"
FIX="${WORK}/services"

dc() {
    local stack="$1"
    shift
    docker compose --project-directory "${FIX}/${stack}" -f "${FIX}/${stack}/compose.yaml" "$@"
}

cleanup() {
    local rc=$?
    echo "== cleanup"
    if ((rc != 0)) || ((FAILURES > 0)); then
        for stack in "${STACKS[@]}"; do
            [[ -f "${FIX}/${stack}/compose.yaml" ]] && dc "${stack}" logs --tail 30 2>&1 | sed 's/^/    /' || true
        done
    fi
    for stack in "${STACKS[@]}"; do
        [[ -f "${FIX}/${stack}/compose.yaml" ]] && dc "${stack}" down --remove-orphans >/dev/null 2>&1 || true
    done
    for vol in "${VOLUMES[@]}"; do docker volume rm "${vol}" >/dev/null 2>&1 || true; done
    for net in ${created_net[@]+"${created_net[@]}"}; do docker network rm "${net}" >/dev/null 2>&1 || true; done
    rm -rf "${WORK}"
}
trap cleanup EXIT

cid() { dc "$1" ps -q "$2"; }

# quiet <command...>: run with output in a log, show the log and abort on failure
quiet() {
    if ! "$@" >"${WORK}/step.log" 2>&1; then
        fail "command failed: $*"
        tail -n 40 "${WORK}/step.log" >&2
        exit 1
    fi
}

# http_code <scheme> <path>: status code of a request through nginx on 127.0.0.1
http_code() {
    local port=443
    [[ "$1" == "http" ]] && port=80
    curl -sk -o /dev/null -w '%{http_code}' --max-time 20 \
        --resolve "${DOMAIN}:${port}:127.0.0.1" "$1://${DOMAIN}$2" || true
}

# ws_handshake: status code of a websocket handshake on /websocket through nginx (101 expected).
# The key is the 16-byte sample nonce of RFC 6455. After a 101 the connection stays open, curl
# ends with the timeout and still writes the status code.
ws_handshake() {
    curl -sk -o /dev/null -w '%{http_code}' --http1.1 --max-time 5 \
        --resolve "${DOMAIN}:443:127.0.0.1" \
        -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" \
        -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Origin: https://${DOMAIN}" \
        "https://${DOMAIN}/websocket" || true
}

# wait_for_code <expected> <timeout-seconds> <scheme> <path>
wait_for_code() {
    local expected="$1" timeout="$2" code="" waited=0
    while ((waited < timeout)); do
        code="$(http_code "$3" "$4")"
        [[ "${code}" == "${expected}" ]] && break
        sleep 5
        waited=$((waited + 5))
    done
    printf '%s' "${code}"
}

echo "== fixture"
mkdir -p "${FIX}"
(cd "${SERVICES_DIR}" && tar --exclude ./tests --exclude '.env' --exclude 'ssl-dhparams.pem' -cf - .) |
    (cd "${FIX}" && tar -xf -)

mkdir -p "${WORK}/odoo-conf"
cat >"${WORK}/odoo-conf/odoo.conf" <<EOF
[options]
addons_path = /mnt/extra-addons
data_dir = /var/lib/odoo/data
dbfilter = ^%h\$
list_db = False
db_host = postgresql
db_port = 5432
proxy_mode = True
workers = 0
EOF

mkdir -p "${WORK}/letsencrypt/live/${DOMAIN}"
openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj "/CN=${DOMAIN}" \
    -keyout "${WORK}/letsencrypt/live/${DOMAIN}/privkey.pem" \
    -out "${WORK}/letsencrypt/live/${DOMAIN}/fullchain.pem" >/dev/null 2>&1

cat >"${FIX}/database/.env" <<EOF
POSTGRESQL_POSTGRES_PASSWORD=smoke-root-pw
POSTGRESQL_USERNAME=odoo_smoke
POSTGRESQL_PASSWORD=smoke-odoo-pw
POSTGRESQL_DATABASE=${DB_NAME}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
POSTGRES_HOST_PORT=${PG_HOST_PORT}
EOF
cat >"${FIX}/odoo-griffity-prod/.env" <<EOF
ODOO_IMAGE=${ODOO_IMAGE}
ODOO_IMAGE_TAG=${ODOO_IMAGE_TAG}
ODOO_DB_NAME=${DB_NAME}
ODOO_DB_USER=odoo_smoke
ODOO_DB_PASSWORD=smoke-odoo-pw
ODOO_CONFIG_ENCRYPTION_KEY=smoke-encryption-key
ODOO_CONF_DIR=${WORK}/odoo-conf
EOF
cat >"${FIX}/odoo-griffity-prod/backup/.env" <<EOF
ODOO_DB_NAME=${DB_NAME}
ODOO_DB_USER=odoo_smoke
ODOO_DB_PASSWORD=smoke-odoo-pw
AWS_ACCESS_KEY_ID=smoke
AWS_SECRET_ACCESS_KEY=smoke
AWS_REGION=eu-central-1
S3_BUCKET=smoke-bucket
ENCRYPTION_PASSWORD=smoke
BACKUP_RETENTION=10d
BACKUP_IMAGE=${BACKUP_IMAGE}
EOF
cat >"${FIX}/ingress/.env" <<EOF
CERTBOT_DIR=${WORK}/letsencrypt
EOF
chmod 600 "${FIX}"/database/.env "${FIX}"/odoo-griffity-prod/.env "${FIX}"/odoo-griffity-prod/backup/.env "${FIX}"/ingress/.env
pass "fixture in ${WORK}"

echo "== images"
if [[ -d "${BACKUP_REPO}" ]]; then
    branch="$(git -C "${BACKUP_REPO}" rev-parse --abbrev-ref HEAD)"
    [[ "${branch}" == "${BACKUP_BRANCH}" ]] || die "${BACKUP_REPO} is on ${branch}, expected ${BACKUP_BRANCH}"
    [[ -z "$(git -C "${BACKUP_REPO}" status --porcelain)" ]] || echo "  note: ${BACKUP_REPO} has local changes"
    docker build -q -t "${BACKUP_IMAGE}" "${BACKUP_REPO}" >/dev/null
    pass "backup image built natively from ${BACKUP_REPO} (${BACKUP_BRANCH})"
    native_images=("${POSTGRES_IMAGE}" "${ODOO_IMAGE}:${ODOO_IMAGE_TAG}" "${BACKUP_IMAGE}")
else
    echo "  WARN: ${BACKUP_REPO} not found, using the production backup image under emulation" >&2
    BACKUP_IMAGE="ghcr.io/mikrowerk/tom-backup-image:feature-build-image-for-odoo-17"
    sed -i.bak "s#^BACKUP_IMAGE=.*#BACKUP_IMAGE=${BACKUP_IMAGE}#" "${FIX}/odoo-griffity-prod/backup/.env"
    docker pull -q --platform linux/amd64 "${BACKUP_IMAGE}" >/dev/null
    native_images=("${POSTGRES_IMAGE}" "${ODOO_IMAGE}:${ODOO_IMAGE_TAG}")
fi
for stack in database odoo-griffity-prod ingress; do
    dc "${stack}" pull -q
done
host_arch="$(docker info --format '{{.Architecture}}')"
[[ "${host_arch}" == "aarch64" ]] && host_arch="arm64"
[[ "${host_arch}" == "x86_64" ]] && host_arch="amd64"
for image in "${native_images[@]}" "$(dc ingress config --images | grep nginx)"; do
    assert_eq "image ${image} native" "${host_arch}" "$(docker image inspect --format '{{.Architecture}}' "${image}")"
done

echo "== 1. setup and database"
if "${SERVICES_DIR}/setup.sh" --root "${FIX}" >"${WORK}/setup.log" 2>&1; then
    pass "setup.sh"
else
    fail "setup.sh"
    cat "${WORK}/setup.log" >&2
    exit 1
fi
quiet dc database up -d --wait --wait-timeout 180
assert_eq "postgresql healthy" "healthy" "$(docker inspect --format '{{.State.Health.Status}}' "$(cid database postgresql)")"

echo "== 2. initialise test database"
if dc odoo-griffity-prod run --rm odoo odoo -d "${DB_NAME}" -i base --without-demo=all --stop-after-init \
    >"${WORK}/init.log" 2>&1; then
    pass "odoo -i base on ${DB_NAME}"
else
    fail "odoo -i base"
    tail -n 30 "${WORK}/init.log" >&2
    exit 1
fi

echo "== 3. robust start: ingress without running odoo"
quiet dc ingress up -d
sleep 5
nginx_id="$(cid ingress nginx)"
nginx_started="$(docker inspect --format '{{.State.StartedAt}}' "${nginx_id}")"
assert_eq "nginx running without odoo" "running" "$(docker inspect --format '{{.State.Status}}' "${nginx_id}")"
assert_eq "nginx without restarts" "0" "$(docker inspect --format '{{.RestartCount}}' "${nginx_id}")"
assert_eq "https while odoo is down" "502" "$(http_code https /web/login)"

echo "== 4. odoo up, reached without nginx restart"
quiet dc odoo-griffity-prod up -d
assert_eq "https /web/login" "200" "$(wait_for_code 200 240 https /web/login)"
assert_eq "nginx not restarted" "${nginx_started}" "$(docker inspect --format '{{.State.StartedAt}}' "${nginx_id}")"

echo "== 5. http redirect"
assert_eq "http -> https" "301" "$(http_code http /web/login)"

echo "== 5b. websocket (live updates)"
assert_eq "websocket handshake on /websocket" "101" "$(ws_handshake)"

echo "== 6. ports"
pg_id="$(cid database postgresql)"
odoo_id="$(cid odoo-griffity-prod odoo)"
assert_eq "postgresql bound to loopback only" "127.0.0.1:${PG_HOST_PORT}" \
    "$(docker inspect --format '{{range (index .HostConfig.PortBindings "5432/tcp")}}{{.HostIp}}:{{.HostPort}} {{end}}' "${pg_id}" | xargs)"
assert_eq "odoo without port bindings" "" \
    "$(docker inspect --format '{{range $p, $b := .HostConfig.PortBindings}}{{$p}} {{end}}' "${odoo_id}" | xargs)"

echo "== 7. network isolation"
if docker exec "${nginx_id}" getent hosts postgresql >/dev/null 2>&1; then
    fail "nginx can resolve postgresql"
else
    pass "nginx cannot resolve postgresql"
fi
if docker exec "${odoo_id}" getent hosts postgresql >/dev/null 2>&1; then
    pass "odoo resolves postgresql"
else
    fail "odoo cannot resolve postgresql"
fi

echo "== 8. backup"
quiet dc odoo-griffity-prod/backup up -d
backup_id="$(cid odoo-griffity-prod/backup backup-service)"
if docker exec "${backup_id}" sh -c \
    'PGPASSWORD="$POSTGRESQL_POSTGRES_PASSWORD" pg_dump -h "$POSTGRES_HOST" -U "$POSTGRESQL_USERNAME" "$POSTGRESQL_DATABASE" >/dev/null'; then
    pass "pg_dump with the odoo DB user"
else
    fail "pg_dump with the odoo DB user"
fi
if docker exec "${backup_id}" sh -c 'test -d "$DATA_DIR"'; then pass "DATA_DIR exists"; else fail "DATA_DIR missing"; fi
if docker exec "${backup_id}" sh -c 'touch "$DATA_DIR/.smoke" 2>/dev/null'; then
    fail "DATA_DIR is writable"
else
    pass "DATA_DIR read-only"
fi

echo "== 9. backup decoupled from the odoo stack"
quiet dc odoo-griffity-prod up -d --force-recreate
assert_eq "backup untouched by odoo up --force-recreate" "${backup_id}" "$(cid odoo-griffity-prod/backup backup-service)"
quiet dc odoo-griffity-prod down
assert_eq "backup keeps running after odoo down" "running" "$(docker inspect --format '{{.State.Status}}' "${backup_id}")"

echo "== 10. start-all-services.sh"
for stack in "${STACKS[@]}"; do quiet dc "${stack}" down; done
if "${SERVICES_DIR}/start-all-services.sh" --root "${FIX}" >"${WORK}/start-all.log" 2>&1; then
    pass "start-all-services.sh"
else
    fail "start-all-services.sh"
    tail -n 30 "${WORK}/start-all.log" >&2
fi
for pair in database:postgresql odoo-griffity-prod:odoo odoo-griffity-prod/backup:backup-service ingress:nginx ingress:certbot; do
    id="$(cid "${pair%%:*}" "${pair##*:}")"
    assert_eq "${pair##*:} running" "running" "$(docker inspect --format '{{.State.Status}}' "${id}" 2>/dev/null || echo missing)"
done
assert_eq "https /web/login after start-all" "200" "$(wait_for_code 200 240 https /web/login)"

finish
