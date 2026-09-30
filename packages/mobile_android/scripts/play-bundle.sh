#!/usr/bin/env bash
set -euo pipefail
# Check names only; never echo credential values or enable shell tracing here.
for name in VERDE_ANDROID_UPLOAD_KEYSTORE VERDE_ANDROID_STORE_PASSWORD VERDE_ANDROID_KEY_ALIAS VERDE_ANDROID_KEY_PASSWORD VERDE_ANDROID_VERSION_CODE VERDE_ANDROID_VERSION_NAME; do
    if [[ ! -v "$name" || -z "${!name}" ]]; then
        echo "Missing required environment variable: $name" >&2
        exit 1
    fi
done
if [[ ! -f "$VERDE_ANDROID_UPLOAD_KEYSTORE" ]]; then
    echo 'Upload keystore file does not exist.' >&2
    exit 1
fi
exec bash "$(dirname "$0")/../run-gradle.sh" bundleRelease
