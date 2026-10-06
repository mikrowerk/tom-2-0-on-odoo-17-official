#!/usr/bin/env bash
# Copyright Mikrowerk a Gammadata Business.
# SPDX-License-Identifier: AGPL-3
#
# Prepares the host for the stacks below this directory. Idempotent, safe to run repeatedly:
#   1. docker and docker compose v2 available
#   2. external networks db-net and ingress-net
#   3. external volumes postgres_data, odoo_data, certbot_www (created only if missing - on the
#      VPS they already exist and hold the production data)
#   4. ingress/conf.d/ssl-dhparams.pem (ffdhe2048, RFC 7919) if missing; an existing file is
#      never overwritten, an invalid one is an error
#   5. every stack with a .env.example has a .env in which every variable of the example is set,
#      not empty and not "changeme"; permissions wider than 600 give a warning
#   6. ODOO_DB_NAME/USER/PASSWORD are identical in odoo-*/.env and odoo-*/backup/.env
#
#   setup.sh [--root <dir>]      (default: the directory of this script)
#
# Exit code 0 when everything is fine, 1 when a check failed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { echo "--root needs a directory" >&2; exit 2; }
            ROOT="$(cd "$2" && pwd)"
            shift 2
            ;;
        -h | --help)
            sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

NETWORKS=(db-net ingress-net)
VOLUMES=(postgres_data odoo_data certbot_www)
DB_KEYS=(ODOO_DB_NAME ODOO_DB_USER ODOO_DB_PASSWORD)

ERRORS=0
WARNINGS=0
error() { echo "  ERROR: $*" >&2; ERRORS=$((ERRORS + 1)); }
warn() { echo "  WARN:  $*" >&2; WARNINGS=$((WARNINGS + 1)); }
info() { echo "  $*"; }

# env_value <file> <key>: value of KEY=VALUE without surrounding quotes (the file is not sourced)
env_value() {
    local line value
    line="$(grep -E "^[[:space:]]*$2=" "$1" | tail -n 1 || true)"
    value="${line#*=}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "${value}" =~ ^\"(.*)\"$ || "${value}" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
    fi
    printf '%s' "${value}"
}

env_keys() { grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$1" | tr -d ' =' || true; }

file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

echo "== docker"
if ! command -v docker >/dev/null 2>&1; then
    echo "  ERROR: docker not found" >&2
    exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
    echo "  ERROR: docker compose v2 not available" >&2
    exit 1
fi
info "$(docker compose version)"

echo "== networks"
for net in "${NETWORKS[@]}"; do
    if docker network inspect "${net}" >/dev/null 2>&1; then
        info "${net}: exists"
    else
        docker network create "${net}" >/dev/null
        info "${net}: created"
    fi
done

echo "== volumes"
for vol in "${VOLUMES[@]}"; do
    if docker volume inspect "${vol}" >/dev/null 2>&1; then
        info "${vol}: exists"
    else
        docker volume create "${vol}" >/dev/null
        warn "${vol}: did not exist and was CREATED EMPTY - on the VPS this volume should already hold data"
    fi
done

echo "== DH parameters"
dhparams="${ROOT}/ingress/conf.d/ssl-dhparams.pem"
if [[ ! -d "$(dirname "${dhparams}")" ]]; then
    info "no ingress/conf.d, skipped"
elif [[ -e "${dhparams}" ]]; then
    if openssl pkeyparam -in "${dhparams}" -noout >/dev/null 2>&1; then
        info "ssl-dhparams.pem: exists and valid"
    else
        error "ssl-dhparams.pem exists but is no valid DH parameter file (not overwritten): ${dhparams}"
    fi
else
    openssl genpkey -genparam -algorithm DH -pkeyopt group:ffdhe2048 -out "${dhparams}" 2>/dev/null
    chmod 644 "${dhparams}"
    info "ssl-dhparams.pem: created (ffdhe2048)"
fi

echo "== .env files"
while IFS= read -r example; do
    dir="$(dirname "${example}")"
    rel="${dir#"${ROOT}/"}"
    env="${dir}/.env"
    if [[ ! -f "${env}" ]]; then
        error "${rel}/.env missing (template: ${rel}/.env.example)"
        continue
    fi
    missing=0
    for key in $(env_keys "${example}"); do
        if ! grep -qE "^[[:space:]]*${key}=" "${env}"; then
            error "${rel}/.env: ${key} missing"
            missing=1
        else
            value="$(env_value "${env}" "${key}")"
            if [[ -z "${value}" ]]; then
                error "${rel}/.env: ${key} is empty"
                missing=1
            elif [[ "${value}" == "changeme" ]]; then
                error "${rel}/.env: ${key} still has the placeholder 'changeme'"
                missing=1
            fi
        fi
    done
    mode="$(file_mode "${env}")"
    if ((8#${mode} & 8#077)); then
        warn "${rel}/.env has mode ${mode}, expected 600 (chmod 600 ${rel}/.env)"
    fi
    ((missing == 0)) && info "${rel}/.env: complete"
done < <(find "${ROOT}" -mindepth 1 -maxdepth 3 -path "${ROOT}/tests" -prune -o -name .env.example -print | sort)

echo "== database credentials odoo <-> backup"
for backup_env in "${ROOT}"/odoo-*/backup/.env; do
    [[ -f "${backup_env}" ]] || continue
    stack_dir="$(dirname "$(dirname "${backup_env}")")"
    stack="$(basename "${stack_dir}")"
    if [[ ! -f "${stack_dir}/.env" ]]; then
        continue # already reported above
    fi
    same=1
    for key in "${DB_KEYS[@]}"; do
        if [[ "$(env_value "${stack_dir}/.env" "${key}")" != "$(env_value "${backup_env}" "${key}")" ]]; then
            error "${stack}: ${key} differs between .env and backup/.env"
            same=0
        fi
    done
    ((same == 1)) && info "${stack}: consistent"
done

echo "== summary"
if ((ERRORS > 0)); then
    echo "  ${ERRORS} error(s), ${WARNINGS} warning(s)" >&2
    exit 1
fi
echo "  ok (${WARNINGS} warning(s))"
