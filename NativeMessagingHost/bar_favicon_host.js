#!/usr/bin/env node

/**
 * Bar Favicon Bridge - Native Messaging Host (Sample)
 * 
 * This is a minimal Node.js host that reads Native Messaging packets from stdin
 * and logs them. Replace this with a Swift CLI helper or forward to your app.
 * 
 * Native Messaging Protocol:
 * - 4-byte little-endian length prefix
 * - JSON payload
 * 
 * Reference: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging
 */

const fs = require('fs');

// Log to a file since stdout is used for messaging
const logFile = '/tmp/bar_favicon_host.log';
function log(msg) {
  fs.appendFileSync(logFile, `[${new Date().toISOString()}] ${msg}\n`);
}

log('Bar Favicon Host started');

// Read 4-byte length prefix
function readLength() {
  const buffer = Buffer.alloc(4);
  const bytesRead = fs.readSync(process.stdin.fd, buffer, 0, 4, null);
  if (bytesRead !== 4) return null;
  return buffer.readUInt32LE(0);
}

// Read JSON message
function readMessage(length) {
  const buffer = Buffer.alloc(length);
  const bytesRead = fs.readSync(process.stdin.fd, buffer, 0, length, null);
  if (bytesRead !== length) return null;
  return JSON.parse(buffer.toString('utf8'));
}

// Send response (optional)
function sendMessage(msg) {
  const json = JSON.stringify(msg);
  const buffer = Buffer.from(json, 'utf8');
  const lengthBuffer = Buffer.alloc(4);
  lengthBuffer.writeUInt32LE(buffer.length, 0);
  
  process.stdout.write(lengthBuffer);
  process.stdout.write(buffer);
}

// Main loop
try {
  while (true) {
    const length = readLength();
    if (length === null) break;
    
    const message = readMessage(length);
    if (message === null) break;
    
    log(`Received: ${JSON.stringify(message)}`);
    
    // TODO: Forward to Bar app via IPC, socket, or other mechanism
    // For now, just log it
    
    // Optional: send acknowledgment back to extension
    // sendMessage({ status: 'ok', received: message.type });
  }
} catch (err) {
  log(`Error: ${err.message}`);
}

log('Bar Favicon Host stopped');
