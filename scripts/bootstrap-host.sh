#!/bin/sh

set -eu

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <runtime-bundle.tar.gz> [base-dir] [target-root]" >&2
    exit 1
fi

RUNTIME_BUNDLE="$1"
BASE_DIR="${2:-/opt/remnanode}"
TARGET_ROOT="${3:-/}"
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

"${SELF_DIR}/preflight-alpine.sh"
"${SELF_DIR}/create-service-user.sh"
"${SELF_DIR}/install-layout.sh" "${TARGET_ROOT}"
"${TARGET_ROOT}/usr/local/bin/install-remnanode-runtime" "${RUNTIME_BUNDLE}" "${BASE_DIR}"
"${TARGET_ROOT}/usr/local/bin/check-remnanode-layout" "${BASE_DIR}/current"

printf '%s\n' "bootstrap complete"
printf '%s\n' "edit ${TARGET_ROOT}/etc/remnanode/remnanode.env if needed, then start or restart remnanode"
