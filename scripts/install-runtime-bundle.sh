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
require_cmd mktemp
require_cmd date
require_cmd ln
require_cmd cp
require_cmd mv

if [ ! -f "${BUNDLE_PATH}" ]; then
    echo "bundle not found: ${BUNDLE_PATH}" >&2
    exit 1
fi

mkdir -p "${RELEASES_DIR}"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/remnanode-install.XXXXXX")

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
