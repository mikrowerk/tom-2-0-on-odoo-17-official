#!/usr/bin/env bash
# Copyright Mikrowerk a Gammadata Business.
# SPDX-License-Identifier: AGPL-3
#
# Starts all stacks below this directory in dependency order:
#   setup.sh -> database (waits until healthy) -> odoo-* -> odoo-*/backup -> ingress
#
#   start-all-services.sh [--root <dir>] [--dry-run]
#
# --dry-run only prints the commands. Each stack is started with `docker compose up -d` in its
# own directory, so its .env is used. A paused backup (docker compose stop in odoo-*/backup) is
# started again by this script - do not run it in the middle of an Odoo update.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN=0
DB_WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-180}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { echo "--root needs a directory" >&2; exit 2; }
            ROOT="$(cd "$2" && pwd)"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h | --help)
            sed -n '4,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

run() {
    echo "+ $*"
    ((DRY_RUN == 1)) || "$@"
}

# up <stack-dir> [extra args for `up`]
up() {
    local dir="$1"
    shift
    echo "== ${dir#"${ROOT}/"}"
    run docker compose --project-directory "${dir}" -f "${dir}/compose.yaml" up -d "$@"
}

run "$(dirname "$0")/setup.sh" --root "${ROOT}"

[[ -f "${ROOT}/database/compose.yaml" ]] || { echo "database/compose.yaml missing" >&2; exit 1; }
up "${ROOT}/database" --wait --wait-timeout "${DB_WAIT_TIMEOUT}"

odoo_stacks=()
for compose in "${ROOT}"/odoo-*/compose.yaml; do
    [[ -f "${compose}" ]] && odoo_stacks+=("$(dirname "${compose}")")
done

for dir in ${odoo_stacks[@]+"${odoo_stacks[@]}"}; do
    up "${dir}"
done
for dir in ${odoo_stacks[@]+"${odoo_stacks[@]}"}; do
    [[ -f "${dir}/backup/compose.yaml" ]] && up "${dir}/backup"
done

[[ -f "${ROOT}/ingress/compose.yaml" ]] && up "${ROOT}/ingress"
echo "all stacks started"
