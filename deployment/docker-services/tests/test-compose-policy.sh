#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs use $variables, single quotes are intended
# Policy test for all stacks below deployment/docker-services (compose.yaml one or two levels deep):
#   - every file has a fixed project name, no service has a container_name
#   - only nginx publishes ports (80/443); postgresql only on 127.0.0.1:5432; no other ports
#   - restart: unless-stopped for the long-running services
#   - networks: postgresql only in db-net, nginx never in db-net, odoo in both with alias,
#     backup only in db-net, certbot in neither; db-net/ingress-net are external
#   - no secret literals in the raw YAML (values of *PASSWORD*/*SECRET*/*KEY* are ${...})
#   - image defaults (POSTGRES_IMAGE, ODOO_IMAGE, BACKUP_IMAGE unset) are the production images,
#     and none of these variables appears in a .env.example
#   - nginx image is pinned (no :latest, version >= 1.27.3 for `server ... resolve`)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd docker jq

PROD_POSTGRES_IMAGE="ghcr.io/mikrowerk/postgresql:15"
PROD_ODOO_REPO="ghcr.io/mikrowerk/tom-2-0-odoo-17-image"
PROD_BACKUP_IMAGE="ghcr.io/mikrowerk/tom-backup-image:feature-build-image-for-odoo-17"
RESTART_SERVICES=" postgresql odoo nginx certbot backup-service "

mapfile -t FILES < <(find "${SERVICES_DIR}" -mindepth 2 -maxdepth 3 -name compose.yaml -not -path '*/tests/*' | sort)
((${#FILES[@]} > 0)) || die "no compose.yaml found below ${SERVICES_DIR}"

for file in "${FILES[@]}"; do
    dir="$(dirname "${file}")"
    rel="${file#"${SERVICES_DIR}/"}"
    echo "== ${rel}"

    if grep -qE '(^|[^_])(POSTGRES_IMAGE|ODOO_IMAGE|BACKUP_IMAGE)=' "${dir}/.env.example" 2>/dev/null; then
        fail "${rel}: image override variable in .env.example"
    fi

    # effective config with the production image defaults
    json="$(env -u POSTGRES_IMAGE -u ODOO_IMAGE -u BACKUP_IMAGE \
        docker compose --env-file "${dir}/.env.example" -f "${file}" config --format json)"
    j() { jq -r "$@" <<<"${json}"; }

    if grep -qE '^name:[[:space:]]*[a-z0-9][a-z0-9_-]*[[:space:]]*$' "${file}"; then
        pass "fixed project name $(j '.name')"
    else
        fail "no top-level name:"
    fi

    # secret literals in the raw file
    while IFS= read -r line; do
        fail "secret literal: ${line}"
    done < <(grep -nE '^[[:space:]]*-?[[:space:]]*[A-Z0-9_]*(PASSWORD|SECRET|KEY)[A-Z0-9_]*[[:space:]]*[:=]' "${file}" |
        grep -vE '[:=][[:space:]]*"?\$\{' || true)

    for net in db-net ingress-net; do
        if [[ "$(j --arg n "${net}" '.networks | has($n)')" == "true" ]]; then
            assert_eq "network ${net} external" "true" "$(j --arg n "${net}" '.networks[$n].external // false')"
            assert_eq "network ${net} name" "${net}" "$(j --arg n "${net}" '.networks[$n].name')"
        fi
    done

    for svc in $(j '.services | keys[]'); do
        s() { j --arg s "${svc}" "$@"; }
        nets="$(s '.services[$s].networks // {} | keys | join(",")')"
        ports="$(s '[.services[$s].ports // [] | .[] | "\(.host_ip // ""):\(.published):\(.target)"] | sort | join(",")')"

        assert_eq "${svc}: no container_name" "" "$(s '.services[$s].container_name // ""')"
        if [[ "${RESTART_SERVICES}" == *" ${svc} "* ]]; then
            assert_eq "${svc}: restart policy" "unless-stopped" "$(s '.services[$s].restart // ""')"
        fi

        case "${svc}" in
            postgresql)
                assert_eq "postgresql: image default" "${PROD_POSTGRES_IMAGE}" "$(s '.services[$s].image')"
                assert_eq "postgresql: ports" "127.0.0.1:5432:5432" "${ports}"
                assert_eq "postgresql: networks" "db-net" "${nets}"
                assert_eq "postgresql: alias" "true" \
                    "$(s '.services[$s].networks["db-net"].aliases // [] | index("postgresql") != null')"
                ;;
            odoo)
                image="$(s '.services[$s].image')"
                if [[ "${image}" == "${PROD_ODOO_REPO}:"* ]]; then pass "odoo: image default ${image}"; else fail "odoo: image default ${image}"; fi
                assert_eq "odoo: ports" "" "${ports}"
                assert_eq "odoo: networks" "db-net,ingress-net" "${nets}"
                assert_eq "odoo: ingress alias" "true" \
                    "$(s --arg a "$(basename "${dir}")" '.services[$s].networks["ingress-net"].aliases // [] | index($a) != null')"
                ;;
            backup-service)
                assert_eq "backup-service: image default" "${PROD_BACKUP_IMAGE}" "$(s '.services[$s].image')"
                assert_eq "backup-service: ports" "" "${ports}"
                assert_eq "backup-service: networks" "db-net" "${nets}"
                ;;
            nginx)
                assert_eq "nginx: ports" ":443:443,:80:80" "${ports}"
                assert_eq "nginx: networks" "ingress-net" "${nets}"
                image="$(s '.services[$s].image')"
                tag="${image##*:}"
                if [[ "${image}" != *:* || "${tag}" == "latest" ]]; then
                    fail "nginx: image ${image} not pinned"
                elif printf '%s\n%s\n' "1.27.3" "${tag}" | sort -V -C; then
                    pass "nginx: image ${image} pinned (>= 1.27.3)"
                else
                    fail "nginx: image ${image} older than 1.27.3"
                fi
                ;;
            certbot)
                assert_eq "certbot: ports" "" "${ports}"
                if [[ ",${nets}," == *",db-net,"* || ",${nets}," == *",ingress-net,"* ]]; then
                    fail "certbot: must not join db-net/ingress-net (${nets})"
                else
                    pass "certbot: networks ${nets:-default}"
                fi
                ;;
            *)
                assert_eq "${svc}: no published ports" "" "${ports}"
                ;;
        esac
    done
done

finish
