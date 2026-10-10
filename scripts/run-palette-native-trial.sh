#!/usr/bin/env bash
# Runs the palette-native port of Verde fully isolated from the user's Verde.
#
#   scripts/run-palette-native-trial.sh [--visible] [--no-build]
#
# - Builds this worktree if zig-out/bin/verde is missing or older than the sources.
# - HOME and every XDG_* dir point into a persistent trial root
#   (~/.local/share/verde-palette-trial), so the data dir, daemon socket, live
#   endpoint and browser profile are separate from the real ones.
# - By default the app id is palette-test-verde, which Hyprland sends to the hidden
#   PALETTE-TEST output (workspace 99). The script refuses to start that way unless
#   workspace 99 is on PALETTE-TEST. --visible uses the normal-looking app id
#   verde-palette-trial instead, and the window opens like any other.
# - Ctrl-C (or the app quitting) stops every process started under the trial root.
set -euo pipefail

visible=0
build=1
for arg in "$@"; do
  case "$arg" in
    --visible) visible=1 ;;
    --no-build) build=0 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${VERDE_PALETTE_TRIAL_ROOT:-$HOME/.local/share/verde-palette-trial}"
real_home="$HOME"
bin="$repo/zig-out/bin/verde"

if [[ "$root" == "$real_home" || "$root" == "$real_home/.local/share/verde"* ]]; then
  echo "refusing: trial root $root overlaps the real Verde data" >&2
  exit 1
fi

if [[ $build == 1 ]]; then
  if [[ ! -x "$bin" ]] || [[ -n "$(find "$repo/packages/desktop/src" "$repo/packages/palette/src" -newer "$bin" -print -quit)" ]]; then
    echo "building $repo"
    (cd "$repo" && zig build --release=safe -Dbrowser-backend=native_webview)
  fi
fi

if [[ $visible == 1 ]]; then
  app_id=verde-palette-trial
else
  app_id=palette-test-verde
  if command -v hyprctl >/dev/null; then
    ws_monitor="$(hyprctl workspaces -j | python3 -c 'import json,sys; print(next((w["monitor"] for w in json.load(sys.stdin) if w["name"]=="99"), ""))')"
    if [[ "$ws_monitor" != "PALETTE-TEST" ]]; then
      echo "refusing: workspace 99 is not on PALETTE-TEST (got '${ws_monitor:-none}'); use --visible" >&2
      exit 1
    fi
  fi
fi

mkdir -p "$root"/{.config/verde,.local/share,.local/state,.cache,run}
chmod 700 "$root/run"
config="$root/.config/verde/verde.json"
[[ -f "$config" ]] || echo '{"updates":{"check_automatically":false},"notifications":{"enabled":false}}' > "$config"
data="$root/.local/share/verde/Native"

wayland="${WAYLAND_DISPLAY:-wayland-0}"
[[ "$wayland" == /* ]] || wayland="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$wayland"

# Drop everything that would point the trial at the user's Verde or herdr.
unset_vars=()
while IFS= read -r name; do unset_vars+=(-u "$name"); done < <(env | sed -n 's/^\(VERDE_[A-Z0-9_]*\|HERDR_[A-Z0-9_]*\|SDL_[A-Z0-9_]*\)=.*/\1/p')

echo "trial root:    $root"
echo "data dir:      $data"
echo "live endpoint: $data/verde.sock"
echo "app id:        $app_id"

trial_env=(env "${unset_vars[@]}"
  HOME="$root"
  XDG_CONFIG_HOME="$root/.config"
  XDG_DATA_HOME="$root/.local/share"
  XDG_STATE_HOME="$root/.local/state"
  XDG_CACHE_HOME="$root/.cache"
  XDG_RUNTIME_DIR="$root/run"
  WAYLAND_DISPLAY="$wayland"
  VERDE_LIVE_ENDPOINT="$data/verde.sock"
  VERDE_APP_ID="$app_id")

cleanup() {
  # Only processes whose environment carries the trial HOME; never by name.
  for sig in TERM KILL; do
    pids=()
    for pid in $(pgrep -u "$(id -u)"); do
      { tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null | grep -qx "HOME=$root" && [[ $pid != $$ ]] && pids+=("$pid")
    done
    [[ ${#pids[@]} == 0 ]] && break
    kill -"$sig" "${pids[@]}" 2>/dev/null || true
    sleep 1
  done
}
trap cleanup EXIT INT TERM

"${trial_env[@]}" "$bin" app &
app_pid=$!

if [[ $visible == 0 ]] && command -v hyprctl >/dev/null; then
  # The window must land on workspace 99 without focus; otherwise stop at once.
  placement=NOWINDOW
  for _ in $(seq 1 40); do
    placement="$(hyprctl clients -j | python3 -c '
import json,sys
cs=[c for c in json.load(sys.stdin) if c["class"]==sys.argv[1]]
if not cs: print("NOWINDOW")
else: print("OK" if all(c["workspace"]["name"]=="99" and c["focusHistoryID"]!=0 for c in cs) else "BAD")' "$app_id")"
    [[ $placement != NOWINDOW ]] && break
    kill -0 "$app_pid" 2>/dev/null || break
    sleep 0.25
  done
  if [[ $placement != OK ]]; then
    echo "window placement check failed ($placement); stopping the trial" >&2
    exit 1
  fi
  echo "window is on hidden workspace 99, unfocused"
fi

wait "$app_pid"
