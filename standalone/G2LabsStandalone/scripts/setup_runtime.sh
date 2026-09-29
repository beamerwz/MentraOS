#!/bin/bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
TMP="$APP_ROOT/.runtime_tmp"
FRAMEWORKS="$APP_ROOT/Frameworks"
VENDOR="$APP_ROOT/Vendor"
RES="$APP_ROOT/Resources/BuiltinItalian"

rm -rf "$TMP" "$FRAMEWORKS" "$VENDOR"
mkdir -p "$TMP" "$FRAMEWORKS" "$VENDOR/Sherpa" "$RES"

echo "== G2 LABS Standalone runtime =="

SHERPA_VERSION="1.13.3"
SHERPA_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VERSION}/sherpa-onnx-v${SHERPA_VERSION}-ios.tar.bz2"
curl -fL --retry 3 "$SHERPA_URL" -o "$TMP/sherpa.tar.bz2"
tar -xjf "$TMP/sherpa.tar.bz2" -C "$TMP"
mv "$TMP/build-ios/sherpa-onnx.xcframework" "$FRAMEWORKS/"

ORT_VERSION="1.26.0"
ORT_URL="https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ORT_VERSION}/onnxruntime-ios-static-xcframework-${ORT_VERSION}.zip"
curl -fL --retry 3 "$ORT_URL" -o "$TMP/ort.zip"
unzip -q "$TMP/ort.zip" -d "$TMP/ort"
ORT_DIR="$(find "$TMP/ort" -type d -name onnxruntime.xcframework | head -1)"
test -n "$ORT_DIR"
mv "$ORT_DIR" "$FRAMEWORKS/onnxruntime.xcframework"

cp "$REPO_ROOT/mobile/modules/bluetooth-sdk/ios/Packages/SherpaOnnx/SherpaOnnx.swift" "$VENDOR/Sherpa/"
cp "$REPO_ROOT/mobile/modules/bluetooth-sdk/ios/Source/stt/SherpaOnnxSafeBridge.h" "$VENDOR/Sherpa/"
cp "$REPO_ROOT/mobile/modules/bluetooth-sdk/ios/Source/stt/SherpaOnnxSafeBridge.mm" "$VENDOR/Sherpa/"
cp -R "$REPO_ROOT/mobile/modules/bluetooth-sdk/ios/Packages/CoreObjC" "$VENDOR/CoreObjC"
cp -R "$REPO_ROOT/mobile/modules/bluetooth-sdk/ios/Packages/libbz2" "$VENDOR/libbz2"

ITALIAN_BASE="https://huggingface.co/hudaiapa88/sherpa-stt-onnx/resolve/main/it/kroko_64l"
for f in encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt; do
  if [[ ! -s "$RES/$f" ]]; then
    echo "Downloading built-in Italian: $f"
    curl -fL --retry 3 "$ITALIAN_BASE/$f" -o "$RES/$f"
  fi
done

ORT_BIN="$FRAMEWORKS/onnxruntime.xcframework/ios-arm64/onnxruntime.framework/onnxruntime"
nm -gU "$ORT_BIN" > "$TMP/ort-symbols.txt"
grep -q '_OrtGetApiBase$' "$TMP/ort-symbols.txt"
grep -q '_OrtSessionOptionsAppendExecutionProvider_CoreML$' "$TMP/ort-symbols.txt"

rm -rf "$TMP"
echo "Standalone runtime ready."
