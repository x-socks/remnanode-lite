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

print_intro() {
    cat >&2 <<'EOF'
Remnanode one-click install

This installer will:
- install or verify Node.js 24, supervisor, gcompat, unzip, tar, and Xray
- download the latest host-tools and runtime bundles from GitHub Releases
- install the bare-metal layout under /opt/remnanode
- write /etc/remnanode/remnanode.env
- enable and start the OpenRC remnanode service

You will be prompted for:
- NODE_PORT: the Node Port configured in the Remnawave panel
- SECRET_KEY: the full secret payload from the panel

Accepted SECRET_KEY input:
- the raw secret value
- a full SECRET_KEY=... line
EOF
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

install_supervisord_config() {
    cat > /etc/supervisord.conf <<'EOF'
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=%(ENV_SUPERVISORD_PID_PATH)s
childlogdir=/var/log/supervisor
logfile_maxbytes=5MB
logfile_backups=2
loglevel=info
silent=true

[unix_http_server]
file=%(ENV_SUPERVISORD_SOCKET_PATH)s
username=%(ENV_SUPERVISORD_USER)s
password=%(ENV_SUPERVISORD_PASSWORD)s

[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface

[program:xray]
command=/usr/local/bin/rw-core -config http+unix://%(ENV_INTERNAL_SOCKET_PATH)s/internal/get-config?token=%(ENV_INTERNAL_REST_TOKEN)s -format json
autostart=false
autorestart=false
stderr_logfile=/var/log/supervisor/xray.err.log
stdout_logfile=/var/log/supervisor/xray.out.log
stdout_logfile_maxbytes=5MB
stderr_logfile_maxbytes=5MB
stdout_logfile_backups=0
stderr_logfile_backups=0
EOF
    chmod 644 /etc/supervisord.conf
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
: "${XTLS_API_PORT:=61000}"

generate_random() {
    length="${1:-64}"
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "${length}"
}

SUPERVISORD_USER="${SUPERVISORD_USER:-$(generate_random 64)}"
SUPERVISORD_PASSWORD="${SUPERVISORD_PASSWORD:-$(generate_random 64)}"
INTERNAL_REST_TOKEN="${INTERNAL_REST_TOKEN:-$(generate_random 64)}"
INTERNAL_SOCKET_PATH="${INTERNAL_SOCKET_PATH:-/run/remnanode-internal.sock}"
SUPERVISORD_SOCKET_PATH="${SUPERVISORD_SOCKET_PATH:-/run/supervisord.sock}"
SUPERVISORD_PID_PATH="${SUPERVISORD_PID_PATH:-/run/supervisord.pid}"

export NODE_PORT SECRET_KEY XTLS_API_PORT
export SUPERVISORD_USER SUPERVISORD_PASSWORD INTERNAL_REST_TOKEN
export INTERNAL_SOCKET_PATH SUPERVISORD_SOCKET_PATH SUPERVISORD_PID_PATH

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
export NODE_OPTIONS="${NODE_OPTIONS:---max-http-header-size=65536 --max-old-space-size=64 --max-semi-space-size=1}"
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"
export UV_THREADPOOL_SIZE="${UV_THREADPOOL_SIZE:-1}"
export XRAY_CORE_VERSION="$([ -x /usr/local/bin/rw-core ] && /usr/local/bin/rw-core version | head -n 1 || true)"

rm -f "${INTERNAL_SOCKET_PATH}" "${SUPERVISORD_SOCKET_PATH}" "${SUPERVISORD_PID_PATH}" 2>/dev/null || true
pkill -x supervisord 2>/dev/null || true

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

TMP_BASE="${HOME:-/root}"
mkdir -p "${TMP_BASE}"
WORK_DIR=$(mktemp -d -p "${TMP_BASE}" remnanode-one-click.XXXXXX)

cleanup() {
    rm -rf "${WORK_DIR}"
}

trap cleanup EXIT INT TERM

install_xray
print_intro

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

install_supervisord_config
install_remnanode_start

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
