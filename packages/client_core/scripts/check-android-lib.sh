#!/usr/bin/env bash
# Checks an Android libverde_client.so: only allowlisted NEEDED libraries and
# 16 KB-aligned LOAD segments (required for Android 15+ devices and Play).
# Usage: check-android-lib.sh <readelf> <libverde_client.so>
set -euo pipefail

readelf=$1
lib=$2
allowed=" libc.so libdl.so libm.so liblog.so "

needed=$("$readelf" -d "$lib" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')
status=0
for name in $needed; do
    if [[ "$allowed" != *" $name "* ]]; then
        echo "$lib: unexpected NEEDED library: $name" >&2
        status=1
    fi
done

while read -r align; do
    if (( align < 0x4000 )); then
        echo "$lib: LOAD segment alignment $align is below 16 KB" >&2
        status=1
    fi
done < <("$readelf" -lW "$lib" | awk '$1 == "LOAD" { print $NF }')

exit "$status"
