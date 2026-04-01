#!/bin/sh

set -eu

ACTION="${1:-${ACTION:-auto}}"
REPO_SLUG="${2:-${REPO_SLUG:-x-socks/remnanode-lite}}"
REPO_REF="${3:-${REPO_REF:-main}}"
RUNTIME_VERSION="${4:-${RUNTIME_VERSION:-latest}}"
BASE_DIR="${BASE_DIR:-/opt/remnanode}"
REMNANODE_ENV_FILE="${REMNANODE_ENV_FILE:-/etc/remnanode/remnanode.env}"
GITHUB_RELEASE_ENV_FILE="${GITHUB_RELEASE_ENV_FILE:-/etc/remnanode/github-release.env}"
XRAY_CONFIG_FILE="${XRAY_CONFIG_FILE:-/etc/xray/config.json}"
PANEL_TITLE="${PANEL_TITLE:-remnanode-lite Node Management}"
PANEL_WORK_ROOT="${PANEL_WORK_ROOT:-${HOME:-/root}/.remnanode-work}"
PANEL_INSTALL_DIR="${PANEL_INSTALL_DIR:-/usr/local/lib/remnanode}"
PANEL_INSTALLED_SCRIPT="${PANEL_INSTALLED_SCRIPT:-${PANEL_INSTALL_DIR}/one-click-panel.sh}"
PANEL_LAUNCHER_PATH="${PANEL_LAUNCHER_PATH:-/usr/local/bin/remnanode}"

PUBLIC_IP_CACHE="${PUBLIC_IP_CACHE:-}"
SNAPSHOT_STATUS=""
SNAPSHOT_IP=""
SNAPSHOT_PORT=""
SNAPSHOT_FULL_URL=""
SNAPSHOT_RUNTIME_VERSION=""
SNAPSHOT_XRAY_VERSION=""
SNAPSHOT_XRAY_STATE=""
SNAPSHOT_CPU_LOAD=""
SNAPSHOT_MEMORY_USAGE=""
SNAPSHOT_DISK_USAGE=""
ANSI_BOLD=""
ANSI_RESET=""
ANSI_CYAN=""
ANSI_BLUE=""
ANSI_GREEN=""
ANSI_YELLOW=""
ANSI_MAGENTA=""

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "this script must run as root" >&2
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

download_file() {
    url="$1"
    out="$2"

    if command_exists curl; then
        curl -fsSL "${url}" -o "${out}"
        return 0
    fi

    if command_exists wget; then
        wget -qO "${out}" "${url}"
        return 0
    fi

    echo "missing curl or wget" >&2
    exit 1
}

make_temp_dir() {
    prefix="${1:-panel}"

    mkdir -p "${PANEL_WORK_ROOT}"
    mktemp -d "${PANEL_WORK_ROOT}/${prefix}.XXXXXX"
}

init_terminal_style() {
    if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
        esc="$(printf '\033')"
        ANSI_BOLD="${esc}[1m"
        ANSI_RESET="${esc}[0m"
        ANSI_CYAN="${esc}[36m"
        ANSI_BLUE="${esc}[34m"
        ANSI_GREEN="${esc}[32m"
        ANSI_YELLOW="${esc}[33m"
        ANSI_MAGENTA="${esc}[35m"
    fi
}

resolve_self_path() {
    script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
    printf '%s/%s\n' "${script_dir}" "$(basename -- "$0")"
}

is_installed() {
    [ -f "${REMNANODE_ENV_FILE}" ] && [ -e "${BASE_DIR}/current" ]
}

extract_env_value() {
    file_path="$1"
    key_name="$2"

    if [ ! -f "${file_path}" ]; then
        return 1
    fi

    line="$(grep "^${key_name}=" "${file_path}" | tail -n 1 || true)"
    if [ -z "${line}" ]; then
        return 1
    fi

    value="${line#*=}"
    case "${value}" in
        \"*\")
            value="${value#\"}"
            value="${value%\"}"
            ;;
        \'*\')
            value="${value#\'}"
            value="${value%\'}"
            ;;
    esac

    printf '%s\n' "${value}"
}

load_saved_defaults() {
    saved_repo_slug="$(extract_env_value "${GITHUB_RELEASE_ENV_FILE}" REPO_SLUG || true)"
    saved_base_dir="$(extract_env_value "${GITHUB_RELEASE_ENV_FILE}" BASE_DIR || true)"
    saved_runtime_version="$(extract_env_value "${GITHUB_RELEASE_ENV_FILE}" RUNTIME_VERSION || true)"

    if [ "${REPO_SLUG}" = "x-socks/remnanode-lite" ] && [ -n "${saved_repo_slug}" ] && [ "${saved_repo_slug}" != "owner/repo" ]; then
        REPO_SLUG="${saved_repo_slug}"
    fi

    if [ "${BASE_DIR}" = "/opt/remnanode" ] && [ -n "${saved_base_dir}" ]; then
        BASE_DIR="${saved_base_dir}"
    fi

    if [ "${RUNTIME_VERSION}" = "latest" ] && [ -n "${saved_runtime_version}" ]; then
        RUNTIME_VERSION="${saved_runtime_version}"
    fi
}

detect_platform() {
    if [ -f /etc/alpine-release ]; then
        printf '%s\n' alpine
        return 0
    fi

    if [ -f /etc/debian_version ] && command_exists systemctl; then
        printf '%s\n' debian
        return 0
    fi

    printf '%s\n' unknown
}

service_name() {
    printf '%s\n' remnanode
}

service_unit() {
    printf '%s\n' remnanode.service
}

service_is_active() {
    platform="$(detect_platform)"

    case "${platform}" in
        debian)
            systemctl is-active --quiet "$(service_unit)"
            ;;
        alpine)
            rc-service "$(service_name)" status >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

service_control() {
    action_name="$1"
    platform="$(detect_platform)"

    case "${platform}" in
        debian)
            case "${action_name}" in
                start)
                    systemctl enable "$(service_unit)" >/dev/null 2>&1 || true
                    ;;
            esac
            systemctl "${action_name}" "$(service_unit)"
            ;;
        alpine)
            case "${action_name}" in
                start)
                    rc-update add "$(service_name)" default >/dev/null 2>&1 || true
                    ;;
            esac
            rc-service "$(service_name)" "${action_name}"
            ;;
        *)
            echo "unsupported host: expected Alpine or Debian with systemd" >&2
            return 1
            ;;
    esac
}

show_service_status_output() {
    platform="$(detect_platform)"

    case "${platform}" in
        debian)
            systemctl --no-pager status "$(service_unit)" 2>&1 || true
            ;;
        alpine)
            rc-service "$(service_name)" status 2>&1 || true
            ;;
        *)
            printf '%s\n' "unsupported host"
            ;;
    esac
}

run_service_action() {
    action_name="$1"

    if ! is_installed; then
        printf '%s\n' "remnanode is not installed" >&2
        return 1
    fi

    service_control "${action_name}"
}

find_primary_ip() {
    if [ -n "${PUBLIC_IP_CACHE}" ]; then
        printf '%s\n' "${PUBLIC_IP_CACHE}"
        return 0
    fi

    if command_exists curl; then
        for url in https://api64.ipify.org https://ifconfig.me/ip; do
            ip_value="$(curl -fsS --connect-timeout 2 --max-time 3 "${url}" 2>/dev/null || true)"
            if [ -n "${ip_value}" ]; then
                PUBLIC_IP_CACHE="${ip_value}"
                printf '%s\n' "${PUBLIC_IP_CACHE}"
                return 0
            fi
        done
    fi

    if command_exists ip; then
        ip_value="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
        if [ -n "${ip_value}" ]; then
            PUBLIC_IP_CACHE="${ip_value}"
            printf '%s\n' "${PUBLIC_IP_CACHE}"
            return 0
        fi
    fi

    if command_exists hostname; then
        ip_value="$(hostname -I 2>/dev/null | awk '{print $1}')"
        if [ -n "${ip_value}" ]; then
            PUBLIC_IP_CACHE="${ip_value}"
            printf '%s\n' "${PUBLIC_IP_CACHE}"
            return 0
        fi
    fi

    printf '%s\n' "n/a"
}

extract_runtime_version() {
    manifest_path="${BASE_DIR}/current/.bundle-manifest"
    package_json="${BASE_DIR}/current/package.json"

    if [ -f "${manifest_path}" ]; then
        version_value="$(sed -n 's/^runtime_version=//p' "${manifest_path}" | head -n 1)"
        if [ -n "${version_value}" ]; then
            printf '%s\n' "${version_value}"
            return 0
        fi

        version_value="$(sed -n 's/^bundle_version=//p' "${manifest_path}" | head -n 1)"
        if [ -n "${version_value}" ]; then
            printf '%s\n' "${version_value}"
            return 0
        fi
    fi

    if [ -f "${package_json}" ]; then
        version_value="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${package_json}" | head -n 1)"
        if [ -n "${version_value}" ]; then
            printf '%s\n' "${version_value}"
            return 0
        fi
    fi

    extract_env_value "${GITHUB_RELEASE_ENV_FILE}" RUNTIME_VERSION || printf '%s\n' "not installed"
}

extract_node_port() {
    extract_env_value "${REMNANODE_ENV_FILE}" NODE_PORT || printf '%s\n' "n/a"
}

extract_xray_bin() {
    xray_bin="$(extract_env_value "${REMNANODE_ENV_FILE}" XRAY_BIN || true)"
    if [ -n "${xray_bin}" ]; then
        printf '%s\n' "${xray_bin}"
        return 0
    fi

    if [ -x /usr/local/bin/xray ]; then
        printf '%s\n' /usr/local/bin/xray
        return 0
    fi

    printf '%s\n' xray
}

extract_xray_version() {
    xray_bin="$(extract_xray_bin)"

    if [ -x "${xray_bin}" ]; then
        version_line="$("${xray_bin}" version 2>/dev/null | head -n 1 || true)"
    elif command_exists "${xray_bin}"; then
        version_line="$("${xray_bin}" version 2>/dev/null | head -n 1 || true)"
    else
        version_line=""
    fi

    if [ -n "${version_line}" ]; then
        version_value="$(printf '%s\n' "${version_line}" | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^[0-9][0-9.]*$/) { print $i; exit }}')"
        if [ -n "${version_value}" ]; then
            printf '%s\n' "${version_value}"
            return 0
        fi
        printf '%s\n' "${version_line}"
        return 0
    fi

    printf '%s\n' "not installed"
}

extract_xray_component_state() {
    xray_bin="$(extract_xray_bin)"

    if [ -x "${xray_bin}" ] || command_exists "${xray_bin}"; then
        printf '%s\n' installed
        return 0
    fi

    printf '%s\n' missing
}

human_kib() {
    kib_value="$1"

    awk -v kib="${kib_value}" 'BEGIN {
        split("KiB MiB GiB TiB", units, " ")
        value = kib + 0
        unit = 1
        while (value >= 1024 && unit < 4) {
            value = value / 1024
            unit++
        }
        if (unit == 1) {
            printf "%.0f%s", value, units[unit]
        } else {
            printf "%.1f%s", value, units[unit]
        }
    }'
}

extract_memory_usage() {
    if [ ! -r /proc/meminfo ]; then
        printf '%s\n' "n/a"
        return 0
    fi

    mem_total="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
    mem_available="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"

    if [ -z "${mem_total}" ] || [ -z "${mem_available}" ]; then
        printf '%s\n' "n/a"
        return 0
    fi

    mem_used=$((mem_total - mem_available))
    printf '%s / %s\n' "$(human_kib "${mem_used}")" "$(human_kib "${mem_total}")"
}

extract_disk_usage() {
    if ! command_exists df; then
        printf '%s\n' "n/a"
        return 0
    fi

    df_line="$(df -Pk "${BASE_DIR}" 2>/dev/null | awk 'NR == 2 {print $2 " " $4 " " $5}')"
    if [ -z "${df_line}" ]; then
        df_line="$(df -Pk / 2>/dev/null | awk 'NR == 2 {print $2 " " $4 " " $5}')"
    fi

    if [ -z "${df_line}" ]; then
        printf '%s\n' "n/a"
        return 0
    fi

    total_kib="$(printf '%s\n' "${df_line}" | awk '{print $1}')"
    avail_kib="$(printf '%s\n' "${df_line}" | awk '{print $2}')"
    used_pct="$(printf '%s\n' "${df_line}" | awk '{print $3}')"

    printf '%s used, %s available\n' "${used_pct}" "$(human_kib "${avail_kib}")"
}

extract_cpu_load() {
    if [ ! -r /proc/loadavg ]; then
        printf '%s\n' "n/a"
        return 0
    fi

    load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || true)"
    load5="$(awk '{print $2}' /proc/loadavg 2>/dev/null || true)"
    load15="$(awk '{print $3}' /proc/loadavg 2>/dev/null || true)"

    if command_exists getconf; then
        core_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    else
        core_count=""
    fi

    if [ -z "${core_count}" ] && [ -r /proc/stat ]; then
        core_count="$(awk '/^cpu[0-9]+ / {count++} END {print count+0}' /proc/stat)"
    fi

    case "${core_count}" in
        ''|*[!0-9]*|0)
            core_count=1
            ;;
    esac

    if [ -n "${load1}" ] && [ -n "${load5}" ] && [ -n "${load15}" ]; then
        awk -v load1="${load1}" -v load5="${load5}" -v load15="${load15}" -v cores="${core_count}" 'BEGIN {
            pct = (load1 / cores) * 100
            if (pct < 0) pct = 0
            printf "%.1f%% load, avg %s %s %s", pct, load1, load5, load15
        }'
        return 0
    fi

    printf '%s\n' "n/a"
}

install_cli_launcher() {
    self_path="$(resolve_self_path)"

    if [ ! -f "${self_path}" ]; then
        echo "unable to resolve panel source path: ${self_path}" >&2
        return 1
    fi

    mkdir -p "${PANEL_INSTALL_DIR}" "$(dirname "${PANEL_LAUNCHER_PATH}")"
    if [ "${self_path}" != "${PANEL_INSTALLED_SCRIPT}" ]; then
        cp "${self_path}" "${PANEL_INSTALLED_SCRIPT}"
        chmod 755 "${PANEL_INSTALLED_SCRIPT}"
    elif [ -f "${PANEL_INSTALLED_SCRIPT}" ]; then
        chmod 755 "${PANEL_INSTALLED_SCRIPT}"
    fi

    cat > "${PANEL_LAUNCHER_PATH}" <<EOF
#!/bin/sh
set -eu
exec sh "${PANEL_INSTALLED_SCRIPT}" "\$@"
EOF
    chmod 755 "${PANEL_LAUNCHER_PATH}"
}

current_service_status() {
    if ! is_installed; then
        printf '%s\n' "NOT INSTALLED"
        return 0
    fi

    if service_is_active; then
        printf '%s\n' "RUNNING"
    else
        printf '%s\n' "STOPPED"
    fi
}

extract_full_url() {
    ip_value="$(find_primary_ip)"
    node_port="$(extract_node_port)"

    if [ "${ip_value}" = "n/a" ] || [ "${node_port}" = "n/a" ]; then
        printf '%s\n' "n/a"
        return 0
    fi

    printf '%s:%s\n' "${ip_value}" "${node_port}"
}

clear_screen() {
    if [ -t 1 ]; then
        printf '\033[H\033[2J'
    fi
}

print_rule() {
    printf '%s\n' "-------------------------------------------------------"
}

press_enter() {
    if [ -t 0 ]; then
        printf '%s' "Press Enter to continue..." >&2
        IFS= read -r _ || true
    fi
}

confirm_action() {
    prompt_text="$1"

    if [ ! -t 0 ]; then
        return 1
    fi

    printf '%s' "${prompt_text}" >&2
    IFS= read -r reply || true

    case "${reply}" in
        y|Y|yes|YES)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

show_text_file() {
    file_path="$1"
    heading="$2"
    lines="${3:-80}"

    clear_screen
    printf '%s\n' "${heading}"
    print_rule

    if [ -f "${file_path}" ]; then
        tail -n "${lines}" "${file_path}" 2>/dev/null || cat "${file_path}" 2>/dev/null || true
    else
        printf '%s\n' "missing file: ${file_path}"
    fi

    press_enter
}

show_service_logs() {
    platform="$(detect_platform)"

    clear_screen
    printf '%s\n' "Service Logs"
    print_rule

    case "${platform}" in
        debian)
            if command_exists journalctl; then
                journalctl --no-pager -u "$(service_unit)" -n 80 2>&1 || true
            else
                printf '%s\n' "journalctl is not available"
            fi
            ;;
        alpine)
            remnanode_log="/var/log/remnanode/remnanode.log"
            remnanode_err="/var/log/remnanode/remnanode.err"
            if [ -f "${remnanode_log}" ]; then
                printf '%s\n' "===== ${remnanode_log} ====="
                tail -n 80 "${remnanode_log}" 2>/dev/null || true
            fi
            if [ -f "${remnanode_err}" ]; then
                printf '%s\n' "===== ${remnanode_err} ====="
                tail -n 80 "${remnanode_err}" 2>/dev/null || true
            fi
            if [ ! -f "${remnanode_log}" ] && [ ! -f "${remnanode_err}" ]; then
                printf '%s\n' "service logs are not available yet"
            fi
            ;;
        *)
            printf '%s\n' "unsupported host"
            ;;
    esac

    press_enter
}

show_status_report() {
    clear_screen
    print_dashboard
    printf '\n'
    printf '%s\n' "Detailed Service Status"
    print_rule
    show_service_status_output

    supervisor_socket="$(extract_env_value "${REMNANODE_ENV_FILE}" SUPERVISORD_SOCKET_PATH || true)"
    supervisor_user="$(extract_env_value "${REMNANODE_ENV_FILE}" SUPERVISORD_USER || true)"
    supervisor_password="$(extract_env_value "${REMNANODE_ENV_FILE}" SUPERVISORD_PASSWORD || true)"

    if command_exists supervisorctl && [ -n "${supervisor_socket}" ] && [ -S "${supervisor_socket}" ]; then
        printf '\n%s\n' "Supervisor Xray Status"
        print_rule
        run_supervisorctl_status "${supervisor_socket}" "${supervisor_user}" "${supervisor_password}" xray 2>&1 || print_xray_process_fallback
    fi

    press_enter
}

run_supervisorctl_status() {
    supervisor_socket="$1"
    supervisor_user="$2"
    supervisor_password="$3"
    program_name="$4"
    work_dir="$(make_temp_dir "supervisorctl")"
    config_path="${work_dir}/supervisorctl.conf"

    cat > "${config_path}" <<EOF
[supervisorctl]
serverurl=unix://${supervisor_socket}
EOF

    if [ -n "${supervisor_user}" ]; then
        printf 'username=%s\n' "${supervisor_user}" >> "${config_path}"
    fi

    if [ -n "${supervisor_password}" ]; then
        printf 'password=%s\n' "${supervisor_password}" >> "${config_path}"
    fi

    if supervisorctl -c "${config_path}" status "${program_name}"; then
        rm -rf "${work_dir}"
        return 0
    fi

    rm -rf "${work_dir}"
    return 1
}

print_xray_process_fallback() {
    if pgrep -x xray >/dev/null 2>&1 || pgrep -x rw-core >/dev/null 2>&1; then
        printf '%s\n' "xray RUNNING (process fallback)"
    else
        printf '%s\n' "xray STOPPED (process fallback)"
    fi
}

print_colored_title() {
    color_code="$1"
    icon="$2"
    title_text="$3"

    if [ -n "${ANSI_BOLD}" ]; then
        printf '%b%s %s%b\n' "${ANSI_BOLD}${color_code}" "${icon}" "${title_text}" "${ANSI_RESET}"
    else
        printf '%s %s\n' "${icon}" "${title_text}"
    fi
}

resolve_local_or_remote_script() {
    script_name="$1"
    script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

    if [ -f "${script_dir}/${script_name}" ]; then
        printf '%s\n' "${script_dir}/${script_name}"
        return 0
    fi

    work_dir="$(make_temp_dir "download")"
    script_path="${work_dir}/${script_name}"
    script_url="https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_REF}/scripts/${script_name}"

    printf '%s\n' "downloading ${script_url}" >&2
    download_file "${script_url}" "${script_path}"
    printf '%s\n' "${script_path}"
}

run_remote_script() {
    script_name="$1"
    runtime_value="${2:-${RUNTIME_VERSION}}"
    script_path="$(resolve_local_or_remote_script "${script_name}")"
    work_dir=""

    case "${script_path}" in
        "${PANEL_WORK_ROOT}"/*)
            work_dir="$(dirname "${script_path}")"
            ;;
    esac

    env BASE_DIR="${BASE_DIR}" REPO_REF="${REPO_REF}" RUNTIME_VERSION="${runtime_value}" sh "${script_path}" "${REPO_SLUG}" "${runtime_value}"

    if [ -n "${work_dir}" ] && [ -d "${work_dir}" ]; then
        rm -rf "${work_dir}"
    fi
}

resolve_xray_asset_name() {
    arch_name="$(uname -m)"

    case "${arch_name}" in
        x86_64)
            printf '%s\n' Xray-linux-64.zip
            ;;
        aarch64)
            printf '%s\n' Xray-linux-arm64-v8a.zip
            ;;
        armv7*|armv6*|armhf)
            printf '%s\n' Xray-linux-arm32-v7a.zip
            ;;
        *)
            echo "unsupported arch: ${arch_name}" >&2
            return 1
            ;;
    esac
}

ensure_xray_update_prereqs() {
    if command_exists unzip && { command_exists curl || command_exists wget; }; then
        return 0
    fi

    platform="$(detect_platform)"

    case "${platform}" in
        debian)
            if command_exists apt-get; then
                export DEBIAN_FRONTEND=noninteractive
                apt-get update
                apt-get install -y --no-install-recommends ca-certificates curl unzip
            fi
            ;;
        alpine)
            if command_exists apk; then
                apk add --no-cache --upgrade curl unzip
            fi
            ;;
    esac

    if ! command_exists unzip || { ! command_exists curl && ! command_exists wget; }; then
        echo "missing curl/wget or unzip" >&2
        return 1
    fi
}

update_xray_core() {
    ensure_xray_update_prereqs

    asset_name="$(resolve_xray_asset_name)"
    work_dir="$(make_temp_dir "xray")"
    archive_path="${work_dir}/xray.zip"
    unpack_dir="${work_dir}/unpacked"

    mkdir -p "${unpack_dir}" /usr/local/bin /usr/local/share/xray /etc/xray
    download_file "https://github.com/XTLS/Xray-core/releases/latest/download/${asset_name}" "${archive_path}"
    unzip -o "${archive_path}" -d "${unpack_dir}" >/dev/null

    if [ ! -f "${unpack_dir}/xray" ]; then
        rm -rf "${work_dir}"
        echo "xray archive did not contain the xray binary" >&2
        return 1
    fi

    install -m 0755 "${unpack_dir}/xray" /usr/local/bin/xray
    ln -sf /usr/local/bin/xray /usr/local/bin/rw-core

    if [ -f "${unpack_dir}/geoip.dat" ]; then
        install -m 0644 "${unpack_dir}/geoip.dat" /usr/local/share/xray/geoip.dat
    fi

    if [ -f "${unpack_dir}/geosite.dat" ]; then
        install -m 0644 "${unpack_dir}/geosite.dat" /usr/local/share/xray/geosite.dat
    fi

    rm -rf "${work_dir}"

    if is_installed; then
        service_control restart || true
    fi

    printf '%s\n' "updated xray-core to $(extract_xray_version)"
}

edit_configuration() {
    editor_cmd="${EDITOR:-}"

    if [ -z "${editor_cmd}" ]; then
        for candidate in vi vim nano; do
            if command_exists "${candidate}"; then
                editor_cmd="${candidate}"
                break
            fi
        done
    fi

    if [ -z "${editor_cmd}" ]; then
        printf '%s\n' "missing editor; set EDITOR or install vi/nano" >&2
        return 1
    fi

    while :; do
        clear_screen
        printf '%s\n' "Edit Configuration"
        print_rule
        printf '%s\n' "1) remnanode env (${REMNANODE_ENV_FILE})"
        printf '%s\n' "2) xray config (${XRAY_CONFIG_FILE})"
        printf '%s\n' "3) release config (${GITHUB_RELEASE_ENV_FILE})"
        printf '%s\n' "0) back"
        printf '\n%s' "Choose file: " >&2
        IFS= read -r selection || true

        case "${selection}" in
            1)
                mkdir -p "$(dirname "${REMNANODE_ENV_FILE}")"
                [ -f "${REMNANODE_ENV_FILE}" ] || : > "${REMNANODE_ENV_FILE}"
                "${editor_cmd}" "${REMNANODE_ENV_FILE}"
                if confirm_action "Restart remnanode service now? [y/N]: "; then
                    service_control restart || true
                fi
                return 0
                ;;
            2)
                mkdir -p "$(dirname "${XRAY_CONFIG_FILE}")"
                if [ ! -f "${XRAY_CONFIG_FILE}" ] && [ -f /etc/xray/config.json.example ]; then
                    cp /etc/xray/config.json.example "${XRAY_CONFIG_FILE}"
                fi
                "${editor_cmd}" "${XRAY_CONFIG_FILE}"
                if confirm_action "Restart remnanode service now? [y/N]: "; then
                    service_control restart || true
                fi
                return 0
                ;;
            3)
                mkdir -p "$(dirname "${GITHUB_RELEASE_ENV_FILE}")"
                [ -f "${GITHUB_RELEASE_ENV_FILE}" ] || : > "${GITHUB_RELEASE_ENV_FILE}"
                "${editor_cmd}" "${GITHUB_RELEASE_ENV_FILE}"
                return 0
                ;;
            0|'')
                return 0
                ;;
        esac
    done
}

uninstall_remnanode() {
    if ! is_installed && [ ! -e /usr/local/bin/xray ] && [ ! -e /etc/systemd/system/remnanode.service ] && [ ! -e /etc/init.d/remnanode ]; then
        printf '%s\n' "nothing to uninstall"
        return 0
    fi

    if ! confirm_action "This will remove remnanode-lite, configs, logs, runtime files, and xray-core. Continue? [y/N]: "; then
        printf '%s\n' "uninstall cancelled"
        return 0
    fi

    platform="$(detect_platform)"

    case "${platform}" in
        debian)
            systemctl stop "$(service_unit)" >/dev/null 2>&1 || true
            systemctl disable "$(service_unit)" >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/remnanode.service
            systemctl daemon-reload >/dev/null 2>&1 || true
            ;;
        alpine)
            rc-service "$(service_name)" stop >/dev/null 2>&1 || true
            rc-update del "$(service_name)" default >/dev/null 2>&1 || true
            rm -f /etc/init.d/remnanode /etc/conf.d/remnanode
            ;;
    esac

    pkill -x supervisord >/dev/null 2>&1 || true
    pkill -x xray >/dev/null 2>&1 || true
    pkill -x rw-core >/dev/null 2>&1 || true

    rm -f /usr/local/bin/remnanode-start
    rm -f /usr/local/bin/xray
    rm -f /usr/local/bin/rw-core
    rm -f "${PANEL_LAUNCHER_PATH}"
    rm -f "${PANEL_INSTALLED_SCRIPT}"
    rmdir "${PANEL_INSTALL_DIR}" >/dev/null 2>&1 || true
    rm -f /etc/supervisord.conf
    rm -rf /etc/remnanode
    rm -rf /etc/xray
    rm -rf /usr/local/share/xray
    rm -rf "${BASE_DIR}"
    rm -rf /var/log/remnanode
    rm -f /run/remnanode.pid /run/remnanode-internal.sock /run/supervisord.sock /run/supervisord.pid

    printf '%s\n' "remnanode-lite has been uninstalled"
}

print_dashboard() {
    print_colored_title "${ANSI_MAGENTA}" "🚀" "${PANEL_TITLE}"
    print_rule
    printf '\n'
    print_colored_title "${ANSI_GREEN}" "✅" "Node Status"
    printf '  %-16s %s\n' "Current:" "${SNAPSHOT_STATUS}"
    printf '\n'
    print_colored_title "${ANSI_BLUE}" "🌐" "Connection Information"
    printf '  %-16s %s\n' "IP Address:" "${SNAPSHOT_IP}"
    printf '  %-16s %s\n' "Port:" "${SNAPSHOT_PORT}"
    printf '  %-16s %s\n' "Full URL:" "${SNAPSHOT_FULL_URL}"

    printf '\n'
    print_colored_title "${ANSI_CYAN}" "⚙️" "Components Status"
    printf '  %-16s %s\n' "Remnanode:" "${SNAPSHOT_RUNTIME_VERSION}"
    printf '  %-16s %s (%s)\n' "Xray Core:" "${SNAPSHOT_XRAY_VERSION}" "${SNAPSHOT_XRAY_STATE}"

    printf '\n'
    print_colored_title "${ANSI_YELLOW}" "💾" "Resource Usage"
    printf '  %-16s %s\n' "CPU Load:" "${SNAPSHOT_CPU_LOAD}"
    printf '  %-16s %s\n' "Memory:" "${SNAPSHOT_MEMORY_USAGE}"
    printf '  %-16s %s\n' "Disk Usage:" "${SNAPSHOT_DISK_USAGE}"
}

capture_dashboard_snapshot() {
    SNAPSHOT_STATUS="$(current_service_status)"
    SNAPSHOT_IP="$(find_primary_ip)"
    SNAPSHOT_PORT="$(extract_node_port)"
    SNAPSHOT_FULL_URL="$(extract_full_url)"
    SNAPSHOT_RUNTIME_VERSION="$(extract_runtime_version)"
    SNAPSHOT_XRAY_VERSION="$(extract_xray_version)"
    SNAPSHOT_XRAY_STATE="$(extract_xray_component_state)"
    SNAPSHOT_CPU_LOAD="$(extract_cpu_load)"
    SNAPSHOT_MEMORY_USAGE="$(extract_memory_usage)"
    SNAPSHOT_DISK_USAGE="$(extract_disk_usage)"
}

refresh_dashboard_snapshot() {
    load_saved_defaults
    capture_dashboard_snapshot
}

print_menu() {
    printf '\n'
    print_colored_title "${ANSI_GREEN}" "🛠️" "Installation & Management"
    printf '%s\n' "  1) Install remnanode-lite"
    printf '%s\n' "  2) Start node services"
    printf '%s\n' "  3) Stop node services"
    printf '%s\n' "  4) Restart node services"
    printf '%s\n' "  5) Uninstall remnanode-lite"

    printf '\n'
    print_colored_title "${ANSI_BLUE}" "📊" "Monitoring & Logs"
    printf '%s\n' "  6) Show node status"
    printf '%s\n' "  7) View service logs"
    printf '%s\n' "  8) View Xray output logs"
    printf '%s\n' "  9) View Xray error logs"

    printf '\n'
    print_colored_title "${ANSI_CYAN}" "⚙️" "Updates & Configuration"
    printf '%s\n' " 10) Update remnanode-lite"
    printf '%s\n' " 11) Update xray-core"
    printf '%s\n' " 12) Edit configuration"
    printf '%s\n' "  0) Exit"
}

run_tui() {
    while :; do
        clear_screen
        print_dashboard
        print_menu
        printf '\n%s' "Choose an option: " >&2
        IFS= read -r selection || true

        case "${selection}" in
            1)
                if ! run_remote_script one-click-deploy.sh "${RUNTIME_VERSION}"; then
                    printf '%s\n' "install failed" >&2
                else
                    install_cli_launcher || true
                    refresh_dashboard_snapshot
                fi
                press_enter
                ;;
            2)
                run_service_action start || true
                refresh_dashboard_snapshot
                press_enter
                ;;
            3)
                run_service_action stop || true
                refresh_dashboard_snapshot
                press_enter
                ;;
            4)
                run_service_action restart || true
                refresh_dashboard_snapshot
                press_enter
                ;;
            5)
                uninstall_remnanode
                refresh_dashboard_snapshot
                press_enter
                ;;
            6)
                show_status_report
                ;;
            7)
                show_service_logs
                ;;
            8)
                show_text_file /var/log/remnanode/xray.log "Xray Output Logs" 80
                ;;
            9)
                show_text_file /var/log/remnanode/xray.err "Xray Error Logs" 80
                ;;
            10)
                if ! run_remote_script one-click-upgrade.sh "${RUNTIME_VERSION}"; then
                    printf '%s\n' "update failed" >&2
                else
                    install_cli_launcher || true
                    refresh_dashboard_snapshot
                fi
                press_enter
                ;;
            11)
                if ! update_xray_core; then
                    printf '%s\n' "xray-core update failed" >&2
                fi
                refresh_dashboard_snapshot
                press_enter
                ;;
            12)
                edit_configuration || true
                refresh_dashboard_snapshot
                ;;
            0|q|Q|quit|QUIT|exit|EXIT)
                exit 0
                ;;
            *)
                printf '%s\n' "invalid selection: ${selection:-<empty>}" >&2
                press_enter
                ;;
        esac

    done
}

print_status_once() {
    print_dashboard
    printf '\n%s\n' "Detailed Service Status"
    print_rule
    show_service_status_output
}

normalize_action() {
    case "$1" in
        1|install|INSTALL)
            printf '%s\n' install
            ;;
        2|update|UPDATE|upgrade|UPGRADE)
            printf '%s\n' update
            ;;
        tui|TUI|menu|MENU|panel|PANEL)
            printf '%s\n' tui
            ;;
        start|START)
            printf '%s\n' start
            ;;
        stop|STOP)
            printf '%s\n' stop
            ;;
        restart|RESTART)
            printf '%s\n' restart
            ;;
        status|STATUS|info|INFO)
            printf '%s\n' status
            ;;
        logs|LOGS)
            printf '%s\n' logs
            ;;
        xray-log|xray-out|XRAY-LOG|XRAY-OUT)
            printf '%s\n' xray-log
            ;;
        xray-err|xray-error|XRAY-ERR|XRAY-ERROR)
            printf '%s\n' xray-err
            ;;
        update-xray|xray-update|UPDATE-XRAY|XRAY-UPDATE)
            printf '%s\n' update-xray
            ;;
        edit-config|config|EDIT-CONFIG|CONFIG)
            printf '%s\n' edit-config
            ;;
        uninstall|UNINSTALL|remove|REMOVE)
            printf '%s\n' uninstall
            ;;
        auto|'')
            printf '%s\n' auto
            ;;
        help|-h|--help)
            printf '%s\n' help
            ;;
        *)
            echo "invalid action: $1" >&2
            exit 1
            ;;
    esac
}

print_usage() {
    cat <<EOF
Usage:
  sh one-click-panel.sh [action] [repo_slug] [repo_ref] [runtime_version]

Actions:
  auto         open the TUI when interactive, otherwise choose install/update
  install      install remnanode-lite
  update       update remnanode-lite
  tui          open the management TUI
  start        start node services
  stop         stop node services
  restart      restart node services
  status       show the status dashboard
  logs         show service logs
  xray-log     show Xray output logs
  xray-err     show Xray error logs
  update-xray  update xray-core only
  edit-config  edit remnanode/xray config files
  uninstall    remove remnanode-lite and xray-core
EOF
}

choose_default_action() {
    if is_installed; then
        printf '%s\n' update
    else
        printf '%s\n' install
    fi
}

require_root
init_terminal_style
load_saved_defaults
capture_dashboard_snapshot

selected_action="$(normalize_action "${ACTION}")"

if [ "${selected_action}" = "auto" ]; then
    if [ -t 0 ]; then
        selected_action="tui"
    else
        selected_action="$(choose_default_action)"
    fi
fi

case "${selected_action}" in
    install)
        run_remote_script one-click-deploy.sh "${RUNTIME_VERSION}"
        install_cli_launcher
        ;;
    update)
        if ! is_installed; then
            printf '%s\n' "remnanode is not installed yet; switching to install" >&2
            run_remote_script one-click-deploy.sh "${RUNTIME_VERSION}"
            install_cli_launcher
        else
            run_remote_script one-click-upgrade.sh "${RUNTIME_VERSION}"
            install_cli_launcher
        fi
        ;;
    tui)
        run_tui
        ;;
    start)
        run_service_action start
        ;;
    stop)
        run_service_action stop
        ;;
    restart)
        run_service_action restart
        ;;
    status)
        print_status_once
        ;;
    logs)
        show_service_logs
        ;;
    xray-log)
        show_text_file /var/log/remnanode/xray.log "Xray Output Logs" 80
        ;;
    xray-err)
        show_text_file /var/log/remnanode/xray.err "Xray Error Logs" 80
        ;;
    update-xray)
        update_xray_core
        ;;
    edit-config)
        edit_configuration
        ;;
    uninstall)
        uninstall_remnanode
        ;;
    help)
        print_usage
        ;;
esac
