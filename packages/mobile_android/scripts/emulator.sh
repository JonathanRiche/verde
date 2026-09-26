#!/usr/bin/env bash
# Starts the verde-pixel AVD in the foreground and waits (bounded) for boot.
# The emulator stays attached to this process: Ctrl+C, `adb emu kill`, or
# closing the window stops it. See docs/mobile-device-testing.md "Emulator".
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: mise run mobile-android-emulator [-- [--headless] [--avd NAME] [--timeout SECONDS] [--wipe] [--dns-server IP]]

  --headless        run without a window (-no-window, no audio)
  --avd NAME        AVD to start (default: verde-pixel, or $VERDE_AVD)
  --timeout SECONDS boot deadline (default: 300)
  --wipe            wipe user data (fresh install state)
  --dns-server IP   override the emulator's upstream DNS (default: host resolver)
EOF
}

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
adb="$ANDROID_HOME/platform-tools/adb"
emulator="$ANDROID_HOME/emulator/emulator"

avd="${VERDE_AVD:-verde-pixel}"
timeout_s=300
headless=0
extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --headless) headless=1 ;;
    --avd) avd="$2"; shift ;;
    --timeout) timeout_s="$2"; shift ;;
    --wipe) extra+=(-wipe-data) ;;
    --dns-server) extra+=(-dns-server "$2"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  echo "error: /dev/kvm is not accessible to $(id -un); run: sudo usermod -aG kvm $(id -un) (then log in again)" >&2
  exit 1
fi
if [[ ! -x "$emulator" ]]; then
  echo "error: $emulator missing; install with:" >&2
  echo "  mise exec java@openjdk-17 -- $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager emulator 'system-images;android-35;google_apis;x86_64'" >&2
  exit 1
fi
if ! "$emulator" -list-avds 2>/dev/null | grep -qx "$avd"; then
  echo "error: AVD '$avd' not found in $ANDROID_AVD_HOME; create it with:" >&2
  echo "  echo no | ANDROID_AVD_HOME=$ANDROID_AVD_HOME mise exec java@openjdk-17 -- $ANDROID_HOME/cmdline-tools/latest/bin/avdmanager create avd -n $avd -k 'system-images;android-35;google_apis;x86_64' -d pixel_8" >&2
  exit 1
fi

"$adb" start-server >/dev/null

# Already running? Report its serial instead of starting a second instance.
for serial in $("$adb" devices | awk '$1 ~ /^emulator-/ {print $1}'); do
  if [[ "$("$adb" -s "$serial" emu avd name 2>/dev/null | head -n1 | tr -d '\r')" == "$avd" ]]; then
    echo "$avd is already running as $serial"
    exit 0
  fi
done

# Pick a free console port so the serial (emulator-PORT) is known up front.
used="$("$adb" devices | awk '$1 ~ /^emulator-/ {sub("emulator-", "", $1); print $1}')"
port=""
for p in $(seq 5554 2 5584); do
  if ! grep -qx "$p" <<<"$used" && ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
    port="$p"
    break
  fi
done
[[ -n "$port" ]] || { echo "error: no free emulator console port in 5554-5584" >&2; exit 1; }
serial="emulator-$port"

args=(-avd "$avd" -port "$port" -no-snapshot-save -no-boot-anim "${extra[@]}")
if [[ $headless -eq 1 ]]; then
  args+=(-no-window -no-audio -gpu swiftshader_indirect)
fi

echo "starting: $emulator ${args[*]}"
# The emulator is a child of this foreground process and dies with it.
"$emulator" "${args[@]}" &
emu_pid=$!
cleanup() {
  if kill -0 "$emu_pid" 2>/dev/null; then
    "$adb" -s "$serial" emu kill >/dev/null 2>&1 || kill "$emu_pid" 2>/dev/null || true
    wait "$emu_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

deadline=$((SECONDS + timeout_s))
booted=0
while ((SECONDS < deadline)); do
  if ! kill -0 "$emu_pid" 2>/dev/null; then
    wait "$emu_pid" && status=0 || status=$?
    echo "error: emulator exited during boot (status $status)" >&2
    trap - EXIT
    exit 1
  fi
  if [[ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; then
    booted=1
    break
  fi
  sleep 2
done
if [[ $booted -ne 1 ]]; then
  echo "error: $avd did not finish booting within ${timeout_s}s; stopping it" >&2
  exit 1
fi

# Keep the screen on while plugged in so screenshots and UI checks work.
"$adb" -s "$serial" shell svc power stayon true >/dev/null 2>&1 || true
"$adb" -s "$serial" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
"$adb" -s "$serial" shell wm dismiss-keyguard >/dev/null 2>&1 || true

echo "BOOTED $avd as $serial after ${SECONDS}s. Install with: mise run mobile-android-install"
echo "Stop with Ctrl+C here, or: $adb -s $serial emu kill"
wait "$emu_pid" && status=0 || status=$?
trap - EXIT
exit "$status"
