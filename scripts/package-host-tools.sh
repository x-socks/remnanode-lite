#!/bin/sh

set -eu

OUTPUT_DIR="${1:-./out}"
BUNDLE_STAMP="${BUNDLE_STAMP:-}"
BUNDLE_NAME="${BUNDLE_NAME:-}"
BUNDLE_PATH_FILE="${BUNDLE_PATH_FILE:-}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing command: $1" >&2
        exit 1
    fi
}

require_cmd cp
require_cmd tar
require_cmd mktemp
require_cmd date

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SELF_DIR}/.." && pwd)

STAMP="${BUNDLE_STAMP}"
if [ -z "${STAMP}" ]; then
    STAMP="$(date +%Y%m%d-%H%M%S)-$$"
fi

if [ -z "${BUNDLE_NAME}" ]; then
    BUNDLE_NAME="remnanode-host-tools-${STAMP}.tar.gz"
fi

mkdir -p "${OUTPUT_DIR}"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/remnanode-tools.XXXXXX")
STAGE_DIR="${WORK_DIR}/remnanode-host-tools"

cleanup() {
    rm -rf "${WORK_DIR}"
}

trap cleanup EXIT INT TERM

mkdir -p "${STAGE_DIR}"

copy_into_stage() {
    rel_path="$1"
    mkdir -p "${STAGE_DIR}/$(dirname "${rel_path}")"
    cp -R "${REPO_ROOT}/${rel_path}" "${STAGE_DIR}/${rel_path}"
}

copy_into_stage README.md
copy_into_stage docs
copy_into_stage deploy
copy_into_stage config
copy_into_stage scripts/install-layout.sh
copy_into_stage scripts/create-service-user.sh
copy_into_stage scripts/install-runtime-bundle.sh
copy_into_stage scripts/preflight-alpine.sh
copy_into_stage scripts/check-remnanode-layout.sh
copy_into_stage scripts/update-from-github-release.sh
copy_into_stage scripts/bootstrap-from-github-release.sh
copy_into_stage scripts/one-click-deploy.sh
copy_into_stage scripts/remnanode-start.sh
copy_into_stage scripts/xray-start.sh
copy_into_stage scripts/bootstrap-host.sh

tar -C "${WORK_DIR}" -czf "${OUTPUT_DIR}/${BUNDLE_NAME}" remnanode-host-tools

printf '%s\n' "wrote ${OUTPUT_DIR}/${BUNDLE_NAME}"

if [ -n "${BUNDLE_PATH_FILE}" ]; then
    printf '%s\n' "${OUTPUT_DIR}/${BUNDLE_NAME}" > "${BUNDLE_PATH_FILE}"
fi
