#!/bin/sh

set -eu

STATUS=0

ok() {
    printf 'ok   %s\n' "$1"
}

warn() {
    printf 'warn %s\n' "$1"
}

fail() {
    printf 'fail %s\n' "$1" >&2
    STATUS=1
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

check_cmd() {
    if has_cmd "$1"; then
        ok "command $1"
    else
        fail "missing command $1"
    fi
}

check_file() {
    if [ -e "$1" ]; then
        ok "path $1"
    else
        fail "missing path $1"
    fi
}

check_alpine() {
    if [ -f /etc/alpine-release ]; then
        ok "alpine $(cat /etc/alpine-release)"
    else
        warn "host is not reporting Alpine via /etc/alpine-release"
    fi
}

check_memory() {
    if [ -r /proc/meminfo ]; then
        mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
        if [ -n "${mem_kb}" ]; then
            ok "memtotal ${mem_kb} kB"
            if [ "${mem_kb}" -gt 300000 ]; then
                warn "memory is above the ultra-low-memory target; tuning remains conservative"
            fi
        else
            warn "unable to parse /proc/meminfo"
        fi
    else
        warn "cannot read /proc/meminfo"
    fi
}

check_swap() {
    if [ -r /proc/swaps ]; then
        swap_lines=$(awk 'NR>1 {count++} END {print count+0}' /proc/swaps)
        if [ "${swap_lines}" -eq 0 ]; then
            ok "no swap configured"
        else
            warn "swap entries detected in /proc/swaps"
        fi
    else
        warn "cannot read /proc/swaps"
    fi
}

check_node() {
    if ! has_cmd node; then
        fail "missing command node"
        return
    fi

    version=$(node -v 2>/dev/null || true)
    ok "node ${version}"

    major=$(printf '%s' "${version}" | sed 's/^v//' | cut -d. -f1)
    case "${major}" in
        ''|*[!0-9]*)
            warn "unable to parse Node.js major version"
            ;;
        *)
            if [ "${major}" -lt 24 ]; then
                warn "Node.js major version is below 24"
            fi
            ;;
    esac
}

check_xray() {
    if has_cmd xray; then
        ok "command xray"
    elif [ -x /usr/local/bin/xray ]; then
        ok "path /usr/local/bin/xray"
    else
        fail "missing xray binary"
    fi
}

check_rw_core() {
    if [ -x /usr/local/bin/rw-core ]; then
        ok "path /usr/local/bin/rw-core"
    else
        warn "missing /usr/local/bin/rw-core symlink"
    fi
}

check_supervisord() {
    if has_cmd supervisord; then
        ok "command supervisord"
    else
        warn "missing command supervisord"
    fi
}

check_gcompat() {
    if has_cmd apk; then
        if apk info -e gcompat >/dev/null 2>&1; then
            ok "apk package gcompat"
        else
            warn "apk package gcompat not installed"
        fi
    else
        warn "apk not available; cannot check gcompat package"
    fi
}

check_openrc() {
    check_cmd rc-service
    check_cmd rc-update
    check_file /sbin/openrc-run
}

check_ulimit() {
    nofile=$(ulimit -n 2>/dev/null || true)
    if [ -n "${nofile}" ]; then
        ok "current nofile ${nofile}"
        if [ "${nofile}" -lt 65535 ] 2>/dev/null; then
            warn "current shell nofile is below 65535"
        fi
    else
        warn "unable to read current nofile limit"
    fi
}

check_alpine
check_memory
check_swap
check_openrc
check_node
check_xray
check_rw_core
check_supervisord
check_gcompat
check_ulimit

exit "${STATUS}"
