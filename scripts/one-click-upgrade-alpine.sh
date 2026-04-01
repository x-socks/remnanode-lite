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

read_cgroup_memory_limit_mb() {
    if [ ! -r /sys/fs/cgroup/memory.max ]; then
        return 1
    fi

    limit_bytes="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)"
    case "${limit_bytes}" in
        ''|max|*[!0-9]*)
            return 1
            ;;
    esac

    awk -v bytes="${limit_bytes}" 'BEGIN {
        if (bytes <= 0) {
            exit 1
        }
        printf "%d\n", bytes / 1048576
    }'
}

detect_effective_memory_limit_mb() {
    mem_total_mb=""
    cgroup_limit_mb="$(read_cgroup_memory_limit_mb || true)"

    if [ -r /proc/meminfo ]; then
        mem_total_mb="$(awk '/MemTotal:/ { printf "%d\n", $2 / 1024; exit }' /proc/meminfo 2>/dev/null || true)"
    fi

    if [ -n "${cgroup_limit_mb}" ] && [ -n "${mem_total_mb}" ] && [ "${cgroup_limit_mb}" -lt "${mem_total_mb}" ]; then
        printf '%s\n' "${cgroup_limit_mb}"
        return 0
    fi

    if [ -n "${mem_total_mb}" ]; then
        printf '%s\n' "${mem_total_mb}"
        return 0
    fi

    if [ -n "${cgroup_limit_mb}" ]; then
        printf '%s\n' "${cgroup_limit_mb}"
        return 0
    fi

    printf '%s\n' 0
}

default_node_options() {
    limit_mb="$(detect_effective_memory_limit_mb)"
    old_space_mb=48

    case "${limit_mb}" in
        ''|0)
            ;;
        *)
            if [ "${limit_mb}" -le 128 ]; then
                old_space_mb=12
            elif [ "${limit_mb}" -le 192 ]; then
                old_space_mb=16
            elif [ "${limit_mb}" -le 256 ]; then
                old_space_mb=24
            elif [ "${limit_mb}" -le 384 ]; then
                old_space_mb=32
            fi
            ;;
    esac

    printf '%s\n' "--max-http-header-size=32768 --max-old-space-size=${old_space_mb} --max-semi-space-size=1"
}

is_managed_node_options() {
    case "$1" in
        ''|"--max-http-header-size=65536 --max-old-space-size=64 --max-semi-space-size=1"|"--max-http-header-size=32768 --max-old-space-size=48 --max-semi-space-size=1"|"--max-http-header-size=32768 --max-old-space-size=32 --max-semi-space-size=1"|"--max-http-header-size=32768 --max-old-space-size=24 --max-semi-space-size=1"|"--max-http-header-size=32768 --max-old-space-size=16 --max-semi-space-size=1"|"--max-http-header-size=32768 --max-old-space-size=12 --max-semi-space-size=1")
            return 0
            ;;
        *)
            return 1
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
        apk add --no-cache --upgrade supervisor >/dev/null
    fi
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
    : > /var/log/remnanode/xray.log
    : > /var/log/remnanode/xray.err
    chmod 644 /var/log/remnanode/xray.log /var/log/remnanode/xray.err 2>/dev/null || true
    chmod 700 /etc/remnanode 2>/dev/null || true
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
detect_effective_memory_limit_mb() {
    cgroup_limit_mb=""
    mem_total_mb=""

    if [ -r /sys/fs/cgroup/memory.max ]; then
        limit_bytes="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)"
        case "${limit_bytes}" in
            ''|max|*[!0-9]*)
                ;;
            *)
                cgroup_limit_mb="$(awk -v bytes="${limit_bytes}" 'BEGIN { if (bytes > 0) printf "%d", bytes / 1048576 }')"
                ;;
        esac
    fi

    if [ -r /proc/meminfo ]; then
        mem_total_mb="$(awk '/MemTotal:/ { printf "%d", $2 / 1024; exit }' /proc/meminfo 2>/dev/null || true)"
    fi

    if [ -n "${cgroup_limit_mb}" ] && [ -n "${mem_total_mb}" ] && [ "${cgroup_limit_mb}" -lt "${mem_total_mb}" ]; then
        printf '%s\n' "${cgroup_limit_mb}"
        return 0
    fi

    if [ -n "${mem_total_mb}" ]; then
        printf '%s\n' "${mem_total_mb}"
        return 0
    fi

    if [ -n "${cgroup_limit_mb}" ]; then
        printf '%s\n' "${cgroup_limit_mb}"
        return 0
    fi

    printf '%s\n' 0
}

default_node_options() {
    limit_mb="$(detect_effective_memory_limit_mb)"
    old_space_mb=48

    case "${limit_mb}" in
        ''|0)
            ;;
        *)
            if [ "${limit_mb}" -le 128 ]; then
                old_space_mb=12
            elif [ "${limit_mb}" -le 192 ]; then
                old_space_mb=16
            elif [ "${limit_mb}" -le 256 ]; then
                old_space_mb=24
            elif [ "${limit_mb}" -le 384 ]; then
                old_space_mb=32
            fi
            ;;
    esac

    printf '%s\n' "--max-http-header-size=32768 --max-old-space-size=${old_space_mb} --max-semi-space-size=1"
}

export NODE_OPTIONS="${NODE_OPTIONS:-$(default_node_options)}"
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

    ensure_apk_prereqs
    ensure_layout
    cleanup_legacy_xray_sidecar
    install_remnanode_service
    install_remnanode_start

    if [ -z "${INTERNAL_REST_TOKEN}" ]; then
        INTERNAL_REST_TOKEN="$(generate_random 64)"
    fi
    if [ -z "${SUPERVISORD_USER}" ]; then
        SUPERVISORD_USER="$(generate_random 32)"
    fi
    if [ -z "${SUPERVISORD_PASSWORD}" ]; then
        SUPERVISORD_PASSWORD="$(generate_random 64)"
    fi

    update_key_value_file "${REMNANODE_ENV_FILE}" INTERNAL_REST_TOKEN "${INTERNAL_REST_TOKEN}"
    update_key_value_file "${REMNANODE_ENV_FILE}" INTERNAL_SOCKET_PATH "${INTERNAL_SOCKET_PATH}"
    update_key_value_file "${REMNANODE_ENV_FILE}" XRAY_START_TIMEOUT "${XRAY_START_TIMEOUT}"
    update_key_value_file "${REMNANODE_ENV_FILE}" SUPERVISORD_USER "${SUPERVISORD_USER}"
    update_key_value_file "${REMNANODE_ENV_FILE}" SUPERVISORD_PASSWORD "${SUPERVISORD_PASSWORD}"
    update_key_value_file "${REMNANODE_ENV_FILE}" SUPERVISORD_SOCKET_PATH "${SUPERVISORD_SOCKET_PATH}"
    update_key_value_file "${REMNANODE_ENV_FILE}" SUPERVISORD_PID_PATH "${SUPERVISORD_PID_PATH}"
    install_supervisord_config

    if is_managed_node_options "${current_node_options}"; then
        update_key_value_file "${REMNANODE_ENV_FILE}" NODE_OPTIONS "$(default_node_options)"
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
require_cmd rc-update
require_cmd rc-service

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
install_runtime_bundle "${runtime_bundle}"
check_layout
update_key_value_file "${ENV_FILE}" RUNTIME_VERSION "${RUNTIME_VERSION}"
update_key_value_file "${ENV_FILE}" RUNTIME_ASSET_NAME "${RUNTIME_ASSET_NAME}"
update_key_value_file "${ENV_FILE}" RUNTIME_RELEASE_TAG "${RUNTIME_RELEASE_TAG}"

printf '%s\n' "restarting remnanode"
rc-service remnanode restart
sleep 3

printf '%s\n' "===== service status ====="
rc-service remnanode status || true
printf '%s\n' "===== /etc/supervisord.conf ====="
cat /etc/supervisord.conf || true
printf '%s\n' "===== /var/log/remnanode/remnanode.log ====="
tail -n 40 /var/log/remnanode/remnanode.log || true
printf '%s\n' "===== /var/log/remnanode/remnanode.err ====="
tail -n 40 /var/log/remnanode/remnanode.err || true
printf '%s\n' "===== /var/log/supervisor/supervisord.log ====="
tail -n 40 /var/log/supervisor/supervisord.log || true
printf '%s\n' "===== /var/log/remnanode/xray.log ====="
tail -n 40 /var/log/remnanode/xray.log || true
printf '%s\n' "===== /var/log/remnanode/xray.err ====="
tail -n 40 /var/log/remnanode/xray.err || true
