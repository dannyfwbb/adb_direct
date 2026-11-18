#!/usr/bin/env bash
# Copyright 2026 The adb_direct authors
# SPDX-License-Identifier: Apache-2.0
#
# Builds the tiny APKs in test/fixtures/apks from the manifests in
# test/fixtures/apks/src: an app without code (versions 1 and 2) and a
# feature split for it, with their v4 signatures (.idsig, for incremental
# installs), signed with the test-only key in
# test/fixtures/apks/test.jks (password "testtest"), so a rebuilt APK can
# still update the others. Needs the Android SDK with build-tools 36.0.0
# and platform android-35 (pinned, so rebuilds are comparable).
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
BT="$SDK/build-tools/36.0.0"
JAR="$SDK/platforms/android-35/android.jar"
KEY=test/fixtures/apks/test.jks
OUT=test/fixtures/apks
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$KEY" ]; then
  keytool -genkeypair -keystore "$KEY" -storepass testtest -keypass testtest \
    -alias test -keyalg RSA -keysize 2048 -validity 36500 \
    -dname "CN=adb_direct test" >/dev/null 2>&1
fi

link() { # name manifest [extra aapt2 args]
  "$BT/aapt2" link -o "$WORK/$1.unsigned.apk" -I "$JAR" --manifest "$2" "${@:3}"
  "$BT/zipalign" -f 4 "$WORK/$1.unsigned.apk" "$WORK/$1.aligned.apk"
  "$BT/apksigner" sign --ks "$KEY" --ks-pass pass:testtest \
    --v4-signing-enabled true --out "$OUT/$1.apk" "$WORK/$1.aligned.apk"
}

link app-v1 "$OUT/src/AndroidManifest-v1.xml"
link app-v2 "$OUT/src/AndroidManifest-v2.xml"
link app-v2-extra "$OUT/src/AndroidManifest-extra.xml"
ls -l "$OUT"/*.apk
