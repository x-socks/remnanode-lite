#!/bin/sh

set -eu

ACTION="${1:-${ACTION:-auto}}"
REPO_SLUG="${2:-${REPO_SLUG:-x-socks/remnanode-lite}}"
BASE_DIR="${BASE_DIR:-/opt/remnanode}"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "this script must run as root" >&2
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

is_installed() {
    [ -f /etc/remnanode/remnanode.env ] && [ -e "${BASE_DIR}/current" ]
}

normalize_action() {
    case "$1" in
        1|install|INSTALL)
            printf '%s\n' install
            ;;
        2|update|UPDATE|upgrade|UPGRADE)
            printf '%s\n' update
            ;;
        auto|'')
            printf '%s\n' auto
            ;;
        *)
            echo "invalid action: $1" >&2
            exit 1
            ;;
    esac
}

choose_action() {
    current_action="$(normalize_action "${ACTION}")"

    if [ "${current_action}" != "auto" ]; then
        printf '%s\n' "${current_action}"
        return 0
    fi

    if is_installed; then
        default_action="update"
        default_hint="2"
    else
        default_action="install"
        default_hint="1"
    fi

    if [ ! -t 0 ]; then
        printf '%s\n' "${default_action}"
        return 0
    fi

    cat >&2 <<EOF
Remnanode panel

Choose action:
1. install
2. update

Default: ${default_action}
EOF

    while :; do
        printf '%s' "Action [${default_hint}]: " >&2
        IFS= read -r selected || true
        if [ -z "${selected}" ]; then
            printf '%s\n' "${default_action}"
            return 0
        fi

        case "$(normalize_action "${selected}")" in
            install)
                printf '%s\n' install
                return 0
                ;;
            update)
                printf '%s\n' update
                return 0
                ;;
        esac
    done
}

run_remote_script() {
    script_name="$1"

    WORK_ROOT="${HOME:-/root}/.remnanode-work"
    WORK_DIR="${WORK_ROOT}/panel.$$"
    mkdir -p "${WORK_ROOT}"
    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}"

    cleanup() {
        rm -rf "${WORK_DIR}"
    }

    trap cleanup EXIT INT TERM

    script_path="${WORK_DIR}/${script_name}"
    script_url="https://raw.githubusercontent.com/${REPO_SLUG}/main/scripts/${script_name}"

    printf '%s\n' "downloading ${script_url}"
    download_file "${script_url}" "${script_path}"

    exec env BASE_DIR="${BASE_DIR}" sh "${script_path}" "${REPO_SLUG}"
}

require_root

selected_action="$(choose_action)"

case "${selected_action}" in
    install)
        run_remote_script one-click-deploy.sh
        ;;
    update)
        if ! is_installed; then
            echo "remnanode is not installed yet; switching to install" >&2
            run_remote_script one-click-deploy.sh
        fi
        run_remote_script one-click-upgrade.sh
        ;;
esac
