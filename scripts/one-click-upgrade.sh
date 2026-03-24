#!/bin/sh

set -eu

ENV_FILE="${GITHUB_RELEASE_ENV_FILE:-/etc/remnanode/github-release.env}"

if [ -f "${ENV_FILE}" ]; then
    set -a
    . "${ENV_FILE}"
    set +a
fi

REPO_SLUG="${1:-${REPO_SLUG:-x-socks/remnanode-lite}}"
RUNTIME_ASSET_NAME="${RUNTIME_ASSET_NAME:-remnanode-runtime-latest.tar.gz}"
BASE_DIR="${BASE_DIR:-/opt/remnanode}"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "this script must run as root" >&2
        exit 1
    fi
}

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

install_runtime_bundle() {
    bundle_path="$1"
    releases_dir="${BASE_DIR}/releases"
    current_link="${BASE_DIR}/current"

    if [ ! -f "${bundle_path}" ]; then
        echo "bundle not found: ${bundle_path}" >&2
        exit 1
    fi

    mkdir -p "${releases_dir}"

    install_dir="${WORK_DIR}/install-runtime"
    rm -rf "${install_dir}"
    mkdir -p "${install_dir}"

    tar -C "${install_dir}" -xzf "${bundle_path}"

    if [ ! -d "${install_dir}/runtime" ]; then
        echo "bundle missing runtime directory" >&2
        exit 1
    fi

    stamp="$(date +%Y%m%d-%H%M%S)-$$"
    release_dir="${releases_dir}/${stamp}"

    mv "${install_dir}/runtime" "${release_dir}"

    if [ -f "${install_dir}/manifest.txt" ]; then
        cp "${install_dir}/manifest.txt" "${release_dir}/.bundle-manifest"
    fi

    ln -sfn "${release_dir}" "${current_link}"

    printf '%s\n' "installed release ${release_dir}"
    printf '%s\n' "updated current -> ${release_dir}"
}

check_layout() {
    app_dir="${BASE_DIR}/current"
    status=0

    check_path() {
        path="$1"
        label="$2"

        if [ -e "${path}" ]; then
            printf 'ok   %s %s\n' "${label}" "${path}"
        else
            printf 'miss %s %s\n' "${label}" "${path}" >&2
            status=1
        fi
    }

    check_path "${app_dir}" dir
    check_path "${app_dir}/dist" dir
    check_path "${app_dir}/node_modules" dir
    check_path "${app_dir}/package.json" file

    if [ -f "${app_dir}/dist/src/main.js" ]; then
        printf 'ok   file %s\n' "${app_dir}/dist/src/main.js"
    elif [ -f "${app_dir}/dist/src/main" ]; then
        printf 'ok   file %s\n' "${app_dir}/dist/src/main"
    else
        printf 'miss file %s\n' "${app_dir}/dist/src/main(.js)" >&2
        status=1
    fi

    return "${status}"
}

require_root
require_cmd tar
require_cmd date
require_cmd cp
require_cmd mv
require_cmd ln
require_cmd rc-service

WORK_ROOT="${HOME:-/root}/.remnanode-work"
WORK_DIR="${WORK_ROOT}/one-click-upgrade.$$"
mkdir -p "${WORK_ROOT}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

cleanup() {
    rm -rf "${WORK_DIR}"
}

trap cleanup EXIT INT TERM

runtime_bundle="${WORK_DIR}/${RUNTIME_ASSET_NAME}"
runtime_url="https://github.com/${REPO_SLUG}/releases/latest/download/${RUNTIME_ASSET_NAME}"

printf '%s\n' "downloading ${runtime_url}"
download_file "${runtime_url}" "${runtime_bundle}"

install_runtime_bundle "${runtime_bundle}"
check_layout

printf '%s\n' "restarting remnanode"
rc-service remnanode restart
sleep 3

printf '%s\n' "===== service status ====="
rc-service remnanode status || true
printf '%s\n' "===== /var/log/remnanode/remnanode.log ====="
tail -n 40 /var/log/remnanode/remnanode.log || true
printf '%s\n' "===== /var/log/remnanode/remnanode.err ====="
tail -n 40 /var/log/remnanode/remnanode.err || true
