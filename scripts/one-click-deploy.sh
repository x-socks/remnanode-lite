#!/bin/sh

set -eu

REPO_SLUG="${1:-${REPO_SLUG:-x-socks/remnanode-lite}}"
BASE_DIR="${BASE_DIR:-/opt/remnanode}"
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
- download the latest runtime bundle from GitHub Releases
- install the bare-metal layout under /opt/remnanode
- write the local OpenRC and supervisord files directly on the host
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

    if id remnanode >/dev/null 2>&1; then
        chown root:remnanode "${file_path}" 2>/dev/null || true
    fi

    chmod 640 "${file_path}" 2>/dev/null || true
}

ensure_service_user() {
    if ! grep -q '^remnanode:' /etc/group 2>/dev/null; then
        addgroup -S remnanode
    fi

    if ! id remnanode >/dev/null 2>&1; then
        adduser -S -D -H -h /nonexistent -s /sbin/nologin -G remnanode remnanode
    fi

    printf '%s\n' "Ensured service user remnanode:remnanode"
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

# Paste the panel-provided secret payload here.
SECRET_KEY=

# Internal Xray API port used by the node process to control rw-core.
XTLS_API_PORT=61000

# Xray integration
XRAY_BIN=/usr/local/bin/xray
XRAY_CONFIG=/etc/xray/config.json
XRAY_ASSET_DIR=/usr/local/share/xray

# Runtime hard limits for 256 MB hosts
NODE_OPTIONS='--max-http-header-size=65536 --max-old-space-size=64 --max-semi-space-size=1'
MALLOC_ARENA_MAX=2
UV_THREADPOOL_SIZE=1
REMNANODE_ULIMIT_NOFILE=65535

# These are auto-generated by remnanode-start if not provided.
# SUPERVISORD_USER=
# SUPERVISORD_PASSWORD=
# INTERNAL_REST_TOKEN=
# INTERNAL_SOCKET_PATH=
# SUPERVISORD_SOCKET_PATH=
# SUPERVISORD_PID_PATH=

# Optional extra tuning
# NODE_NO_WARNINGS=1
# TZ=UTC
EOF
    fi

    if [ ! -f /etc/remnanode/xray.env ]; then
        cat > /etc/remnanode/xray.env <<'EOF'
# Optional standalone Xray service.
# Do not enable this if Remnanode already manages Xray itself.

XRAY_BIN=/usr/local/bin/xray
XRAY_CONFIG=/etc/xray/config.json
XRAY_ASSET_DIR=/usr/local/share/xray
XRAY_ULIMIT_NOFILE=65535
GOMAXPROCS=1
GODEBUG=madvdontneed=1
EOF
    fi

    if [ ! -f /etc/remnanode/github-release.env ]; then
        cat > /etc/remnanode/github-release.env <<'EOF'
# Pull-based updates from the latest GitHub release.
# This path is intended for public repositories using stable asset names.

REPO_SLUG=owner/repo
RUNTIME_ASSET_NAME=remnanode-runtime-latest.tar.gz
BASE_DIR=/opt/remnanode
RESTART_SERVICE=0
EOF
    fi

    chown root:remnanode /etc/remnanode 2>/dev/null || true
    chmod 750 /etc/remnanode 2>/dev/null || true

    for env_file in /etc/remnanode/remnanode.env /etc/remnanode/xray.env /etc/remnanode/github-release.env
    do
        chown root:remnanode "${env_file}" 2>/dev/null || true
        chmod 640 "${env_file}" 2>/dev/null || true
    done
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

run_preflight() {
    STATUS=0

    ok() {
        printf 'ok   %s\n' "$1"
    }

    warn() {
        printf 'warn %s\n' "$1"
    }

    fail() {
        printf 'fail %s\n' "$1" >&2
        STATUS=1
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
            if [ "${mem_kb}" -gt 300000 ]; then
                warn "memory is above the ultra-low-memory target; tuning remains conservative"
            fi
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
        version="$(node -v 2>/dev/null || true)"
        ok "node ${version}"
        major="$(printf '%s' "${version}" | sed 's/^v//' | cut -d. -f1)"
        case "${major}" in
            ''|*[!0-9]*)
                warn "unable to parse Node.js major version"
                ;;
            *)
                if [ "${major}" -lt 24 ]; then
                    warn "Node.js major version is below 24"
                fi
                ;;
        esac
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
        warn "missing /usr/local/bin/rw-core symlink"
    fi

    if has_cmd supervisord; then
        ok "command supervisord"
    else
        warn "missing command supervisord"
    fi

    if command -v apk >/dev/null 2>&1; then
        if apk info -e gcompat >/dev/null 2>&1; then
            ok "apk package gcompat"
        else
            warn "apk package gcompat not installed"
        fi
    else
        warn "apk not available; cannot check gcompat package"
    fi

    nofile="$(ulimit -n 2>/dev/null || true)"
    if [ -n "${nofile}" ]; then
        ok "current nofile ${nofile}"
        if [ "${nofile}" -lt 65535 ] 2>/dev/null; then
            warn "current shell nofile is below 65535"
        fi
    else
        warn "unable to read current nofile limit"
    fi

    return "${STATUS}"
}

install_preflight_tool() {
    cat > /usr/local/bin/remnanode-preflight <<'EOF'
#!/bin/sh

set -eu

STATUS=0

ok() {
    printf 'ok   %s\n' "$1"
}

warn() {
    printf 'warn %s\n' "$1"
}

fail() {
    printf 'fail %s\n' "$1" >&2
    STATUS=1
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
        if [ "${mem_kb}" -gt 300000 ]; then
            warn "memory is above the ultra-low-memory target; tuning remains conservative"
        fi
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
    version="$(node -v 2>/dev/null || true)"
    ok "node ${version}"
    major="$(printf '%s' "${version}" | sed 's/^v//' | cut -d. -f1)"
    case "${major}" in
        ''|*[!0-9]*)
            warn "unable to parse Node.js major version"
            ;;
        *)
            if [ "${major}" -lt 24 ]; then
                warn "Node.js major version is below 24"
            fi
            ;;
    esac
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
    warn "missing /usr/local/bin/rw-core symlink"
fi

if has_cmd supervisord; then
    ok "command supervisord"
else
    warn "missing command supervisord"
fi

if command -v apk >/dev/null 2>&1; then
    if apk info -e gcompat >/dev/null 2>&1; then
        ok "apk package gcompat"
    else
        warn "apk package gcompat not installed"
    fi
else
    warn "apk not available; cannot check gcompat package"
fi

nofile="$(ulimit -n 2>/dev/null || true)"
if [ -n "${nofile}" ]; then
    ok "current nofile ${nofile}"
    if [ "${nofile}" -lt 65535 ] 2>/dev/null; then
        warn "current shell nofile is below 65535"
    fi
else
    warn "unable to read current nofile limit"
fi

exit "${STATUS}"
EOF
    chmod 755 /usr/local/bin/remnanode-preflight
}

install_check_layout_tool() {
    cat > /usr/local/bin/check-remnanode-layout <<'EOF'
#!/bin/sh

set -eu

APP_DIR="${1:-/opt/remnanode/current}"
STATUS=0

check_path() {
    path="$1"
    label="$2"

    if [ -e "${path}" ]; then
        printf 'ok   %s %s\n' "${label}" "${path}"
    else
        printf 'miss %s %s\n' "${label}" "${path}" >&2
        STATUS=1
    fi
}

check_path "${APP_DIR}" dir
check_path "${APP_DIR}/dist" dir
check_path "${APP_DIR}/node_modules" dir
check_path "${APP_DIR}/package.json" file

if [ -f "${APP_DIR}/dist/src/main.js" ]; then
    printf 'ok   file %s\n' "${APP_DIR}/dist/src/main.js"
elif [ -f "${APP_DIR}/dist/src/main" ]; then
    printf 'ok   file %s\n' "${APP_DIR}/dist/src/main"
else
    printf 'miss file %s\n' "${APP_DIR}/dist/src/main(.js)" >&2
    STATUS=1
fi

exit "${STATUS}"
EOF
    chmod 755 /usr/local/bin/check-remnanode-layout
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

install_runtime_bundle_tool() {
    cat > /usr/local/bin/install-remnanode-runtime <<'EOF'
#!/bin/sh

set -eu

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <runtime-bundle.tar.gz> [base-dir]" >&2
    exit 1
fi

BUNDLE_PATH="$1"
BASE_DIR="${2:-/opt/remnanode}"
RELEASES_DIR="${BASE_DIR}/releases"
CURRENT_LINK="${BASE_DIR}/current"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing command: $1" >&2
        exit 1
    fi
}

require_cmd tar
require_cmd date
require_cmd ln
require_cmd cp
require_cmd mv

if [ ! -f "${BUNDLE_PATH}" ]; then
    echo "bundle not found: ${BUNDLE_PATH}" >&2
    exit 1
fi

mkdir -p "${RELEASES_DIR}"

WORK_ROOT="${HOME:-/root}/.remnanode-work"
WORK_DIR="${WORK_ROOT}/install-runtime.$$"
mkdir -p "${WORK_ROOT}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

cleanup() {
    rm -rf "${WORK_DIR}"
}

trap cleanup EXIT INT TERM

tar -C "${WORK_DIR}" -xzf "${BUNDLE_PATH}"

if [ ! -d "${WORK_DIR}/runtime" ]; then
    echo "bundle missing runtime directory" >&2
    exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)-$$"
RELEASE_DIR="${RELEASES_DIR}/${STAMP}"

mv "${WORK_DIR}/runtime" "${RELEASE_DIR}"

if [ -f "${WORK_DIR}/manifest.txt" ]; then
    cp "${WORK_DIR}/manifest.txt" "${RELEASE_DIR}/.bundle-manifest"
fi

ln -sfn "${RELEASE_DIR}" "${CURRENT_LINK}"

printf '%s\n' "installed release ${RELEASE_DIR}"
printf '%s\n' "updated current -> ${RELEASE_DIR}"
EOF
    chmod 755 /usr/local/bin/install-remnanode-runtime
}

install_update_from_github_tool() {
    cat > /usr/local/bin/remnanode-update-from-github <<'EOF'
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
BASE_DIR="${BASE_DIR:-/opt/remnanode}"
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

require_cmd tar
require_cmd sh
require_cmd /usr/local/bin/install-remnanode-runtime
require_cmd /usr/local/bin/check-remnanode-layout

WORK_ROOT="${HOME:-/root}/.remnanode-work"
WORK_DIR="${WORK_ROOT}/update-release.$$"
mkdir -p "${WORK_ROOT}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

cleanup() {
    rm -rf "${WORK_DIR}"
}

trap cleanup EXIT INT TERM

runtime_url="https://github.com/${REPO_SLUG}/releases/latest/download/${RUNTIME_ASSET_NAME}"
runtime_bundle="${WORK_DIR}/${RUNTIME_ASSET_NAME}"

download_file "${runtime_url}" "${runtime_bundle}"

/usr/local/bin/install-remnanode-runtime "${runtime_bundle}" "${BASE_DIR}"
/usr/local/bin/check-remnanode-layout "${BASE_DIR}/current"

if [ "${RESTART_SERVICE}" = "1" ]; then
    rc-service remnanode restart
fi

printf '%s\n' "updated from https://github.com/${REPO_SLUG}/releases/latest"
EOF
    chmod 755 /usr/local/bin/remnanode-update-from-github
}

ensure_layout() {
    mkdir -p /etc/remnanode
    mkdir -p /etc/xray
    mkdir -p /usr/local/bin
    mkdir -p /usr/local/share/xray
    mkdir -p /var/log/remnanode
    mkdir -p /var/log/xray
    mkdir -p /var/log/supervisor
    mkdir -p /etc/conf.d
    mkdir -p /etc/init.d
    mkdir -p "${BASE_DIR}/releases"
    printf '%s\n' "Installed deployment layout into /"
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

WORK_ROOT="${HOME:-/root}/.remnanode-work"
WORK_DIR="${WORK_ROOT}/one-click.$$"
mkdir -p "${WORK_ROOT}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

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

run_preflight
ensure_service_user
ensure_layout
install_preflight_tool
install_check_layout_tool
install_runtime_bundle_tool
install_update_from_github_tool
install_remnanode_service
install_remnanode_env
install_xray_example_config
install_supervisord_config
install_remnanode_start

download_file "https://github.com/${REPO_SLUG}/releases/latest/download/${RUNTIME_ASSET_NAME}" "${WORK_DIR}/${RUNTIME_ASSET_NAME}"
/usr/local/bin/install-remnanode-runtime "${WORK_DIR}/${RUNTIME_ASSET_NAME}" "${BASE_DIR}"
/usr/local/bin/check-remnanode-layout "${BASE_DIR}/current"

update_key_value_file /etc/remnanode/remnanode.env NODE_PORT "${NODE_PORT}"
update_key_value_file /etc/remnanode/remnanode.env SECRET_KEY "${SECRET_KEY}"
update_key_value_file /etc/remnanode/remnanode.env XTLS_API_PORT 61000
update_key_value_file /etc/remnanode/remnanode.env NODE_OPTIONS "--max-http-header-size=65536 --max-old-space-size=64 --max-semi-space-size=1"
update_key_value_file /etc/remnanode/remnanode.env XRAY_BIN /usr/local/bin/xray
update_key_value_file /etc/remnanode/remnanode.env XRAY_CONFIG /etc/xray/config.json
update_key_value_file /etc/remnanode/remnanode.env XRAY_ASSET_DIR /usr/local/share/xray
update_key_value_file /etc/remnanode/github-release.env REPO_SLUG "${REPO_SLUG}"
update_key_value_file /etc/remnanode/github-release.env RUNTIME_ASSET_NAME "${RUNTIME_ASSET_NAME}"
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
rc-service remnanode status || true
printf '%s\n' "===== /etc/remnanode/remnanode.env ====="
cat /etc/remnanode/remnanode.env
printf '%s\n' "===== /var/log/remnanode/remnanode.log ====="
tail -n 50 /var/log/remnanode/remnanode.log || true
printf '%s\n' "===== /var/log/remnanode/remnanode.err ====="
tail -n 50 /var/log/remnanode/remnanode.err || true
