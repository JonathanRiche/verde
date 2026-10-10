#!/usr/bin/env bash
# Fixture tests only: no Mac, VNC service, sockets, or privileged commands needed.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$script_dir/macos-screen-sharing.sh"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
mkdir "$fixture_dir/bin"
export FIXTURE_DIR="$fixture_dir"
export PATH="$fixture_dir/bin:$PATH"

cat > "$fixture_dir/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FIXTURE_OS:-Darwin}"
EOF
cat > "$fixture_dir/bin/lsof" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FIXTURE_DIR/call"
cat "$FIXTURE_DIR/listeners"
printf '%s\n' 'PRIVATE_TOOL_ERROR' >&2
exit "${FIXTURE_STATUS:-0}"
EOF
chmod +x "$fixture_dir/bin/uname" "$fixture_dir/bin/lsof"
export FIXTURE_OS=Darwin FIXTURE_STATUS=0

run_case() {
  local expected_status="$1" expected_text="$2" status=0
  shift 2
  bash "$helper" "$@" > "$fixture_dir/output" 2>&1 || status=$?
  if [[ "$status" != "$expected_status" ]] || ! grep -Fq "$expected_text" "$fixture_dir/output"; then
    echo 'FAIL: unexpected helper status or diagnostic' >&2
    cat "$fixture_dir/output" >&2
    exit 1
  fi
  if grep -Eq 'PRIVATE_TOOL_ERROR|SECRET_SENTINEL|PRIVATE_PROCESS' "$fixture_dir/output"; then
    echo 'FAIL: helper echoed private fixture data' >&2
    exit 1
  fi
}

run_case 0 'Usage:' --help
run_case 0 'No service is started' --guide
run_case 2 'Usage:' --diagnose
run_case 2 'Usage:' --diagnose --port 0
run_case 2 'Usage:' --diagnose --port 65536
run_case 2 'Usage:' --diagnose --port 05900
run_case 2 'Usage:' --diagnose --port '-1'
run_case 2 'Usage:' --diagnose --port '5900;SECRET_SENTINEL'
run_case 2 'Usage:' --diagnose --port 5900 --password SECRET_SENTINEL
run_case 2 'Usage:' --guide SECRET_SENTINEL
[[ ! -e "$fixture_dir/call" ]]

FIXTURE_OS=Linux run_case 3 'requires macOS' --diagnose --port 5900
[[ ! -e "$fixture_dir/call" ]]
printf 'p123\ncPRIVATE_PROCESS\nn127.0.0.1:5900\np456\nn[::1]:5900\n' > "$fixture_dir/listeners"
run_case 0 'only loopback records' --diagnose --port 5900
printf '%s\n' -nP -a -iTCP:5900 -sTCP:LISTEN -Fn > "$fixture_dir/expected-call"
cmp "$fixture_dir/expected-call" "$fixture_dir/call"

printf 'p123\nn*:5900\nn127.0.0.1:5900\n' > "$fixture_dir/listeners"
run_case 1 'outside recognized loopback' --diagnose --port 5900
printf 'p123\nn[::]:5900\n' > "$fixture_dir/listeners"
run_case 1 'outside recognized loopback' --diagnose --port 5900
printf 'p123\nn192.0.2.4:5900\n' > "$fixture_dir/listeners"
run_case 1 'outside recognized loopback' --diagnose --port 5900
printf 'p123\nnunrecognized\n' > "$fixture_dir/listeners"
run_case 1 'outside recognized loopback' --diagnose --port 5900
printf 'p123\nn127.0.0.1:65535\n' > "$fixture_dir/listeners"
run_case 0 'only loopback records' --diagnose --port 65535
FIXTURE_STATUS=1 run_case 3 'no reliable listener inventory' --diagnose --port 65535
: > "$fixture_dir/listeners"
run_case 3 'no reliable listener inventory' --diagnose --port 5900
FIXTURE_STATUS=1 run_case 3 'no reliable listener inventory' --diagnose --port 5900

echo 'PASS: macOS helper argument handling, passive invocation, exposure classification, and redaction fixtures.'
echo 'No native macOS or noVNC compatibility validation was performed.'
