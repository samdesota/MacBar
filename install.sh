#!/bin/bash
# Build Bar.app, install to /Applications, install the `bar` CLI, and restart.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/Build/Products/Release/Bar.app"
INSTALL_PATH="/Applications/Bar.app"

echo "🔨 Building Bar.app (Release, signed)..."
xcodebuild \
    -project "$SCRIPT_DIR/Bar.xcodeproj" \
    -scheme Bar \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    build \
    >/dev/null

if [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ Build succeeded but $APP_BUNDLE is missing"
    exit 1
fi

echo "🔏 Signature:"
codesign -dvv "$APP_BUNDLE" 2>&1 | grep -E "Identifier=|Authority=Apple|TeamIdentifier=" | sed 's/^/   /'

echo "🛑 Stopping running Bar (if any)..."
pkill -f "/Bar.app/Contents/MacOS/Bar" 2>/dev/null || true
sleep 1

echo "📦 Installing to $INSTALL_PATH..."
rm -rf "$INSTALL_PATH"
cp -R "$APP_BUNDLE" "$INSTALL_PATH"

echo "🔧 Installing bar CLI..."
bash "$SCRIPT_DIR/CLIHost/install.sh" >/dev/null

echo "🚀 Launching Bar..."
open "$INSTALL_PATH"
sleep 1

if pgrep -f "/Bar.app/Contents/MacOS/Bar" >/dev/null; then
    echo "✅ Bar is running from $INSTALL_PATH"
else
    echo "⚠️  Bar did not start — check Console.app for errors"
    exit 1
fi
