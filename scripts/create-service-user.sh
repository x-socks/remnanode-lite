#!/bin/sh

set -eu

GROUP_NAME="${1:-remnanode}"
USER_NAME="${2:-remnanode}"

if ! grep -q "^${GROUP_NAME}:" /etc/group; then
    addgroup -S "${GROUP_NAME}"
fi

if ! id "${USER_NAME}" >/dev/null 2>&1; then
    adduser -S -D -H -h /nonexistent -s /sbin/nologin -G "${GROUP_NAME}" "${USER_NAME}"
fi

printf '%s\n' "Ensured service user ${USER_NAME}:${GROUP_NAME}"
