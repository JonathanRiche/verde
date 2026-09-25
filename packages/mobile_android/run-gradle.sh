#!/usr/bin/env bash
set -euo pipefail
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/30.0.16248370}"
cd "$(dirname "$0")"
exec mise exec java@openjdk-17 -- ./gradlew --no-daemon --console=plain "$@"
