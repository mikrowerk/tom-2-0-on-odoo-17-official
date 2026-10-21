#!/usr/bin/env bash
# T2: smoke test of the built image: platform, Ghostscript, Odoo version, Python packages.
#   tests/image/smoke.sh <image>
# EXPECTED_ARCH (amd64|arm64) checks the image platform, e.g. per CI runner;
# EXPECTED_GS_VERSION overrides the version taken from the Dockerfile (ARG GS_VERSION).
source "$(dirname "$0")/lib.sh"
require_image "${1:-}"
info "T2 smoke: ${IMAGE}"

image_arch="$(docker image inspect --format '{{.Architecture}}' "${IMAGE}")"
if [[ -n "${EXPECTED_ARCH:-}" ]]; then
    check "image architecture ${image_arch}" "image architecture ${image_arch}, expected ${EXPECTED_ARCH}" \
        test "${image_arch}" = "${EXPECTED_ARCH}"
fi
case "${image_arch}" in
    amd64) machine=x86_64 ;;
    arm64) machine=aarch64 ;;
    *)     machine="${image_arch}" ;;
esac
actual_machine="$(in_image 'uname -m')"
check "uname -m ${actual_machine}" "uname -m ${actual_machine}, expected ${machine}" \
    test "${actual_machine}" = "${machine}"

gs_expected="${EXPECTED_GS_VERSION:-$(sed -n 's/^ARG GS_VERSION=//p' "${REPO_DIR}/Dockerfile")}"
gs_actual="$(in_image 'gs --version' || true)"
check "gs --version ${gs_actual}" "gs --version '${gs_actual}', expected '${gs_expected:-?}'" \
    test -n "${gs_expected}" -a "${gs_actual}" = "${gs_expected}"

odoo_version="$(in_image 'odoo --version' || true)"
check "odoo --version ${odoo_version}" "odoo --version '${odoo_version}', expected 'Odoo Server 17.0*'" \
    grep -q '^Odoo Server 17\.0' <<<"${odoo_version}"

# Import names of additional-requirements.txt (plus pycairo from python3-cairo)
modules="facturx pypdf lxml lxml_html_clean schwifty unidecode rlPyCairo cairo edi_invoice_parser google.genai
         thefuzz anyio email_bridge_client markdown openupgradelib OpenSSL cryptography"
for m in ${modules}; do
    if in_image "python3 -c 'import ${m}'" >/dev/null 2>&1; then
        ok "python import ${m}"
    else
        fail "python import ${m}"
    fi
done

if out="$(in_image 'pip3 check' 2>&1)"; then
    ok "pip3 check"
else
    fail "pip3 check: ${out}"
fi

finish
