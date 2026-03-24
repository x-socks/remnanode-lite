#!/bin/sh

set -eu

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <docker-image> [output-dir]" >&2
    exit 1
fi

IMAGE_REF="$1"
OUTPUT_DIR="${2:-./out}"
APP_ROOT="${APP_ROOT:-}"
INCLUDE_PATHS="${INCLUDE_PATHS:-dist node_modules package.json package-lock.json pnpm-lock.yaml npm-shrinkwrap.json prisma apps libs ecosystem.config.js .env.example}"
BUNDLE_STAMP="${BUNDLE_STAMP:-}"
BUNDLE_NAME="${BUNDLE_NAME:-}"
BUNDLE_PATH_FILE="${BUNDLE_PATH_FILE:-}"
IMAGE_DIGEST="${IMAGE_DIGEST:-}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing command: $1" >&2
        exit 1
    fi
}

detect_app_root() {
    cid="$1"
    probe_dir="$2"

    if [ -n "${APP_ROOT}" ]; then
        printf '%s\n' "${APP_ROOT}"
        return 0
    fi

    for candidate in /app /usr/src/app /opt/app /opt/remnanode /srv/app; do
        rm -f "${probe_dir}/package.json"
        if docker cp "${cid}:${candidate}/package.json" "${probe_dir}/package.json" >/dev/null 2>&1; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    return 1
}

copy_path_if_present() {
    cid="$1"
    app_root="$2"
    rel_path="$3"
    target_dir="$4"

    if docker cp "${cid}:${app_root}/${rel_path}" "${target_dir}/${rel_path}" >/dev/null 2>&1; then
        printf 'included %s\n' "${rel_path}"
    else
        printf 'skipped  %s\n' "${rel_path}" >&2
    fi
}

require_cmd docker
require_cmd tar
require_cmd mktemp
require_cmd date

mkdir -p "${OUTPUT_DIR}"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/remnanode-export.XXXXXX")
CONTAINER_ID=""

cleanup() {
    if [ -n "${CONTAINER_ID}" ]; then
        docker rm -f "${CONTAINER_ID}" >/dev/null 2>&1 || true
    fi
    rm -rf "${WORK_DIR}"
}

trap cleanup EXIT INT TERM

CONTAINER_ID=$(docker create "${IMAGE_REF}")
APP_ROOT=$(detect_app_root "${CONTAINER_ID}" "${WORK_DIR}") || {
    echo "failed to detect app root; set APP_ROOT explicitly" >&2
    exit 1
}

STAGE_DIR="${WORK_DIR}/stage"
RUNTIME_DIR="${STAGE_DIR}/runtime"
mkdir -p "${RUNTIME_DIR}"

for rel_path in ${INCLUDE_PATHS}; do
    parent_dir=$(dirname "${RUNTIME_DIR}/${rel_path}")
    mkdir -p "${parent_dir}"
    copy_path_if_present "${CONTAINER_ID}" "${APP_ROOT}" "${rel_path}" "${RUNTIME_DIR}"
done

STAMP="${BUNDLE_STAMP}"
if [ -z "${STAMP}" ]; then
    STAMP="$(date +%Y%m%d-%H%M%S)-$$"
fi

if [ -z "${BUNDLE_NAME}" ]; then
    BUNDLE_NAME="remnanode-runtime-${STAMP}.tar.gz"
fi

cat > "${STAGE_DIR}/manifest.txt" <<EOF
image=${IMAGE_REF}
image_digest=${IMAGE_DIGEST}
app_root=${APP_ROOT}
created_at=${STAMP}
include_paths=${INCLUDE_PATHS}
EOF

tar -C "${STAGE_DIR}" -czf "${OUTPUT_DIR}/${BUNDLE_NAME}" runtime manifest.txt

printf '%s\n' "wrote ${OUTPUT_DIR}/${BUNDLE_NAME}"

if [ -n "${BUNDLE_PATH_FILE}" ]; then
    printf '%s\n' "${OUTPUT_DIR}/${BUNDLE_NAME}" > "${BUNDLE_PATH_FILE}"
fi
