#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs use $variables, single quotes are intended
# Parity test: the functional invariants of the monolithic docker-compose.yaml must survive the
# split into the modular stacks under deployment/docker-services.
#
#   test-compose-parity.sh --monolith <docker-compose.yaml>
#   test-compose-parity.sh --modular <deployment/docker-services>
#
# In --modular mode stacks that do not exist yet are skipped; the services of existing stacks are
# checked. Intentional differences (ports, container_name, restart, networks) are covered by
# test-compose-policy.sh, not here.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd docker jq

MODULAR_STACKS=(database odoo-griffity-prod odoo-griffity-prod/backup ingress)

usage() {
    echo "usage: $0 --monolith <compose-file> | --modular <services-dir>" >&2
    exit 2
}

[[ $# -eq 2 ]] || usage
MODE="$1"
TARGET="$2"

case "${MODE}" in
    --monolith)
        [[ -f "${TARGET}" ]] || die "compose file not found: ${TARGET}"
        CONFIG="$(compose_json "${TARGET}")"
        ;;
    --modular)
        [[ -d "${TARGET}" ]] || die "directory not found: ${TARGET}"
        parts=()
        for stack in "${MODULAR_STACKS[@]}"; do
            file="${TARGET}/${stack}/compose.yaml"
            if [[ ! -f "${file}" ]]; then
                echo "  skip: stack ${stack} does not exist (yet)"
                continue
            fi
            parts+=("$(compose_json "${file}" "${TARGET}/${stack}/.env.example")")
        done
        ((${#parts[@]} > 0)) || die "no stack found below ${TARGET}"
        CONFIG="$(printf '%s\n' "${parts[@]}" | jq -s '
            reduce .[] as $c ({services: {}, volumes: {}};
                .services += ($c.services // {}) | .volumes += ($c.volumes // {}))')"
        ;;
    *)
        usage
        ;;
esac

q() { jq -r "$@" <<<"${CONFIG}"; }

has_service() { [[ "$(q --arg s "$1" '.services | has($s)')" == "true" ]]; }

check_env_keys() {
    local svc="$1" key
    shift
    for key in "$@"; do
        if [[ "$(q --arg s "${svc}" --arg k "${key}" '.services[$s].environment // {} | has($k)')" == "true" ]]; then
            pass "${svc}: env ${key} defined"
        else
            fail "${svc}: env ${key} missing"
        fi
    done
}

env_value() { q --arg s "$1" --arg k "$2" '.services[$s].environment[$k] // ""'; }

# check_volume <service> <type> <source|""> <target> [ro]
check_volume() {
    local svc="$1" type="$2" source="$3" target="$4" ro="${5:-}"
    local match
    match="$(q --arg s "${svc}" --arg t "${type}" --arg src "${source}" --arg tgt "${target}" '
        [.services[$s].volumes // [] | .[]
         | select(.type == $t and .target == $tgt and ($src == "" or .source == $src))] | first // empty')"
    if [[ -z "${match}" ]]; then
        fail "${svc}: ${type} ${source:-<any>} -> ${target} missing"
        return
    fi
    if [[ "${ro}" == "ro" && "$(jq -r '.read_only // false' <<<"${match}")" != "true" ]]; then
        fail "${svc}: ${source} -> ${target} must be read-only"
        return
    fi
    pass "${svc}: ${type} ${source:-<any>} -> ${target}${ro:+ (ro)}"
}

echo "== compose parity (${MODE} ${TARGET})"

# --- shared external volumes -----------------------------------------------------------------
for vol in postgres_data odoo_data certbot_www; do
    if [[ "$(q --arg v "${vol}" '.volumes | has($v)')" != "true" ]]; then
        [[ "${MODE}" == "--monolith" ]] && fail "volume ${vol} not declared"
        continue
    fi
    assert_eq "volume ${vol} is external" "true" "$(q --arg v "${vol}" '.volumes[$v].external // false')"
    assert_eq "volume ${vol} keeps its name" "${vol}" "$(q --arg v "${vol}" '.volumes[$v].name')"
done

# --- postgresql ------------------------------------------------------------------------------
if has_service postgresql; then
    image="$(q '.services.postgresql.image')"
    case "${image}" in
        docker.io/bitnami/postgresql:15 | ghcr.io/mikrowerk/postgresql:15) pass "postgresql: bitnami-compatible image ${image}" ;;
        *) fail "postgresql: unexpected image ${image}" ;;
    esac
    check_volume postgresql volume postgres_data /bitnami/postgresql
    check_env_keys postgresql POSTGRESQL_POSTGRES_PASSWORD POSTGRESQL_USERNAME POSTGRESQL_PASSWORD POSTGRESQL_DATABASE
elif [[ "${MODE}" == "--monolith" ]]; then
    fail "service postgresql missing"
fi

# --- odoo ------------------------------------------------------------------------------------
ODOO_DB=""
if has_service odoo; then
    image="$(q '.services.odoo.image')"
    if [[ "${image}" == ghcr.io/mikrowerk/tom-2-0-odoo-17-image:* ]]; then
        pass "odoo: image ${image}"
    else
        fail "odoo: unexpected image ${image}"
    fi
    assert_eq "odoo: command prefix" "odoo --log-level=info -d" "$(q '.services.odoo.command[0:3] | join(" ")')"
    ODOO_DB="$(q '.services.odoo.command[3] // ""')"
    if [[ -n "${ODOO_DB}" ]]; then pass "odoo: database ${ODOO_DB}"; else fail "odoo: no database in command"; fi
    check_volume odoo volume odoo_data /var/lib/odoo
    check_volume odoo bind "" /etc/odoo
    check_env_keys odoo HOST PORT USER PASSWORD ODOO_CONFIG_ENCRYPTION_KEY
    assert_eq "odoo: HOST" "postgresql" "$(env_value odoo HOST)"
    assert_eq "odoo: PORT" "5432" "$(env_value odoo PORT)"
elif [[ "${MODE}" == "--monolith" ]]; then
    fail "service odoo missing"
fi

# --- backup-service --------------------------------------------------------------------------
if has_service backup-service; then
    assert_eq "backup-service: image" "ghcr.io/mikrowerk/tom-backup-image:feature-build-image-for-odoo-17" \
        "$(q '.services["backup-service"].image')"
    check_volume backup-service volume odoo_data /var/lib/odoo ro
    # variables read by backup.sh in tom-backup-image
    check_env_keys backup-service POSTGRES_HOST POSTGRESQL_POSTGRES_PASSWORD POSTGRESQL_USERNAME \
        POSTGRESQL_DATABASE S3_BUCKET DATA_DIR BACKUP_RETENTION ENCRYPTION_PASSWORD \
        AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION
    assert_eq "backup-service: POSTGRES_HOST" "postgresql" "$(env_value backup-service POSTGRES_HOST)"
    backup_db="$(env_value backup-service POSTGRESQL_DATABASE)"
    assert_eq "backup-service: DATA_DIR matches database" "/var/lib/odoo/data/filestore/${backup_db}" \
        "$(env_value backup-service DATA_DIR)"
    if [[ -n "${ODOO_DB}" ]]; then
        assert_eq "backup-service: same database as odoo" "${ODOO_DB}" "${backup_db}"
    fi
elif [[ "${MODE}" == "--monolith" ]]; then
    fail "service backup-service missing"
fi

# --- nginx -----------------------------------------------------------------------------------
if has_service nginx; then
    assert_eq "nginx: published ports" "443,80" \
        "$(q '[.services.nginx.ports // [] | .[] | .target | tostring] | unique | join(",")')"
    check_volume nginx bind "" /etc/nginx/conf.d
    check_volume nginx bind "" /etc/letsencrypt
    check_volume nginx volume certbot_www /var/www/certbot
elif [[ "${MODE}" == "--monolith" ]]; then
    fail "service nginx missing"
fi

# --- certbot ---------------------------------------------------------------------------------
if has_service certbot; then
    # `docker compose config` keeps the escaped $$ of the compose file
    assert_eq "certbot: renew loop entrypoint" \
        '/bin/sh|-c|trap exit TERM; while :; do certbot renew; sleep 12h & wait $${!}; done;' \
        "$(q '.services.certbot.entrypoint | join("|")')"
    check_volume certbot bind "" /etc/letsencrypt
    check_volume certbot volume certbot_www /var/www/certbot
elif [[ "${MODE}" == "--monolith" ]]; then
    fail "service certbot missing"
fi

finish
