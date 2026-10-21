#!/usr/bin/env bash
# Runs T2-T4 against a local image; stops at the first failing test.
#   tests/image/run.sh <image>
set -euo pipefail
dir="$(dirname "$0")"
image="${1:?usage: run.sh <image>}"
"${dir}/smoke.sh" "${image}"
"${dir}/addons.sh" "${image}"
"${dir}/install.sh" "${image}"
