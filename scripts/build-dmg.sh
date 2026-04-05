#!/bin/bash
set -euo pipefail

BUILD_DIR="build"
APP_NAME="Nola"
DMG_NAME="$APP_NAME.dmg"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "Building release..."
xcodebuild build \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/derived" \
  CODE_SIGNING_ALLOWED=NO \
  -quiet

APP_PATH="$BUILD_DIR/derived/Build/Products/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: $APP_PATH not found"
  exit 1
fi

echo "Creating DMG..."
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$APP_PATH" \
  -ov -format UDZO \
  "$BUILD_DIR/$DMG_NAME"

echo "Done: $BUILD_DIR/$DMG_NAME"
