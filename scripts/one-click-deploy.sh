#!/bin/sh

set -eu

REPO_SLUG="${1:-${REPO_SLUG:-x-socks/remnanode-lite}}"
BASE_DIR="${BASE_DIR:-/opt/remnanode}"
HOST_TOOLS_ASSET_NAME="${HOST_TOOLS_ASSET_NAME:-remnanode-host-tools-latest.tar.gz}"
RUNTIME_ASSET_NAME="${RUNTIME_ASSET_NAME:-remnanode-runtime-latest.tar.gz}"
NODE_PORT="${NODE_PORT:-}"
SECRET_INPUT="${SECRET_INPUT:-${SECRET_KEY:-}}"

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

prompt_required() {
    prompt_text="$1"
    current_value="$2"

    if [ -n "${current_value}" ]; then
        printf '%s\n' "${current_value}"
        return 0
    fi

    while :; do
        printf '%s' "${prompt_text}" >&2
        IFS= read -r input_value
        if [ -n "${input_value}" ]; then
            printf '%s\n' "${input_value}"
            return 0
        fi
    done
}

normalize_secret_key() {
    input_value="$1"

    case "${input_value}" in
        SECRET_KEY=*)
            printf '%s\n' "${input_value#SECRET_KEY=}"
            ;;
        *)
            printf '%s\n' "${input_value}"
            ;;
    esac
}

ensure_apk_prereqs() {
    if command -v apk >/dev/null 2>&1; then
        apk add --upgrade curl tar nodejs gcompat unzip supervisor
    fi
}

require_node_24() {
    node_version="$(node -v 2>/dev/null || true)"
    node_major="$(printf '%s' "${node_version}" | sed 's/^v//' | cut -d. -f1)"

    case "${node_major}" in
        ''|*[!0-9]*)
            echo "unable to determine Node.js version" >&2
            exit 1
            ;;
    esac

    if [ "${node_major}" -lt 24 ]; then
        echo "Node.js 24 or newer is required; found ${node_version}" >&2
        exit 1
    fi
}

install_xray() {
    xray_path="$(command -v xray 2>/dev/null || true)"

    if [ -z "${xray_path}" ]; then
        arch="$(uname -m)"
        case "${arch}" in
            x86_64)
                xray_asset="Xray-linux-64.zip"
                ;;
            aarch64)
                xray_asset="Xray-linux-arm64-v8a.zip"
                ;;
            armv7*|armv6*|armhf)
                xray_asset="Xray-linux-arm32-v7a.zip"
                ;;
            *)
                echo "unsupported arch: ${arch}" >&2
                exit 1
                ;;
        esac

        download_file "https://github.com/XTLS/Xray-core/releases/latest/download/${xray_asset}" "${WORK_DIR}/xray.zip"
        mkdir -p "${WORK_DIR}/xray" /usr/local/bin /usr/local/share/xray
        unzip -o "${WORK_DIR}/xray.zip" -d "${WORK_DIR}/xray" >/dev/null
        install -m 0755 "${WORK_DIR}/xray/xray" /usr/local/bin/xray
        xray_path="/usr/local/bin/xray"

        if [ -f "${WORK_DIR}/xray/geoip.dat" ]; then
            install -m 0644 "${WORK_DIR}/xray/geoip.dat" /usr/local/share/xray/geoip.dat
        fi

        if [ -f "${WORK_DIR}/xray/geosite.dat" ]; then
            install -m 0644 "${WORK_DIR}/xray/geosite.dat" /usr/local/share/xray/geosite.dat
        fi
    fi

    if [ ! -e /usr/local/bin/xray ]; then
        mkdir -p /usr/local/bin
        ln -sf "${xray_path}" /usr/local/bin/xray
    fi

    ln -sf /usr/local/bin/xray /usr/local/bin/rw-core
}

update_key_value_file() {
    file_path="$1"
    key_name="$2"
    value="$3"
    temp_file="${WORK_DIR}/$(basename "${file_path}").tmp"

    if [ -f "${file_path}" ]; then
        grep -v "^${key_name}=" "${file_path}" > "${temp_file}" || true
    else
        : > "${temp_file}"
    fi

    printf '%s=%s\n' "${key_name}" "${value}" >> "${temp_file}"
    mv "${temp_file}" "${file_path}"
    if id remnanode >/dev/null 2>&1; then
        chown root:remnanode "${file_path}" 2>/dev/null || true
    fi
    chmod 640 "${file_path}" 2>/dev/null || true
}

require_root
ensure_apk_prereqs
require_cmd tar
require_cmd unzip
require_cmd install
require_cmd node
require_cmd supervisord
require_cmd rc-service
require_cmd rc-update
require_node_24

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/remnanode-one-click.XXXXXX")

cleanup() {
    rm -rf "${WORK_DIR}"
}

trap cleanup EXIT INT TERM

install_xray

NODE_PORT="$(prompt_required 'NODE_PORT (Node Port from panel): ' "${NODE_PORT}")"
SECRET_INPUT="$(prompt_required 'SECRET_KEY value or full line from panel: ' "${SECRET_INPUT}")"
SECRET_KEY="$(normalize_secret_key "${SECRET_INPUT}")"

case "${NODE_PORT}" in
    ''|*[!0-9]*)
        echo "NODE_PORT must be numeric" >&2
        exit 1
        ;;
esac

download_file "https://github.com/${REPO_SLUG}/releases/latest/download/${HOST_TOOLS_ASSET_NAME}" "${WORK_DIR}/${HOST_TOOLS_ASSET_NAME}"
download_file "https://github.com/${REPO_SLUG}/releases/latest/download/${RUNTIME_ASSET_NAME}" "${WORK_DIR}/${RUNTIME_ASSET_NAME}"

mkdir -p "${WORK_DIR}/host-tools"
tar -C "${WORK_DIR}/host-tools" -xzf "${WORK_DIR}/${HOST_TOOLS_ASSET_NAME}"
HOST_TOOLS_DIR="${WORK_DIR}/host-tools/remnanode-host-tools"

sh "${HOST_TOOLS_DIR}/scripts/bootstrap-host.sh" "${WORK_DIR}/${RUNTIME_ASSET_NAME}" "${BASE_DIR}"

update_key_value_file /etc/remnanode/remnanode.env NODE_PORT "${NODE_PORT}"
update_key_value_file /etc/remnanode/remnanode.env SECRET_KEY "${SECRET_KEY}"
update_key_value_file /etc/remnanode/remnanode.env XTLS_API_PORT 61000
update_key_value_file /etc/remnanode/github-release.env REPO_SLUG "${REPO_SLUG}"
update_key_value_file /etc/remnanode/github-release.env BASE_DIR "${BASE_DIR}"

if [ ! -f /etc/xray/config.json ] && [ -f /etc/xray/config.json.example ]; then
    cp /etc/xray/config.json.example /etc/xray/config.json
fi

if [ ! -f /etc/supervisord.conf ] && [ -f "${HOST_TOOLS_DIR}/config/supervisor/supervisord.conf" ]; then
    cp "${HOST_TOOLS_DIR}/config/supervisor/supervisord.conf" /etc/supervisord.conf
fi

mkdir -p /var/log/supervisor

rc-update add remnanode default >/dev/null 2>&1 || true

if rc-service remnanode status >/dev/null 2>&1; then
    rc-service remnanode restart
else
    rc-service remnanode start
fi

sleep 3
rc-service remnanode status || true
printf '%s\n' "===== /etc/remnanode/remnanode.env ====="
cat /etc/remnanode/remnanode.env
printf '%s\n' "===== /var/log/remnanode/remnanode.log ====="
tail -n 50 /var/log/remnanode/remnanode.log || true
printf '%s\n' "===== /var/log/remnanode/remnanode.err ====="
tail -n 50 /var/log/remnanode/remnanode.err || true
