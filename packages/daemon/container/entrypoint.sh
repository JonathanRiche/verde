#!/usr/bin/env bash
set -Eeuo pipefail

readonly daemon_bin=/opt/verde/bin/verde-daemon
readonly gateway_bin=/opt/verde/bin/verde-web
readonly static_dir=/opt/verde/share/verde/web
readonly data_dir="${VERDE_DATA_DIR:-/home/verde/.local/share/verde/runtime}"
readonly token_file="${VERDE_WEB_TOKEN_FILE:-/home/verde/.config/verde/web-token}"
readonly gateway_port="${VERDE_GATEWAY_PORT:-6783}"
readonly mode="${VERDE_MODE:-runtime}"

# Administrative startup must target the explicit container data directory,
# never a socket inherited from the shell that launched the container.
unset VERDE_SESSIONIZER_SOCKET

fail() {
    printf 'verde container: %s\n' "$1" >&2
    exit 1
}

require_absolute_path() {
    [[ "$2" == /* ]] || fail "$1 must be an absolute path"
}

initialize_daemon() {
    require_absolute_path VERDE_DATA_DIR "$data_dir"
    install -d -m 0700 "$data_dir"
    "$daemon_bin" init --data-dir "$data_dir"
}

ensure_gateway_token() {
    require_absolute_path VERDE_WEB_TOKEN_FILE "$token_file"
    [[ -z "${VERDE_WEB_TOKEN:-}" ]] || fail 'VERDE_WEB_TOKEN is forbidden; use the owner-only token file'
    [[ ! -L "$token_file" ]] || fail 'the gateway token path must not be a symlink'
    install -d -m 0700 "$(dirname "$token_file")"
    if [[ -e "$token_file" ]]; then
        return
    fi

    local token_tmp
    token_tmp="$(mktemp "${token_file}.tmp.XXXXXX")"
    trap 'rm -f -- "$token_tmp"' RETURN
    chmod 0600 "$token_tmp"
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$token_tmp"
    printf '\n' >>"$token_tmp"
    mv -f -- "$token_tmp" "$token_file"
    trap - RETURN
    printf 'verde container: generated owner-only gateway token at %s\n' "$token_file" >&2
}

run_runtime() {
    [[ "$gateway_port" =~ ^[0-9]+$ ]] || fail 'VERDE_GATEWAY_PORT must be an integer'
    (( gateway_port >= 1 && gateway_port <= 65535 )) || fail 'VERDE_GATEWAY_PORT is outside 1..65535'
    [[ -x "$gateway_bin" ]] || fail 'verde-web is missing from the image'
    [[ -d "$static_dir" ]] || fail 'the built web client is missing from the image'

    ensure_gateway_token
    "$daemon_bin" serve --data-dir "$data_dir" &
    local daemon_pid=$!
    "$gateway_bin" \
        --host 127.0.0.1 \
        --port "$gateway_port" \
        --token-file "$token_file" \
        --pref-path "$data_dir" \
        --static "$static_dir" &
    local gateway_pid=$!

    shutdown_children() {
        trap - EXIT INT TERM
        kill -TERM "$gateway_pid" "$daemon_pid" 2>/dev/null || true
        wait "$gateway_pid" 2>/dev/null || true
        wait "$daemon_pid" 2>/dev/null || true
    }
    trap shutdown_children EXIT INT TERM

    local status=0
    wait -n "$daemon_pid" "$gateway_pid" || status=$?
    shutdown_children
    exit "$status"
}

initialize_daemon
case "$mode" in
    daemon)
        exec "$daemon_bin" serve --data-dir "$data_dir"
        ;;
    runtime)
        run_runtime
        ;;
    *)
        fail 'VERDE_MODE must be daemon or runtime'
        ;;
esac
