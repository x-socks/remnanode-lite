#!/bin/sh

set -eu

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <repo-slug> [base-dir]" >&2
    exit 1
fi

REPO_SLUG="$1"
BASE_DIR="${2:-/opt/remnanode}"
RAW_REF="${RAW_REF:-main}"

download_file() {
    url="$1"
    out="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${url}" -o "${out}"
        return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -qO "${out}" "${url}"
        return 0
    fi

    echo "missing curl or wget" >&2
    exit 1
}

WORK_ROOT="${HOME:-/root}/.remnanode-work"
WORK_DIR="${WORK_ROOT}/bootstrap-release.$$"
mkdir -p "${WORK_ROOT}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

cleanup() {
    rm -rf "${WORK_DIR}"
}

trap cleanup EXIT INT TERM

bootstrap_script="${WORK_DIR}/one-click-deploy.sh"
download_file "https://raw.githubusercontent.com/${REPO_SLUG}/${RAW_REF}/scripts/one-click-deploy.sh" "${bootstrap_script}"

exec env BASE_DIR="${BASE_DIR}" sh "${bootstrap_script}" "${REPO_SLUG}"
