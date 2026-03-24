#!/bin/sh

set -eu

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <repo-slug> [base-dir]" >&2
    exit 1
fi

REPO_SLUG="$1"
BASE_DIR="${2:-/opt/remnanode}"
RUNTIME_ASSET_NAME="${RUNTIME_ASSET_NAME:-remnanode-runtime-latest.tar.gz}"
HOST_TOOLS_ASSET_NAME="${HOST_TOOLS_ASSET_NAME:-remnanode-host-tools-latest.tar.gz}"

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

host_tools_bundle="${WORK_DIR}/${HOST_TOOLS_ASSET_NAME}"
runtime_bundle="${WORK_DIR}/${RUNTIME_ASSET_NAME}"

download_file "https://github.com/${REPO_SLUG}/releases/latest/download/${HOST_TOOLS_ASSET_NAME}" "${host_tools_bundle}"
download_file "https://github.com/${REPO_SLUG}/releases/latest/download/${RUNTIME_ASSET_NAME}" "${runtime_bundle}"

tar -C "${WORK_DIR}" -xzf "${host_tools_bundle}"
sh "${WORK_DIR}/remnanode-host-tools/scripts/bootstrap-host.sh" "${runtime_bundle}" "${BASE_DIR}"
