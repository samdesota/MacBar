#!/bin/bash

set -e

echo "🔧 Building and installing Bar Firefox Native Messaging Host..."
echo ""

# Get the absolute path to this script's directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Paths
SWIFT_SOURCE="$SCRIPT_DIR/BarFaviconHost/main.swift"
BINARY_OUTPUT="$SCRIPT_DIR/BarFaviconHost/bar_favicon_host"
MANIFEST_TEMPLATE="$SCRIPT_DIR/bar.favicon.bridge.json"
FIREFOX_NATIVE_DIR="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"
MANIFEST_DEST="$FIREFOX_NATIVE_DIR/bar.favicon.bridge.json"

# Step 1: Compile Swift host
echo "📦 Compiling Swift native messaging host..."
cd "$SCRIPT_DIR/BarFaviconHost"
xcrun swiftc -o bar_favicon_host main.swift
chmod +x bar_favicon_host
echo "✅ Compiled: $BINARY_OUTPUT"
echo ""

# Step 2: Create Firefox native messaging directory
echo "📁 Creating Firefox native messaging directory..."
mkdir -p "$FIREFOX_NATIVE_DIR"
echo "✅ Directory: $FIREFOX_NATIVE_DIR"
echo ""

# Step 3: Generate and install manifest
echo "📝 Installing native messaging manifest..."
cat > "$MANIFEST_DEST" <<EOF
{
  "name": "bar.favicon.bridge",
  "description": "Bar Firefox favicon bridge",
  "path": "$BINARY_OUTPUT",
  "type": "stdio",
  "allowed_extensions": ["bar-favicon-bridge@bar.local"]
}
EOF
echo "✅ Manifest installed: $MANIFEST_DEST"
echo ""

# Step 4: Verify installation
echo "🔍 Verifying installation..."
if [ -f "$BINARY_OUTPUT" ] && [ -x "$BINARY_OUTPUT" ]; then
    echo "✅ Binary exists and is executable"
else
    echo "❌ Binary not found or not executable"
    exit 1
fi

if [ -f "$MANIFEST_DEST" ]; then
    echo "✅ Manifest exists"
else
    echo "❌ Manifest not found"
    exit 1
fi

echo ""
echo "🎉 Installation complete!"
echo ""
echo "Next steps:"
echo "1. Add Bar/FirefoxFaviconReceiver.swift to your Xcode project"
echo "2. Initialize it in your app: @StateObject private var firefoxReceiver = FirefoxFaviconReceiver()"
echo "3. Load the extension in Firefox:"
echo "   - Open Firefox → about:debugging → This Firefox"
echo "   - Click 'Load Temporary Add-on'"
echo "   - Select: $PROJECT_ROOT/FirefoxExtension/manifest.json"
echo ""
echo "📊 Test logs: tail -f /tmp/bar_favicon_host.log"
echo ""
