#!/bin/bash

set -e

echo "🔧 Building and installing Bar CLI..."
echo ""

# Get the absolute path to this script's directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Paths
SWIFT_SOURCE="$SCRIPT_DIR/main.swift"
INSTALL_DIR="$HOME/.local/bin"
BINARY_NAME="bar"
BINARY_OUTPUT="$INSTALL_DIR/$BINARY_NAME"

# Step 1: Compile Swift CLI
echo "📦 Compiling Swift CLI..."
xcrun swiftc -O -o "$SCRIPT_DIR/$BINARY_NAME" "$SWIFT_SOURCE"
chmod +x "$SCRIPT_DIR/$BINARY_NAME"
echo "✅ Compiled: $SCRIPT_DIR/$BINARY_NAME"
echo ""

# Step 2: Create install directory
echo "📁 Creating install directory..."
mkdir -p "$INSTALL_DIR"
echo "✅ Directory: $INSTALL_DIR"
echo ""

# Step 3: Install binary
echo "📋 Installing binary to $BINARY_OUTPUT..."
cp "$SCRIPT_DIR/$BINARY_NAME" "$BINARY_OUTPUT"
echo "✅ Installed: $BINARY_OUTPUT"
echo ""

# Step 4: Verify installation
echo "🔍 Verifying installation..."
if [ -f "$BINARY_OUTPUT" ] && [ -x "$BINARY_OUTPUT" ]; then
    echo "✅ Binary exists and is executable"
else
    echo "❌ Binary not found or not executable"
    exit 1
fi

echo ""
echo "🎉 Installation complete!"
echo ""

# Step 5: PATH reminder
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo "⚠️  $INSTALL_DIR is not in your PATH."
    echo "   Add the following to your shell profile (~/.zshrc or ~/.bash_profile):"
    echo ""
    echo '   export PATH="$HOME/.local/bin:$PATH"'
    echo ""
    echo "   Then reload your shell: source ~/.zshrc"
    echo ""
fi

echo "Usage:"
echo "  $BINARY_NAME fullscreen    # Tile focused window to fullscreen"
echo "  $BINARY_NAME --help        # Show all commands"
echo ""
