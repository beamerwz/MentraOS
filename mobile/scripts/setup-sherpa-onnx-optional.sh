#!/bin/bash

# setup-sherpa-onnx.sh
# Downloads Sherpa-ONNX XCFramework + model once and installs:
#   • iOS:  mobile/ios/Packages/SherpaOnnx/{sherpa-onnx.xcframework,Model/*}
#   • Android: android_core/app/src/main/assets/sherpa_onnx/{model files}
# Run this from the mobile directory: ./scripts/setup-sherpa-onnx.sh

# Check if we're in a "scripts" directory
current_dir=$(basename "$PWD")
if [ "$current_dir" = "scripts" ]; then
    echo "In scripts directory, moving to parent..."
    cd ..
    echo "Now in: $PWD"
else
    echo "Not in a scripts directory. Current directory: $current_dir"
fi

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

msg() { echo -e "${YELLOW}$1${NC}"; }
ok()  { echo -e "${GREEN}$1${NC}"; }
err() { echo -e "${RED}$1${NC}"; }

# Ensure we are inside the mobile directory (script location)
SCRIPT_DIR="$( pwd )"
cd "$SCRIPT_DIR"

if [[ ! -d "ios" ]]; then
  err "❌ Run this script from the AugmentOS/mobile directory"
  exit 1
fi

IOS_PKG_DIR="modules/bluetooth-sdk/ios/Packages/SherpaOnnx"
IOS_MODEL_DIR="$IOS_PKG_DIR/Model"
ORT_VERSION="1.26.0"
ORT_XCF_DIR="$IOS_PKG_DIR/onnxruntime.xcframework"
TMP_DIR=".sherpa_tmp"

mkdir -p "$IOS_MODEL_DIR" "$TMP_DIR"

#################################
# 1. Download XCFramework (iOS) #
#################################
XCF_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.3/sherpa-onnx-v1.13.3-ios.tar.bz2"
if [[ ! -d "$IOS_PKG_DIR/sherpa-onnx.xcframework" ]]; then
  msg "📥 Downloading Sherpa-ONNX XCFramework …"
  curl -L "$XCF_URL" -o "$TMP_DIR/xcf.tar.bz2"
  tar -xjf "$TMP_DIR/xcf.tar.bz2" -C "$TMP_DIR"
  mv "$TMP_DIR/build-ios/sherpa-onnx.xcframework" "$IOS_PKG_DIR/"
  ok "✅ XCFramework ready at $IOS_PKG_DIR/sherpa-onnx.xcframework"
else
  ok "✅ XCFramework already present"
fi

########################################
# 2. Download matching ONNX Runtime    #
########################################
# sherpa-onnx v1.13.3 build-ios.sh pins ORT 1.26.0. Keep this exact
# runtime next to Sherpa so there is one ABI-compatible ORT implementation.
if [[ ! -d "$ORT_XCF_DIR" ]]; then
  msg "📥 Downloading ONNX Runtime $ORT_VERSION XCFramework …"
  ORT_URL="https://github.com/csukuangfj/onnxruntime-libs/releases/download/v$ORT_VERSION/onnxruntime-ios-static-xcframework-$ORT_VERSION.xcframework.zip"
  curl -fL --retry 3 "$ORT_URL" -o "$TMP_DIR/ort.zip"
  unzip -q "$TMP_DIR/ort.zip" -d "$TMP_DIR/ort"
  FOUND_ORT="$(find "$TMP_DIR/ort" -type d -name 'onnxruntime.xcframework' | head -1)"
  if [[ -z "$FOUND_ORT" ]]; then
    err "❌ ONNX Runtime XCFramework not found after extraction"
    exit 1
  fi
  mv "$FOUND_ORT" "$ORT_XCF_DIR"
  ok "✅ ONNX Runtime $ORT_VERSION ready at $ORT_XCF_DIR"
else
  ok "✅ Matching ONNX Runtime already present"
fi

################
# 3. Cleanup   #
################
rm -rf "$TMP_DIR"
ok "🎉 Sherpa-ONNX setup complete for iOS & Android"