#!/usr/bin/env bash
# Syntax and reference check of an nginx conf.d directory with `nginx -t` in the nginx container.
#
#   test-nginx-config.sh <conf-dir> [--add-host <name>]...
#
# For every domain referenced by `ssl_certificate .../live/<domain>/...` a self-signed dummy
# certificate is generated. --add-host maps a hostname to 127.0.0.1 (needed by configs with a
# statically resolved upstream such as `server odoo:8069;`).
# The config is tested on a copy: if `ssl_dhparam` references a file that is missing or no valid
# PEM (the versioned nginx-conf/ssl-dhparams.pem is redacted, on the VPS setup.sh creates it),
# test DH parameters (ffdhe2048) are put into the copy.
# The nginx image is taken from ingress/compose.yaml if it exists, otherwise the image of the
# monolithic compose file (docker.io/nginx:latest). NGINX_IMAGE overrides both.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd docker openssl

[[ $# -ge 1 ]] || die "usage: $0 <conf-dir> [--add-host <name>]..."
CONF_DIR="$(cd "$1" && pwd)"
shift

HOST_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --add-host)
            [[ $# -ge 2 ]] || die "--add-host needs a name"
            HOST_ARGS+=(--add-host "$2:127.0.0.1")
            shift 2
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

if [[ -z "${NGINX_IMAGE:-}" ]]; then
    if [[ -f "${SERVICES_DIR}/ingress/compose.yaml" ]]; then
        NGINX_IMAGE="$(compose_json "${SERVICES_DIR}/ingress/compose.yaml" "${SERVICES_DIR}/ingress/.env.example" |
            jq -r '.services.nginx.image')"
    else
        NGINX_IMAGE="docker.io/nginx:latest"
    fi
fi

WORK="$(make_tmp nginx)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/conf"
cp -R "${CONF_DIR}/." "${WORK}/conf/"
if grep -rqE '^\s*ssl_dhparam\s+/etc/nginx/conf.d/ssl-dhparams.pem' "${WORK}/conf" &&
    ! openssl pkeyparam -in "${WORK}/conf/ssl-dhparams.pem" -noout >/dev/null 2>&1; then
    echo "  note: ssl-dhparams.pem missing or invalid, using generated test DH parameters"
    openssl genpkey -genparam -algorithm DH -pkeyopt group:ffdhe2048 -out "${WORK}/conf/ssl-dhparams.pem" 2>/dev/null
fi

# dummy certificates for all referenced domains
domains="$(grep -rhoE 'live/[^/]+/' "${CONF_DIR}" | sed -E 's#live/([^/]+)/#\1#' | sort -u || true)"
for domain in ${domains}; do
    mkdir -p "${WORK}/letsencrypt/live/${domain}"
    openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj "/CN=${domain}" \
        -keyout "${WORK}/letsencrypt/live/${domain}/privkey.pem" \
        -out "${WORK}/letsencrypt/live/${domain}/fullchain.pem" >/dev/null 2>&1
done
mkdir -p "${WORK}/letsencrypt"

echo "== nginx -t (${CONF_DIR}, image ${NGINX_IMAGE}${HOST_ARGS[*]:+, ${HOST_ARGS[*]}})"
if docker run --rm ${HOST_ARGS[@]+"${HOST_ARGS[@]}"} \
    -v "${WORK}/conf:/etc/nginx/conf.d:ro" \
    -v "${WORK}/letsencrypt:/etc/letsencrypt:ro" \
    "${NGINX_IMAGE}" nginx -t; then
    pass "nginx -t"
else
    fail "nginx -t"
fi
finish
