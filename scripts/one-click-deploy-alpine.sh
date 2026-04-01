#!/bin/sh

set -eu

REPO_SLUG="${1:-${REPO_SLUG:-x-socks/remnanode-lite}}"
RUNTIME_VERSION_INPUT="${2:-${RUNTIME_VERSION:-}}"
BASE_DIR="${BASE_DIR:-/opt/remnanode}"
RUNTIME_ASSET_NAME="${RUNTIME_ASSET_NAME:-}"
RUNTIME_RELEASE_TAG="${RUNTIME_RELEASE_TAG:-}"
NODE_PORT="${NODE_PORT:-}"
SECRET_INPUT="${SECRET_INPUT:-${SECRET_KEY:-}}"
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

print_intro() {
    cat >&2 <<'EOF'
Remnanode one-click install

This installer will:
- install or verify Node.js 24, supervisor, gcompat, unzip, tar, and Xray
- download the selected runtime bundle from GitHub Releases
- install the bare-metal layout under /opt/remnanode
- write the local OpenRC, supervisord, and env files directly on the host
- keep Xray under a minimal supervisor control plane for upstream compatibility
- write /etc/remnanode/remnanode.env
- enable and start the OpenRC remnanode service

You will be prompted for:
- RUNTIME_VERSION: press Enter for the latest runtime, or enter a specific upstream version
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

ensure_apk_prereqs() {
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache --upgrade curl tar nodejs gcompat unzip supervisor
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
    mkdir -p /etc/conf.d
    mkdir -p /etc/init.d
    mkdir -p "${BASE_DIR}/releases"
    chmod 700 /etc/remnanode 2>/dev/null || true
    printf '%s\n' "Installed deployment layout into /"
}

install_remnanode_service() {
    cat > /etc/init.d/remnanode <<'EOF'
#!/sbin/openrc-run

description="Remnanode bare-metal service"

: "${command:=/usr/local/bin/remnanode-start}"
: "${command_user:=root:root}"
: "${directory:=/opt/remnanode/current}"
: "${pidfile:=/run/remnanode.pid}"
: "${output_log:=/var/log/remnanode/remnanode.log}"
: "${error_log:=/var/log/remnanode/remnanode.err}"
: "${respawn_delay:=5}"
: "${respawn_max:=0}"

supervisor=supervise-daemon
command_background=true

depend() {
    need net localmount
    after firewall
    use dns logger
}

start_pre() {
    checkpath -d -m 0755 -o "${command_user}" /var/log/remnanode
    checkpath -f -m 0644 -o "${command_user}" "${output_log}"
    checkpath -f -m 0644 -o "${command_user}" "${error_log}"
    checkpath -d -m 0755 -o "${command_user}" /var/log/supervisor

    if [ ! -x "${command}" ]; then
        eerror "Missing executable: ${command}"
        return 1
    fi

    if [ ! -d "${directory}" ]; then
        eerror "Missing application directory: ${directory}"
        return 1
    fi
}
EOF
    chmod 755 /etc/init.d/remnanode

    cat > /etc/conf.d/remnanode <<'EOF'
# OpenRC service configuration for Remnanode
command=/usr/local/bin/remnanode-start
command_user=root:root
directory=/opt/remnanode/current
pidfile=/run/remnanode.pid
output_log=/var/log/remnanode/remnanode.log
error_log=/var/log/remnanode/remnanode.err
respawn_delay=5
respawn_max=0
EOF
    chmod 644 /etc/conf.d/remnanode
}

install_remnanode_env() {
    if [ ! -f /etc/remnanode/remnanode.env ]; then
        cat > /etc/remnanode/remnanode.env <<'EOF'
# Remnanode runtime layout
REMNANODE_APP_DIR=/opt/remnanode/current
REMNANODE_ENTRYPOINT=dist/src/main.js
REMNANODE_ENV=production

# Required panel values.
NODE_PORT=20481
SECRET_KEY=

# Internal Xray API port used by the node process to control rw-core.
XTLS_API_PORT=61000

# Xray integration
XRAY_BIN=/usr/local/bin/xray
XRAY_CONFIG=/etc/xray/config.json
XRAY_ASSET_DIR=/usr/local/share/xray

# Runtime hard limits for 128 MB experimental hosts
NODE_OPTIONS='--max-http-header-size=32768 --max-old-space-size=48 --max-semi-space-size=1'
MALLOC_ARENA_MAX=1
UV_THREADPOOL_SIZE=1
REMNANODE_ULIMIT_NOFILE=65535

# Stable local control channel used by the supervisor-managed xray process.
INTERNAL_REST_TOKEN=
INTERNAL_SOCKET_PATH=/run/remnanode-internal.sock
XRAY_START_TIMEOUT=20

# Compatibility variables still required by the current Remnanode runtime.
SUPERVISORD_USER=
SUPERVISORD_PASSWORD=
SUPERVISORD_SOCKET_PATH=/run/supervisord.sock
SUPERVISORD_PID_PATH=/run/supervisord.pid

# Optional extra tuning
# NODE_NO_WARNINGS=1
# TZ=UTC
EOF
    fi

    if [ ! -f /etc/remnanode/github-release.env ]; then
        cat > /etc/remnanode/github-release.env <<'EOF'
# Pull-based updates from GitHub releases.
REPO_SLUG=owner/repo
RUNTIME_VERSION=latest
BASE_DIR=/opt/remnanode
EOF
    fi

    chmod 600 /etc/remnanode/remnanode.env /etc/remnanode/github-release.env 2>/dev/null || true
    chown root:root /etc/remnanode/remnanode.env /etc/remnanode/github-release.env 2>/dev/null || true
}

install_xray_example_config() {
    if [ ! -f /etc/xray/config.json.example ]; then
        cat > /etc/xray/config.json.example <<'EOF'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-tcp",
      "listen": "0.0.0.0",
      "port": 20482,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
  ]
}
EOF
    fi

    chmod 644 /etc/xray/config.json.example
}

install_supervisord_config() {
    cat > /etc/supervisord.conf <<'EOF'
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=%(ENV_SUPERVISORD_PID_PATH)s
childlogdir=/var/log/supervisor
logfile_maxbytes=1MB
logfile_backups=0
loglevel=warn
silent=true

[unix_http_server]
file=%(ENV_SUPERVISORD_SOCKET_PATH)s
username=%(ENV_SUPERVISORD_USER)s
password=%(ENV_SUPERVISORD_PASSWORD)s

[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://%(ENV_SUPERVISORD_SOCKET_PATH)s
username=%(ENV_SUPERVISORD_USER)s
password=%(ENV_SUPERVISORD_PASSWORD)s

[program:xray]
command=/usr/local/bin/rw-core -config http+unix://%(ENV_INTERNAL_SOCKET_PATH)s/internal/get-config?token=%(ENV_INTERNAL_REST_TOKEN)s -format json
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
    rc-service remnanode-xray stop >/dev/null 2>&1 || true
    rc-update del remnanode-xray default >/dev/null 2>&1 || true
    rm -f /etc/init.d/remnanode-xray
    rm -f /etc/conf.d/remnanode-xray
    rm -f /usr/local/bin/remnanode-xray-start
    rm -f /run/remnanode-xray.pid
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

install_runtime_bundle() {
    bundle_path="$1"
    releases_dir="${BASE_DIR}/releases"
    current_link="${BASE_DIR}/current"

    if [ ! -f "${bundle_path}" ]; then
        echo "bundle not found: ${bundle_path}" >&2
        exit 1
    fi

    install_dir="${WORK_DIR}/install-runtime"
    rm -rf "${install_dir}"
    mkdir -p "${install_dir}" "${releases_dir}"

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

run_preflight() {
    status=0

    ok() {
        printf 'ok   %s\n' "$1"
    }

    warn() {
        printf 'warn %s\n' "$1"
    }

    fail() {
        printf 'fail %s\n' "$1" >&2
        status=1
    }

    has_cmd() {
        command -v "$1" >/dev/null 2>&1
    }

    check_cmd() {
        if has_cmd "$1"; then
            ok "command $1"
        else
            fail "missing command $1"
        fi
    }

    check_file() {
        if [ -e "$1" ]; then
            ok "path $1"
        else
            fail "missing path $1"
        fi
    }

    if [ -f /etc/alpine-release ]; then
        ok "alpine $(cat /etc/alpine-release)"
    else
        warn "host is not reporting Alpine via /etc/alpine-release"
    fi

    if [ -r /proc/meminfo ]; then
        mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
        if [ -n "${mem_kb}" ]; then
            ok "memtotal ${mem_kb} kB"
        else
            warn "unable to parse /proc/meminfo"
        fi
    else
        warn "cannot read /proc/meminfo"
    fi

    if [ -r /proc/swaps ]; then
        swap_lines="$(awk 'NR>1 {count++} END {print count+0}' /proc/swaps)"
        if [ "${swap_lines}" -eq 0 ]; then
            ok "no swap configured"
        else
            warn "swap entries detected in /proc/swaps"
        fi
    else
        warn "cannot read /proc/swaps"
    fi

    check_cmd rc-service
    check_cmd rc-update
    check_file /sbin/openrc-run

    if has_cmd node; then
        ok "node $(node -v 2>/dev/null || true)"
    else
        fail "missing command node"
    fi

    if has_cmd xray; then
        ok "command xray"
    elif [ -x /usr/local/bin/xray ]; then
        ok "path /usr/local/bin/xray"
    else
        fail "missing xray binary"
    fi

    if [ -x /usr/local/bin/rw-core ]; then
        ok "path /usr/local/bin/rw-core"
    else
        warn "missing /usr/local/bin/rw-core"
    fi

    if has_cmd supervisord; then
        ok "command supervisord"
    else
        fail "missing command supervisord"
    fi

    if command -v apk >/dev/null 2>&1; then
        if apk info -e gcompat >/dev/null 2>&1; then
            ok "apk package gcompat"
        else
            warn "apk package gcompat not installed"
        fi
    fi

    nofile="$(ulimit -n 2>/dev/null || true)"
    if [ -n "${nofile}" ]; then
        ok "current nofile ${nofile}"
    fi

    return "${status}"
}

require_root

WORK_ROOT="${HOME:-/root}/.remnanode-work"
WORK_DIR="${WORK_ROOT}/one-click.$$"
mkdir -p "${WORK_ROOT}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

cleanup() {
    rm -rf "${WORK_DIR}"
}

trap cleanup EXIT INT TERM

ensure_apk_prereqs
require_cmd tar
require_cmd unzip
require_cmd install
require_cmd node
require_cmd supervisord
require_cmd rc-service
require_cmd rc-update
require_node_24
install_xray

print_intro
RUNTIME_VERSION="$(prompt_with_default 'RUNTIME_VERSION [latest]: ' "${RUNTIME_VERSION_INPUT}" latest)"
RUNTIME_VERSION="$(resolve_runtime_version "${RUNTIME_VERSION}" "${RUNTIME_ASSET_NAME}")"
RUNTIME_ASSET_NAME="$(resolve_runtime_asset_name "${RUNTIME_VERSION}" "${RUNTIME_ASSET_NAME}" "${RUNTIME_VERSION_INPUT}")"
RUNTIME_RELEASE_TAG="$(resolve_runtime_release_tag "${RUNTIME_VERSION}" "${RUNTIME_RELEASE_TAG}")"
NODE_PORT="$(prompt_required 'NODE_PORT (Node Port from panel): ' "${NODE_PORT}")"
SECRET_INPUT="$(prompt_required 'SECRET_KEY value or full line from panel: ' "${SECRET_INPUT}")"
SECRET_KEY="$(normalize_secret_key "${SECRET_INPUT}")"

case "${NODE_PORT}" in
    ''|*[!0-9]*)
        echo "NODE_PORT must be numeric" >&2
        exit 1
        ;;
esac

run_preflight
ensure_layout
cleanup_legacy_xray_sidecar
install_remnanode_service
install_remnanode_env
install_xray_example_config
install_supervisord_config
install_remnanode_start

runtime_url="$(build_runtime_download_url "${REPO_SLUG}" "${RUNTIME_VERSION}" "${RUNTIME_ASSET_NAME}" "${RUNTIME_RELEASE_TAG}")"
runtime_bundle="${WORK_DIR}/${RUNTIME_ASSET_NAME}"
download_file "${runtime_url}" "${runtime_bundle}"
install_runtime_bundle "${runtime_bundle}"
check_layout

update_key_value_file /etc/remnanode/remnanode.env NODE_PORT "${NODE_PORT}"
update_key_value_file /etc/remnanode/remnanode.env SECRET_KEY "${SECRET_KEY}"
update_key_value_file /etc/remnanode/remnanode.env XTLS_API_PORT 61000
update_key_value_file /etc/remnanode/remnanode.env XRAY_BIN /usr/local/bin/xray
update_key_value_file /etc/remnanode/remnanode.env XRAY_CONFIG /etc/xray/config.json
update_key_value_file /etc/remnanode/remnanode.env XRAY_ASSET_DIR /usr/local/share/xray
if [ -z "${INTERNAL_REST_TOKEN}" ]; then
    INTERNAL_REST_TOKEN="$(generate_random 64)"
fi
if [ -z "${SUPERVISORD_USER}" ]; then
    SUPERVISORD_USER="$(generate_random 32)"
fi
if [ -z "${SUPERVISORD_PASSWORD}" ]; then
    SUPERVISORD_PASSWORD="$(generate_random 64)"
fi
update_key_value_file /etc/remnanode/remnanode.env INTERNAL_REST_TOKEN "${INTERNAL_REST_TOKEN}"
update_key_value_file /etc/remnanode/remnanode.env INTERNAL_SOCKET_PATH "${INTERNAL_SOCKET_PATH}"
update_key_value_file /etc/remnanode/remnanode.env XRAY_START_TIMEOUT "${XRAY_START_TIMEOUT}"
update_key_value_file /etc/remnanode/remnanode.env SUPERVISORD_USER "${SUPERVISORD_USER}"
update_key_value_file /etc/remnanode/remnanode.env SUPERVISORD_PASSWORD "${SUPERVISORD_PASSWORD}"
update_key_value_file /etc/remnanode/remnanode.env SUPERVISORD_SOCKET_PATH "${SUPERVISORD_SOCKET_PATH}"
update_key_value_file /etc/remnanode/remnanode.env SUPERVISORD_PID_PATH "${SUPERVISORD_PID_PATH}"
update_key_value_file /etc/remnanode/remnanode.env NODE_OPTIONS "--max-http-header-size=32768 --max-old-space-size=48 --max-semi-space-size=1"
update_key_value_file /etc/remnanode/remnanode.env MALLOC_ARENA_MAX 1
update_key_value_file /etc/remnanode/remnanode.env UV_THREADPOOL_SIZE 1
update_key_value_file /etc/remnanode/github-release.env REPO_SLUG "${REPO_SLUG}"
update_key_value_file /etc/remnanode/github-release.env RUNTIME_VERSION "${RUNTIME_VERSION}"
update_key_value_file /etc/remnanode/github-release.env RUNTIME_ASSET_NAME "${RUNTIME_ASSET_NAME}"
update_key_value_file /etc/remnanode/github-release.env RUNTIME_RELEASE_TAG "${RUNTIME_RELEASE_TAG}"
update_key_value_file /etc/remnanode/github-release.env BASE_DIR "${BASE_DIR}"

if [ ! -f /etc/xray/config.json ] && [ -f /etc/xray/config.json.example ]; then
    cp /etc/xray/config.json.example /etc/xray/config.json
fi

chmod 644 /etc/xray/config.json 2>/dev/null || true

rc-update add remnanode default >/dev/null 2>&1 || true

if rc-service remnanode status >/dev/null 2>&1; then
    rc-service remnanode restart
else
    rc-service remnanode start
fi

sleep 3
printf '%s\n' "===== service status ====="
rc-service remnanode status || true
printf '%s\n' "===== /etc/remnanode/remnanode.env ====="
cat /etc/remnanode/remnanode.env
printf '%s\n' "===== /etc/supervisord.conf ====="
cat /etc/supervisord.conf
printf '%s\n' "===== /var/log/remnanode/remnanode.log ====="
tail -n 50 /var/log/remnanode/remnanode.log || true
printf '%s\n' "===== /var/log/remnanode/remnanode.err ====="
tail -n 50 /var/log/remnanode/remnanode.err || true
printf '%s\n' "===== /var/log/supervisor/supervisord.log ====="
tail -n 50 /var/log/supervisor/supervisord.log || true
printf '%s\n' "===== /var/log/remnanode/xray.log ====="
tail -n 50 /var/log/remnanode/xray.log || true
printf '%s\n' "===== /var/log/remnanode/xray.err ====="
tail -n 50 /var/log/remnanode/xray.err || true
