#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_DIR="$PROJECT_DIR/TouchHelper.app"

cd "$PROJECT_DIR"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BUILD_DIR/TouchHelper" "$APP_DIR/Contents/MacOS/TouchHelper"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"

echo "Vytvořeno: $APP_DIR"
