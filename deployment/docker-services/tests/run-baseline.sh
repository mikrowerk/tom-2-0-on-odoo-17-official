#!/usr/bin/env bash
# Regression baseline of the monolithic setup (plan step 2), reproducible at any time:
#   1. parity invariants of the monolithic compose file are green
#   2. the production nginx config (nginx-conf/, without the copy & paste remainder "root@u" at the
#      end of options-ssl-nginx.conf) passes nginx -t
# The monolith lives in the repo root until it is moved to archive/ (plan step 12).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

if [[ -f "${REPO_ROOT}/archive/docker-compose.yaml" ]]; then
    LEGACY="${REPO_ROOT}/archive"
else
    LEGACY="${REPO_ROOT}"
fi

"${TESTS_DIR}/test-compose-parity.sh" --monolith "${LEGACY}/docker-compose.yaml"

WORK="$(make_tmp baseline)"
trap 'rm -rf "${WORK}"' EXIT
cp -R "${LEGACY}/nginx-conf/." "${WORK}/"
# the versioned copy ends with a shell prompt remainder that does not exist on the VPS
sed -E 's/;root@u$/;/' "${LEGACY}/nginx-conf/options-ssl-nginx.conf" >"${WORK}/options-ssl-nginx.conf"
"${TESTS_DIR}/test-nginx-config.sh" "${WORK}" --add-host odoo
