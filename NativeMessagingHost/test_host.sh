#!/bin/bash

# Test script for Bar Firefox Native Messaging Host
# Simulates Firefox extension sending a tabUpdate message

echo "🧪 Testing Bar Firefox Native Messaging Host"
echo ""

# Sample payload matching what the Firefox extension sends
PAYLOAD='{"type":"tabUpdate","windowId":123,"url":"https://github.com","favIconUrl":"https://github.com/favicon.ico"}'

# Calculate length (4-byte little-endian)
LENGTH=${#PAYLOAD}

# Create a temporary file with the native messaging protocol format
TEMP_FILE=$(mktemp)

# Write 4-byte length prefix (little-endian) + JSON payload
printf "\\x$(printf '%02x' $((LENGTH & 0xFF)))" >> "$TEMP_FILE"
printf "\\x$(printf '%02x' $(((LENGTH >> 8) & 0xFF)))" >> "$TEMP_FILE"
printf "\\x$(printf '%02x' $(((LENGTH >> 16) & 0xFF)))" >> "$TEMP_FILE"
printf "\\x$(printf '%02x' $(((LENGTH >> 24) & 0xFF)))" >> "$TEMP_FILE"
printf "%s" "$PAYLOAD" >> "$TEMP_FILE"

echo "📤 Sending test message:"
echo "   $PAYLOAD"
echo ""
echo "📊 Check the log file for output:"
echo "   tail -f /tmp/bar_favicon_host.log"
echo ""
echo "🔄 Running native host..."
echo ""

# Run the host with the test input
cat "$TEMP_FILE" | ./NativeMessagingHost/BarFaviconHost/bar_favicon_host

# Clean up
rm "$TEMP_FILE"

echo ""
echo "✅ Test complete!"
echo ""
echo "If the Bar app is running with FirefoxFaviconReceiver initialized,"
echo "it should have received the notification."
echo ""
echo "Check Bar app logs for: '🦊 Firefox window 123: https://github.com'"
