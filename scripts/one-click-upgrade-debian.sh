#!/bin/sh

set -eu

ENV_FILE="${GITHUB_RELEASE_ENV_FILE:-/etc/remnanode/github-release.env}"

if [ -f "${ENV_FILE}" ]; then
    set -a
    . "${ENV_FILE}"
    set +a
fi

REPO_SLUG="${1:-${REPO_SLUG:-x-socks/remnanode-lite}}"
RUNTIME_VERSION_INPUT="${2:-${RUNTIME_VERSION:-}}"
RUNTIME_ASSET_NAME="${RUNTIME_ASSET_NAME:-}"
RUNTIME_RELEASE_TAG="${RUNTIME_RELEASE_TAG:-}"
BASE_DIR="${BASE_DIR:-/opt/remnanode}"
REMNANODE_ENV_FILE="${REMNANODE_ENV_FILE:-/etc/remnanode/remnanode.env}"

if [ -f "${REMNANODE_ENV_FILE}" ]; then
    set -a
    . "${REMNANODE_ENV_FILE}"
    set +a
fi

INTERNAL_REST_TOKEN="${INTERNAL_REST_TOKEN:-}"
INTERNAL_SOCKET_PATH="${INTERNAL_SOCKET_PATH:-/run/remnanode-internal.sock}"
XRAY_START_TIMEOUT="${XRAY_START_TIMEOUT:-20}"
SUPERVISORD_USER="${SUPERVISORD_USER:-}"
SUPERVISORD_PASSWORD="${SUPERVISORD_PASSWORD:-}"
SUPERVISORD_SOCKET_PATH="${SUPERVISORD_SOCKET_PATH:-/run/supervisord.sock}"
SUPERVISORD_PID_PATH="${SUPERVISORD_PID_PATH:-/run/supervisord.pid}"

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

prompt_with_default() {
    prompt_text="$1"
    current_value="$2"
    default_value="$3"

    if [ -n "${current_value}" ]; then
        printf '%s\n' "${current_value}"
        return 0
    fi

    if [ ! -t 0 ]; then
        printf '%s\n' "${default_value}"
        return 0
    fi

    printf '%s' "${prompt_text}" >&2
    IFS= read -r input_value || true
    if [ -n "${input_value}" ]; then
        printf '%s\n' "${input_value}"
        return 0
    fi

    printf '%s\n' "${default_value}"
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

normalize_runtime_version() {
    case "$1" in
        ""|latest|LATEST)
            printf '%s\n' latest
            ;;
        v[0-9]*)
            printf '%s\n' "${1#v}"
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

infer_runtime_version_from_asset_name() {
    case "$1" in
        remnanode-runtime-latest.tar.gz)
            printf '%s\n' latest
            ;;
        remnanode-runtime-*.tar.gz)
            asset_version="${1#remnanode-runtime-}"
            printf '%s\n' "${asset_version%.tar.gz}"
            ;;
        *)
            printf '%s\n' ""
            ;;
    esac
}

resolve_runtime_version() {
    version_input="$1"
    asset_name="$2"

    if [ -n "${version_input}" ]; then
        normalize_runtime_version "${version_input}"
        return 0
    fi

    inferred_version="$(infer_runtime_version_from_asset_name "${asset_name}")"
    if [ -n "${inferred_version}" ]; then
        normalize_runtime_version "${inferred_version}"
        return 0
    fi

    printf '%s\n' latest
}

resolve_runtime_asset_name() {
    runtime_version="$1"
    configured_asset_name="$2"
    version_input="$3"

    if [ -n "${configured_asset_name}" ] && [ -z "${version_input}" ]; then
        printf '%s\n' "${configured_asset_name}"
        return 0
    fi

    if [ "${runtime_version}" = "latest" ]; then
        printf '%s\n' remnanode-runtime-latest.tar.gz
    else
        printf 'remnanode-runtime-%s.tar.gz\n' "${runtime_version}"
    fi
}

resolve_runtime_release_tag() {
    runtime_version="$1"
    configured_release_tag="$2"

    if [ -n "${configured_release_tag}" ]; then
        printf '%s\n' "${configured_release_tag}"
        return 0
    fi

    if [ "${runtime_version}" = "latest" ]; then
        printf '%s\n' ""
    else
        printf 'runtime-%s\n' "${runtime_version}"
    fi
}

build_runtime_download_url() {
    repo_slug="$1"
    runtime_version="$2"
    asset_name="$3"
    release_tag="$4"

    if [ "${runtime_version}" = "latest" ]; then
        printf 'https://github.com/%s/releases/latest/download/%s\n' "${repo_slug}" "${asset_name}"
    else
        printf 'https://github.com/%s/releases/download/%s/%s\n' "${repo_slug}" "${release_tag}" "${asset_name}"
    fi
}

generate_random() {
    length="${1:-64}"
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "${length}"
}

ensure_apt_prereqs() {
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "apt-get is required on Debian hosts" >&2
        exit 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl tar unzip xz-utils supervisor procps
}

ensure_supervisord_cmd() {
    if command -v supervisord >/dev/null 2>&1; then
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends supervisor

    if command -v supervisord >/dev/null 2>&1; then
        return 0
    fi

    echo "supervisor package installed but supervisord is still missing from PATH" >&2
    exit 1
}

install_node_24() {
    node_version="$(node -v 2>/dev/null || true)"
    node_major="$(printf '%s' "${node_version}" | sed 's/^v//' | cut -d. -f1)"

    case "${node_major}" in
        ''|*[!0-9]*)
            node_major=0
            ;;
    esac

    if [ "${node_major}" -ge 24 ]; then
        return 0
    fi

    arch="$(uname -m)"
    case "${arch}" in
        x86_64)
            node_arch="x64"
            ;;
        aarch64)
            node_arch="arm64"
            ;;
        armv7l|armv6l|armhf)
            node_arch="armv7l"
            ;;
        *)
            echo "unsupported arch for Node.js 24 install: ${arch}" >&2
            exit 1
            ;;
    esac

    shasums_path="${WORK_DIR}/node-shasums.txt"
    download_file "https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt" "${shasums_path}"
    node_archive="$(awk "/linux-${node_arch}\\.tar\\.xz$/ { print \$2; exit }" "${shasums_path}")"

    if [ -z "${node_archive}" ]; then
        echo "unable to resolve a Node.js 24 archive for arch ${node_arch}" >&2
        exit 1
    fi

    archive_path="${WORK_DIR}/${node_archive}"
    node_dir="${node_archive%.tar.xz}"
    install_root="/usr/local/lib/${node_dir}"

    download_file "https://nodejs.org/dist/latest-v24.x/${node_archive}" "${archive_path}"
    rm -rf "${WORK_DIR}/node-install" "${install_root}"
    mkdir -p "${WORK_DIR}/node-install" /usr/local/lib
    tar -C "${WORK_DIR}/node-install" -xJf "${archive_path}"
    mv "${WORK_DIR}/node-install/${node_dir}" "${install_root}"

    ln -sf "${install_root}/bin/node" /usr/local/bin/node
    if [ -x "${install_root}/bin/npm" ]; then
        ln -sf "${install_root}/bin/npm" /usr/local/bin/npm
    fi
    if [ -x "${install_root}/bin/npx" ]; then
        ln -sf "${install_root}/bin/npx" /usr/local/bin/npx
    fi
    if [ -x "${install_root}/bin/corepack" ]; then
        ln -sf "${install_root}/bin/corepack" /usr/local/bin/corepack
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

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

update_key_value_file() {
    file_path="$1"
    key_name="$2"
    value="$3"
    temp_file="${WORK_DIR}/$(basename "${file_path}").tmp"
    quoted_value="$(shell_quote "${value}")"

    if [ -f "${file_path}" ]; then
        grep -v "^${key_name}=" "${file_path}" > "${temp_file}" || true
    else
        : > "${temp_file}"
    fi

    printf '%s=%s\n' "${key_name}" "${quoted_value}" >> "${temp_file}"
    mv "${temp_file}" "${file_path}"
    chown root:root "${file_path}" 2>/dev/null || true
    chmod 600 "${file_path}" 2>/dev/null || true
}

ensure_layout() {
    mkdir -p /etc/remnanode
    mkdir -p /etc/xray
    mkdir -p /usr/local/bin
    mkdir -p /usr/local/share/xray
    mkdir -p /var/log/remnanode
    mkdir -p /var/log/supervisor
    mkdir -p /etc/systemd/system
    mkdir -p "${BASE_DIR}/releases"
    : > /var/log/remnanode/xray.log
    : > /var/log/remnanode/xray.err
    chmod 644 /var/log/remnanode/xray.log /var/log/remnanode/xray.err 2>/dev/null || true
    chmod 700 /etc/remnanode 2>/dev/null || true
}

install_remnanode_service() {
    rm -f /etc/init.d/remnanode /etc/conf.d/remnanode

    cat > /etc/systemd/system/remnanode.service <<'EOF'
[Unit]
Description=Remnanode bare-metal service
After=network-online.target local-fs.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/remnanode/current
ExecStart=/usr/local/bin/remnanode-start
Restart=always
RestartSec=5
LimitNOFILE=65535
KillMode=control-group
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 /etc/systemd/system/remnanode.service
}

install_supervisord_config() {
    cat > /etc/supervisord.conf <<EOF
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=${SUPERVISORD_PID_PATH}
childlogdir=/var/log/supervisor
logfile_maxbytes=1MB
logfile_backups=0
loglevel=warn
silent=true

[unix_http_server]
file=${SUPERVISORD_SOCKET_PATH}
username=${SUPERVISORD_USER}
password=${SUPERVISORD_PASSWORD}

[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://${SUPERVISORD_SOCKET_PATH}
username=${SUPERVISORD_USER}
password=${SUPERVISORD_PASSWORD}

[program:xray]
command=/usr/local/bin/rw-core -config http+unix://${INTERNAL_SOCKET_PATH}/internal/get-config?token=${INTERNAL_REST_TOKEN} -format json
autostart=false
autorestart=false
stderr_logfile=/var/log/remnanode/xray.err
stdout_logfile=/var/log/remnanode/xray.log
stdout_logfile_maxbytes=1MB
stderr_logfile_maxbytes=1MB
stdout_logfile_backups=0
stderr_logfile_backups=0
EOF
    chmod 644 /etc/supervisord.conf
}

cleanup_legacy_xray_sidecar() {
    systemctl disable --now remnanode-xray.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/remnanode-xray.service
    rm -f /etc/init.d/remnanode-xray
    rm -f /etc/conf.d/remnanode-xray
    rm -f /usr/local/bin/remnanode-xray-start
    rm -f /run/remnanode-xray.pid
}

disable_system_supervisor_service() {
    if [ -f /lib/systemd/system/supervisor.service ] || [ -f /usr/lib/systemd/system/supervisor.service ] || [ -f /etc/systemd/system/supervisor.service ]; then
        systemctl stop supervisor.service >/dev/null 2>&1 || true
        systemctl disable supervisor.service >/dev/null 2>&1 || true
    fi
}

install_remnanode_start() {
    cat > /usr/local/bin/remnanode-start <<'EOF'
#!/bin/sh

set -eu

ENV_FILE="${REMNANODE_ENV_FILE:-/etc/remnanode/remnanode.env}"

if [ -f "${ENV_FILE}" ]; then
    set -a
    . "${ENV_FILE}"
    set +a
fi

APP_DIR="${REMNANODE_APP_DIR:-/opt/remnanode/current}"
ENTRYPOINT="${REMNANODE_ENTRYPOINT:-dist/src/main.js}"
NODE_BIN="${NODE_BIN:-node}"
NOFILE_LIMIT="${REMNANODE_ULIMIT_NOFILE:-65535}"

: "${NODE_PORT:?NODE_PORT is required}"
: "${SECRET_KEY:?SECRET_KEY is required}"
: "${INTERNAL_REST_TOKEN:?INTERNAL_REST_TOKEN is required}"
: "${SUPERVISORD_USER:?SUPERVISORD_USER is required}"
: "${SUPERVISORD_PASSWORD:?SUPERVISORD_PASSWORD is required}"
: "${XTLS_API_PORT:=61000}"
INTERNAL_SOCKET_PATH="${INTERNAL_SOCKET_PATH:-/run/remnanode-internal.sock}"
SUPERVISORD_SOCKET_PATH="${SUPERVISORD_SOCKET_PATH:-/run/supervisord.sock}"
SUPERVISORD_PID_PATH="${SUPERVISORD_PID_PATH:-/run/supervisord.pid}"

export NODE_PORT SECRET_KEY XTLS_API_PORT
export INTERNAL_REST_TOKEN INTERNAL_SOCKET_PATH
export SUPERVISORD_USER SUPERVISORD_PASSWORD SUPERVISORD_SOCKET_PATH SUPERVISORD_PID_PATH

if [ ! -d "${APP_DIR}" ]; then
    echo "remnanode-start: missing app dir: ${APP_DIR}" >&2
    exit 1
fi

if [ -f "${APP_DIR}/${ENTRYPOINT}" ]; then
    MAIN_FILE="${APP_DIR}/${ENTRYPOINT}"
elif [ -f "${APP_DIR}/${ENTRYPOINT}.js" ]; then
    MAIN_FILE="${APP_DIR}/${ENTRYPOINT}.js"
else
    echo "remnanode-start: missing entrypoint: ${APP_DIR}/${ENTRYPOINT}" >&2
    exit 1
fi

ulimit -n "${NOFILE_LIMIT}" 2>/dev/null || true

export NODE_ENV="${REMNANODE_ENV:-production}"
export NODE_OPTIONS="${NODE_OPTIONS:---max-http-header-size=32768 --max-old-space-size=48 --max-semi-space-size=1}"
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-1}"
export UV_THREADPOOL_SIZE="${UV_THREADPOOL_SIZE:-1}"
export XRAY_CORE_VERSION="$([ -x /usr/local/bin/rw-core ] && /usr/local/bin/rw-core version | head -n 1 || true)"

cleanup_stale_node_processes() {
    stale_pids="$(ps -o pid,args | awk -v main_file="${MAIN_FILE}" '$1 ~ /^[0-9]+$/ && index($0, "node " main_file) > 0 { print $1 }')"

    if [ -n "${stale_pids}" ]; then
        printf '%s\n' "remnanode-start: stopping stale node processes for ${MAIN_FILE}" >&2
        for pid in ${stale_pids}; do
            kill "${pid}" 2>/dev/null || true
        done
        sleep 1
        for pid in ${stale_pids}; do
            kill -9 "${pid}" 2>/dev/null || true
        done
    fi
}

cleanup_stale_node_processes
rm -f "${INTERNAL_SOCKET_PATH}" "${SUPERVISORD_SOCKET_PATH}" "${SUPERVISORD_PID_PATH}" 2>/dev/null || true
pkill -x supervisord 2>/dev/null || true
pkill -x xray 2>/dev/null || true
pkill -x rw-core 2>/dev/null || true

if command -v supervisord >/dev/null 2>&1; then
    supervisord -c /etc/supervisord.conf &
    wait_seconds="${SUPERVISORD_START_TIMEOUT:-10}"
    while [ "${wait_seconds}" -gt 0 ]; do
        if [ -S "${SUPERVISORD_SOCKET_PATH}" ]; then
            break
        fi
        sleep 1
        wait_seconds=$((wait_seconds - 1))
    done

    if [ ! -S "${SUPERVISORD_SOCKET_PATH}" ]; then
        echo "remnanode-start: supervisord socket not ready: ${SUPERVISORD_SOCKET_PATH}" >&2
        exit 1
    fi
fi

cd "${APP_DIR}"
exec "${NODE_BIN}" "${MAIN_FILE}"
EOF
    chmod 755 /usr/local/bin/remnanode-start
}

refresh_host_runtime() {
    current_node_options="${NODE_OPTIONS:-}"
    current_malloc_arena_max="${MALLOC_ARENA_MAX:-}"

    ensure_apt_prereqs
    ensure_supervisord_cmd
    install_node_24
    install_xray
    ensure_layout
    cleanup_legacy_xray_sidecar
    install_remnanode_service

    if [ -z "${INTERNAL_REST_TOKEN}" ]; then
        INTERNAL_REST_TOKEN="$(generate_random 64)"
    fi
    if [ -z "${SUPERVISORD_USER}" ]; then
        SUPERVISORD_USER="$(generate_random 32)"
    fi
    if [ -z "${SUPERVISORD_PASSWORD}" ]; then
        SUPERVISORD_PASSWORD="$(generate_random 64)"
    fi

    install_supervisord_config
    install_remnanode_start
    disable_system_supervisor_service

    update_key_value_file "${REMNANODE_ENV_FILE}" INTERNAL_REST_TOKEN "${INTERNAL_REST_TOKEN}"
    update_key_value_file "${REMNANODE_ENV_FILE}" INTERNAL_SOCKET_PATH "${INTERNAL_SOCKET_PATH}"
    update_key_value_file "${REMNANODE_ENV_FILE}" XRAY_START_TIMEOUT "${XRAY_START_TIMEOUT}"
    update_key_value_file "${REMNANODE_ENV_FILE}" SUPERVISORD_USER "${SUPERVISORD_USER}"
    update_key_value_file "${REMNANODE_ENV_FILE}" SUPERVISORD_PASSWORD "${SUPERVISORD_PASSWORD}"
    update_key_value_file "${REMNANODE_ENV_FILE}" SUPERVISORD_SOCKET_PATH "${SUPERVISORD_SOCKET_PATH}"
    update_key_value_file "${REMNANODE_ENV_FILE}" SUPERVISORD_PID_PATH "${SUPERVISORD_PID_PATH}"
    update_key_value_file "${REMNANODE_ENV_FILE}" XRAY_BIN /usr/local/bin/xray
    update_key_value_file "${REMNANODE_ENV_FILE}" XRAY_CONFIG /etc/xray/config.json
    update_key_value_file "${REMNANODE_ENV_FILE}" XRAY_ASSET_DIR /usr/local/share/xray

    if [ -z "${current_node_options}" ] || [ "${current_node_options}" = "--max-http-header-size=65536 --max-old-space-size=64 --max-semi-space-size=1" ]; then
        update_key_value_file "${REMNANODE_ENV_FILE}" NODE_OPTIONS "--max-http-header-size=32768 --max-old-space-size=48 --max-semi-space-size=1"
    fi

    if [ -z "${current_malloc_arena_max}" ] || [ "${current_malloc_arena_max}" = "2" ]; then
        update_key_value_file "${REMNANODE_ENV_FILE}" MALLOC_ARENA_MAX 1
    fi

    update_key_value_file "${REMNANODE_ENV_FILE}" UV_THREADPOOL_SIZE 1
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
require_cmd install
require_cmd pkill
require_cmd systemctl
require_cmd journalctl

RUNTIME_VERSION="$(prompt_with_default 'RUNTIME_VERSION [latest]: ' "${RUNTIME_VERSION_INPUT}" latest)"
RUNTIME_VERSION="$(resolve_runtime_version "${RUNTIME_VERSION}" "${RUNTIME_ASSET_NAME}")"
RUNTIME_ASSET_NAME="$(resolve_runtime_asset_name "${RUNTIME_VERSION}" "${RUNTIME_ASSET_NAME}" "${RUNTIME_VERSION_INPUT}")"
RUNTIME_RELEASE_TAG="$(resolve_runtime_release_tag "${RUNTIME_VERSION}" "${RUNTIME_RELEASE_TAG}")"

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
runtime_url="$(build_runtime_download_url "${REPO_SLUG}" "${RUNTIME_VERSION}" "${RUNTIME_ASSET_NAME}" "${RUNTIME_RELEASE_TAG}")"

printf '%s\n' "downloading ${runtime_url}"
download_file "${runtime_url}" "${runtime_bundle}"

refresh_host_runtime
require_cmd node
ensure_supervisord_cmd
require_cmd supervisord
require_node_24
install_runtime_bundle "${runtime_bundle}"
check_layout
update_key_value_file "${ENV_FILE}" RUNTIME_VERSION "${RUNTIME_VERSION}"
update_key_value_file "${ENV_FILE}" RUNTIME_ASSET_NAME "${RUNTIME_ASSET_NAME}"
update_key_value_file "${ENV_FILE}" RUNTIME_RELEASE_TAG "${RUNTIME_RELEASE_TAG}"

if [ ! -f /etc/xray/config.json ] && [ -f /etc/xray/config.json.example ]; then
    cp /etc/xray/config.json.example /etc/xray/config.json
fi

chmod 644 /etc/xray/config.json 2>/dev/null || true

systemctl daemon-reload
systemctl enable remnanode.service >/dev/null

printf '%s\n' "restarting remnanode"
systemctl restart remnanode.service
sleep 3

printf '%s\n' "===== service status ====="
systemctl --no-pager status remnanode.service || true
printf '%s\n' "===== /etc/supervisord.conf ====="
cat /etc/supervisord.conf || true
printf '%s\n' "===== journalctl -u remnanode ====="
journalctl --no-pager -u remnanode.service -n 40 || true
printf '%s\n' "===== /var/log/supervisor/supervisord.log ====="
tail -n 40 /var/log/supervisor/supervisord.log || true
printf '%s\n' "===== /var/log/remnanode/xray.log ====="
tail -n 40 /var/log/remnanode/xray.log || true
printf '%s\n' "===== /var/log/remnanode/xray.err ====="
tail -n 40 /var/log/remnanode/xray.err || true
