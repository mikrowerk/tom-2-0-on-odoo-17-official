#!/usr/bin/env bash
# Repo hygiene:
#   - .env files and generated DH parameters of the stacks are ignored by git, .env.example is not
#   - the Docker build context contains every COPY source of the Dockerfile, but not deployment/,
#     .features/ or archive/ (checked with a busybox probe image built from the real context)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd git docker

cd "${REPO_ROOT}"

echo "== git ignore rules"
for stack in database ingress odoo-griffity-prod odoo-griffity-prod/backup; do
    path="deployment/docker-services/${stack}/.env"
    if git check-ignore -q --no-index "${path}"; then pass "${path} ignored"; else fail "${path} not ignored"; fi
    path="deployment/docker-services/${stack}/.env.example"
    if git check-ignore -q --no-index "${path}"; then fail "${path} ignored"; else pass "${path} tracked"; fi
done
path="deployment/docker-services/ingress/conf.d/ssl-dhparams.pem"
if git check-ignore -q --no-index "${path}"; then pass "${path} ignored"; else fail "${path} not ignored"; fi
if git check-ignore -q --no-index "deployment/docker-services/tests/.tmp/x"; then
    pass "tests/.tmp ignored"
else
    fail "tests/.tmp not ignored"
fi

echo "== docker build context"
# COPY sources of the real Dockerfile (without --from stages and flags; the last argument is the target)
mapfile -t sources < <(awk '/^COPY / && !/--from=/ {
        n = 0
        for (i = 2; i < NF; i++) if ($i !~ /^--/) print $i
    }' Dockerfile)
((${#sources[@]} > 0)) || die "no COPY sources found in Dockerfile"

PROBE="tom-build-context-probe:$$"
trap 'docker image rm -f "${PROBE}" >/dev/null 2>&1 || true' EXIT
printf 'FROM busybox\nCOPY . /ctx\n' | docker build -q -t "${PROBE}" -f - . >/dev/null

# shellcheck disable=SC2016  # the script is evaluated inside the container
result="$(docker run --rm "${PROBE}" sh -c '
    for p in "$@"; do [ -e "/ctx/$p" ] && echo "present $p" || echo "missing $p"; done
' probe "${sources[@]}" deployment .features archive)"

for p in "${sources[@]}"; do
    if grep -qx "present ${p}" <<<"${result}"; then pass "context contains ${p}"; else fail "context lacks COPY source ${p}"; fi
done
for p in deployment .features archive; do
    if grep -qx "present ${p}" <<<"${result}"; then fail "context contains ${p}"; else pass "context excludes ${p}"; fi
done

finish
