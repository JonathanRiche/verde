#!/usr/bin/env bash
# Run from the repository root through mise.
set -euo pipefail
mode=${1:?Expected build or test}
case "$mode" in build|test) ;; *) exit 2 ;; esac
[[ $(uname -s) == Darwin ]] || { echo 'iOS tasks require macOS and Xcode.' >&2; exit 1; }
cd "$(dirname "$0")/.."
xcodegen generate
args=(-project Verde.xcodeproj -scheme Verde -configuration Debug
      -derivedDataPath "$PWD/build/DerivedData" -sdk iphonesimulator
      CODE_SIGNING_ALLOWED=NO ARCHS=arm64)
if [[ $mode == build ]]; then
    xcodebuild "${args[@]}" -destination 'generic/platform=iOS Simulator' build
else
    # Own a disposable device: never boot, erase or shut down a user's simulator.
    runtime=$(xcrun simctl list runtimes --json | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r.get("isAvailable") and ".iOS-" in r["identifier"]
            and int(r["version"].split(".")[0]) >= 17]
if not runtimes:
    sys.exit("Install an iOS 17+ simulator runtime in Xcode before testing.")
print(max(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))))["identifier"])
')
    device=$(xcrun simctl create "Verde-I-01-$$" com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$runtime")
    cleanup() {
        xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
        xcrun simctl delete "$device"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    xcodebuild "${args[@]}" -destination "platform=iOS Simulator,id=$device" \
        -destination-timeout 120 -parallel-testing-enabled NO \
        -maximum-concurrent-test-simulator-destinations 1 \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
        -maximum-test-execution-time-allowance 120 test
fi
