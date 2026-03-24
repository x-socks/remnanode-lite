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
