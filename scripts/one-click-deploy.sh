#!/bin/sh

set -eu

REPO_SLUG="${1:-${REPO_SLUG:-x-socks/remnanode-lite}}"
REPO_REF="${REPO_REF:-main}"
WORK_DIR=""
RESOLVED_SCRIPT=""

cleanup() {
    if [ -n "${WORK_DIR}" ] && [ -d "${WORK_DIR}" ]; then
        rm -rf "${WORK_DIR}"
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

detect_platform() {
    if [ -f /etc/alpine-release ]; then
        printf '%s\n' alpine
        return 0
    fi

    if [ -f /etc/debian_version ] && command -v systemctl >/dev/null 2>&1; then
        printf '%s\n' debian
        return 0
    fi

    echo "unsupported host: expected Alpine or Debian with systemd" >&2
    exit 1
}

resolve_delegate_script() {
    target_script="$1"
    script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

    if [ -f "${script_dir}/${target_script}" ]; then
        RESOLVED_SCRIPT="${script_dir}/${target_script}"
        return 0
    fi

    work_root="${HOME:-/root}/.remnanode-work"
    WORK_DIR="${work_root}/dispatch.$$"
    mkdir -p "${work_root}"
    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}"
    trap cleanup EXIT INT TERM

    script_path="${WORK_DIR}/${target_script}"
    script_url="https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_REF}/scripts/${target_script}"

    printf '%s\n' "downloading ${script_url}" >&2
    download_file "${script_url}" "${script_path}"
    RESOLVED_SCRIPT="${script_path}"
}

platform="$(detect_platform)"
delegate_script="one-click-deploy-${platform}.sh"

printf '%s\n' "detected platform: ${platform}" >&2
resolve_delegate_script "${delegate_script}"

exec env REPO_REF="${REPO_REF}" sh "${RESOLVED_SCRIPT}" "$@"
