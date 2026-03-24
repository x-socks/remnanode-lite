#!/bin/sh

set -eu

ENV_FILE="${GITHUB_RELEASE_ENV_FILE:-/etc/remnanode/github-release.env}"

if [ -f "${ENV_FILE}" ]; then
    set -a
    . "${ENV_FILE}"
    set +a
fi

REPO_SLUG="${REPO_SLUG:-}"
RUNTIME_ASSET_NAME="${RUNTIME_ASSET_NAME:-remnanode-runtime-latest.tar.gz}"
HOST_TOOLS_ASSET_NAME="${HOST_TOOLS_ASSET_NAME:-remnanode-host-tools-latest.tar.gz}"
BASE_DIR="${BASE_DIR:-/opt/remnanode}"
UPDATE_HOST_TOOLS="${UPDATE_HOST_TOOLS:-0}"
RESTART_SERVICE="${RESTART_SERVICE:-0}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing command: $1" >&2
        exit 1
    fi
}

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

if [ -z "${REPO_SLUG}" ]; then
    echo "REPO_SLUG is required" >&2
    exit 1
fi

require_cmd mktemp
require_cmd tar
require_cmd sh

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/remnanode-release.XXXXXX")

cleanup() {
    rm -rf "${WORK_DIR}"
}

trap cleanup EXIT INT TERM

runtime_url="https://github.com/${REPO_SLUG}/releases/latest/download/${RUNTIME_ASSET_NAME}"
runtime_bundle="${WORK_DIR}/${RUNTIME_ASSET_NAME}"

download_file "${runtime_url}" "${runtime_bundle}"

if [ "${UPDATE_HOST_TOOLS}" = "1" ]; then
    host_tools_url="https://github.com/${REPO_SLUG}/releases/latest/download/${HOST_TOOLS_ASSET_NAME}"
    host_tools_bundle="${WORK_DIR}/${HOST_TOOLS_ASSET_NAME}"
    host_tools_dir="${WORK_DIR}/host-tools"

    download_file "${host_tools_url}" "${host_tools_bundle}"
    mkdir -p "${host_tools_dir}"
    tar -C "${host_tools_dir}" -xzf "${host_tools_bundle}"
    sh "${host_tools_dir}/remnanode-host-tools/scripts/install-layout.sh" /
fi

/usr/local/bin/install-remnanode-runtime "${runtime_bundle}" "${BASE_DIR}"
/usr/local/bin/check-remnanode-layout "${BASE_DIR}/current"

if [ "${RESTART_SERVICE}" = "1" ]; then
    rc-service remnanode restart
fi

printf '%s\n' "updated from https://github.com/${REPO_SLUG}/releases/latest"
