#!/bin/sh

set -eu

ROOT="${1:-/}"
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SELF_DIR}/.." && pwd)

set_owner_if_exists() {
    owner_spec="$1"
    target_path="$2"

    if id remnanode >/dev/null 2>&1; then
        chown "${owner_spec}" "${target_path}"
    fi
}

fix_remnanode_permissions() {
    if ! id remnanode >/dev/null 2>&1; then
        return 0
    fi

    if [ -d "${ROOT}/etc/remnanode" ]; then
        chown root:remnanode "${ROOT}/etc/remnanode"
        chmod 750 "${ROOT}/etc/remnanode"
    fi

    for env_file in \
        "${ROOT}/etc/remnanode/remnanode.env" \
        "${ROOT}/etc/remnanode/xray.env" \
        "${ROOT}/etc/remnanode/github-release.env"
    do
        if [ -f "${env_file}" ]; then
            chown root:remnanode "${env_file}"
            chmod 640 "${env_file}"
        fi
    done
}

install_file() {
    src="$1"
    dst="$2"
    mode="$3"
    install_dir=$(dirname "${ROOT}${dst}")
    install -d -m 755 "${install_dir}"
    install -m "${mode}" "${src}" "${ROOT}${dst}"
}

install_if_missing() {
    src="$1"
    dst="$2"
    mode="$3"

    if [ ! -e "${ROOT}${dst}" ]; then
        install_dir=$(dirname "${ROOT}${dst}")
        install -d -m 755 "${install_dir}"
        install -m "${mode}" "${src}" "${ROOT}${dst}"
    fi
}

install_file "${REPO_ROOT}/scripts/remnanode-start.sh" /usr/local/bin/remnanode-start 755
install_file "${REPO_ROOT}/scripts/xray-start.sh" /usr/local/bin/xray-start 755
install_file "${REPO_ROOT}/scripts/create-service-user.sh" /usr/local/bin/create-remnanode-user 755
install_file "${REPO_ROOT}/scripts/install-runtime-bundle.sh" /usr/local/bin/install-remnanode-runtime 755
install_file "${REPO_ROOT}/scripts/preflight-alpine.sh" /usr/local/bin/remnanode-preflight 755
install_file "${REPO_ROOT}/scripts/check-remnanode-layout.sh" /usr/local/bin/check-remnanode-layout 755
install_file "${REPO_ROOT}/scripts/update-from-github-release.sh" /usr/local/bin/remnanode-update-from-github 755
install_file "${REPO_ROOT}/scripts/one-click-deploy.sh" /usr/local/bin/remnanode-one-click-deploy 755
install_file "${REPO_ROOT}/scripts/one-click-upgrade.sh" /usr/local/bin/remnanode-one-click-upgrade 755
install_file "${REPO_ROOT}/scripts/one-click-panel.sh" /usr/local/bin/remnanode-panel 755
install_file "${REPO_ROOT}/deploy/openrc/remnanode" /etc/init.d/remnanode 755
install_file "${REPO_ROOT}/deploy/openrc/xray" /etc/init.d/xray 755
install_file "${REPO_ROOT}/deploy/openrc/conf.d/remnanode" /etc/conf.d/remnanode 644
install_file "${REPO_ROOT}/deploy/openrc/conf.d/xray" /etc/conf.d/xray 644
install_file "${REPO_ROOT}/config/supervisor/supervisord.conf" /etc/supervisord.conf 644
install_if_missing "${REPO_ROOT}/deploy/env/remnanode.env.example" /etc/remnanode/remnanode.env 640
install_if_missing "${REPO_ROOT}/deploy/env/xray.env.example" /etc/remnanode/xray.env 640
install_if_missing "${REPO_ROOT}/deploy/env/github-release.env.example" /etc/remnanode/github-release.env 640
install_if_missing "${REPO_ROOT}/config/xray/config.json.example" /etc/xray/config.json.example 644

install -d -m 755 "${ROOT}/etc/remnanode"
install -d -m 755 "${ROOT}/etc/xray"
install -d -m 755 "${ROOT}/var/log/remnanode"
install -d -m 755 "${ROOT}/var/log/xray"
install -d -m 755 "${ROOT}/var/log/supervisor"

fix_remnanode_permissions

printf '%s\n' "Installed deployment layout into ${ROOT}"
