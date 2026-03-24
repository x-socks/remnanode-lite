#!/bin/sh

set -eu

ENV_FILE="${XRAY_ENV_FILE:-/etc/remnanode/xray.env}"

if [ -f "${ENV_FILE}" ]; then
    set -a
    . "${ENV_FILE}"
    set +a
fi

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-/etc/xray/config.json}"
XRAY_ASSET_DIR="${XRAY_ASSET_DIR:-/usr/local/share/xray}"
NOFILE_LIMIT="${XRAY_ULIMIT_NOFILE:-65535}"

if [ ! -x "${XRAY_BIN}" ]; then
    echo "xray-start: missing xray binary: ${XRAY_BIN}" >&2
    exit 1
fi

if [ ! -f "${XRAY_CONFIG}" ]; then
    echo "xray-start: missing xray config: ${XRAY_CONFIG}" >&2
    exit 1
fi

ulimit -n "${NOFILE_LIMIT}" 2>/dev/null || true

export XRAY_LOCATION_ASSET="${XRAY_ASSET_DIR}"
export GOMAXPROCS="${GOMAXPROCS:-1}"
export GODEBUG="${GODEBUG:-madvdontneed=1}"

exec "${XRAY_BIN}" run -config "${XRAY_CONFIG}"
