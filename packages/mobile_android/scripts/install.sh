#!/usr/bin/env bash
# Installs a Verde debug APK on the single connected device/emulator (or
# $ANDROID_SERIAL) and launches it. See docs/mobile-device-testing.md.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: mise run mobile-android-install [-- [--build] [--apk PATH] [--no-launch]]

  --build      run `assembleDebug` first and install the Gradle output
  --apk PATH   install this APK
  (default)    newest app-debug.apk under ../verde-wt/artifacts or the Gradle output
  --no-launch  install only

Target: $ANDROID_SERIAL, otherwise the only connected device/emulator.
EOF
}

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
adb="$ANDROID_HOME/platform-tools/adb"
package="dev.verdeai.app"
android_dir="$(cd "$(dirname "$0")/.." && pwd)"
gradle_apk="$android_dir/app/build/outputs/apk/debug/app-debug.apk"
# The artifacts tree sits beside the main checkout, also when run from a worktree.
common_dir="$(git -C "$android_dir" rev-parse --path-format=absolute --git-common-dir)"
artifacts="${VERDE_ARTIFACTS_DIR:-$(dirname "$(dirname "$common_dir")")/verde-wt/artifacts}"

apk=""
build=0
launch=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) build=1 ;;
    --apk) apk="$2"; shift ;;
    --no-launch) launch=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ $build -eq 1 ]]; then
  bash "$android_dir/run-gradle.sh" assembleDebug
  apk="$gradle_apk"
fi
if [[ -z "$apk" ]]; then
  candidates=()
  if [[ -d "$artifacts" ]]; then
    mapfile -t candidates < <(find "$artifacts" -name app-debug.apk -printf '%T@ %p\n')
  fi
  if [[ -f "$gradle_apk" ]]; then
    candidates+=("$(stat -c %Y "$gradle_apk") $gradle_apk")
  fi
  if [[ ${#candidates[@]} -gt 0 ]]; then
    apk="$(printf '%s\n' "${candidates[@]}" | sort -n | tail -n1 | cut -d' ' -f2-)"
  fi
fi
if [[ -z "$apk" || ! -f "$apk" ]]; then
  echo "error: no APK found (looked in $artifacts and $gradle_apk); use --build or --apk PATH" >&2
  exit 1
fi

"$adb" start-server >/dev/null
if [[ -z "${ANDROID_SERIAL:-}" ]]; then
  mapfile -t devices < <("$adb" devices | awk 'NR > 1 && $2 == "device" {print $1}')
  if [[ ${#devices[@]} -eq 0 ]]; then
    echo "error: no device or emulator connected; start one with: mise run mobile-android-emulator" >&2
    "$adb" devices >&2
    exit 1
  elif [[ ${#devices[@]} -gt 1 ]]; then
    echo "error: several devices connected (${devices[*]}); set ANDROID_SERIAL" >&2
    exit 1
  fi
  export ANDROID_SERIAL="${devices[0]}"
fi

echo "installing $apk on $ANDROID_SERIAL"
"$adb" install -r "$apk"
if [[ $launch -eq 1 ]]; then
  "$adb" shell am start -W -n "$package/.MainActivity"
fi
