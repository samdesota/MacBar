#!/bin/bash

set -e

echo "🦊 Installing Bar Favicon Bridge Firefox Extension (Development Mode)"
echo ""

# Get the absolute path to this script's directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
EXTENSION_DIR="$SCRIPT_DIR"

# Firefox profile directory
FIREFOX_PROFILE_DIR="$HOME/Library/Application Support/Firefox/Profiles"

# Check if Firefox is installed
if [ ! -d "$FIREFOX_PROFILE_DIR" ]; then
    echo "❌ Firefox not found. Please install Firefox first."
    exit 1
fi

# Find the default profile (usually ends with .default-release)
DEFAULT_PROFILE=$(find "$FIREFOX_PROFILE_DIR" -maxdepth 1 -name "*.default-release" -type d | head -n 1)

if [ -z "$DEFAULT_PROFILE" ]; then
    # Try to find any profile
    DEFAULT_PROFILE=$(find "$FIREFOX_PROFILE_DIR" -maxdepth 1 -type d ! -name "Profiles" | head -n 1)
fi

if [ -z "$DEFAULT_PROFILE" ]; then
    echo "❌ No Firefox profile found."
    echo ""
    echo "To install manually:"
    echo "1. Open Firefox"
    echo "2. Navigate to: about:debugging#/runtime/this-firefox"
    echo "3. Click 'Load Temporary Add-on...'"
    echo "4. Select: $EXTENSION_DIR/manifest.json"
    exit 1
fi

echo "📁 Found Firefox profile: $(basename "$DEFAULT_PROFILE")"
echo ""

# Create extensions directory if it doesn't exist
EXTENSIONS_DIR="$DEFAULT_PROFILE/extensions"
mkdir -p "$EXTENSIONS_DIR"

# Extension ID from manifest
EXTENSION_ID="bar-favicon-bridge@bar.local"

# For development, we'll create a pointer file to the extension directory
# This allows live reloading without reinstalling
EXTENSION_LINK="$EXTENSIONS_DIR/$EXTENSION_ID"

echo "📝 Creating extension pointer..."
echo "$EXTENSION_DIR" > "$EXTENSION_LINK"
echo "✅ Extension pointer created: $EXTENSION_LINK"
echo ""

echo "⚠️  IMPORTANT: Restart Firefox for the extension to load"
echo ""
echo "After restarting Firefox:"
echo "1. Navigate to: about:debugging#/runtime/this-firefox"
echo "2. You should see 'Bar Favicon Bridge' listed"
echo "3. Check the console for any errors"
echo ""
echo "Alternative (Temporary Load):"
echo "1. Open Firefox → about:debugging#/runtime/this-firefox"
echo "2. Click 'Load Temporary Add-on...'"
echo "3. Select: $EXTENSION_DIR/manifest.json"
echo ""
echo "📊 Test the extension:"
echo "   - Open a new tab and navigate to any website"
echo "   - Check: tail -f /tmp/bar_favicon_host.log"
echo ""
