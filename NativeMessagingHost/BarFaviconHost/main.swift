#!/usr/bin/swift

import Foundation

/**
 * Bar Favicon Bridge - Native Messaging Host (Swift)
 * 
 * This Swift CLI reads Native Messaging packets from stdin and can:
 * 1. Forward to Bar app via Distributed Notification Center
 * 2. Write to a shared file
 * 3. Connect via local socket (if Bar app runs a server)
 * 
 * Native Messaging Protocol:
 * - 4-byte little-endian length prefix
 * - JSON payload
 */

// MARK: - Logging

let logFile = "/tmp/bar_favicon_host.log"

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logMessage = "[\(timestamp)] \(message)\n"
    
    if let data = logMessage.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile) {
            if let fileHandle = FileHandle(forWritingAtPath: logFile) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: logFile))
        }
    }
}

// MARK: - Native Messaging Protocol

func readLength() -> UInt32? {
    var buffer = [UInt8](repeating: 0, count: 4)
    let bytesRead = fread(&buffer, 1, 4, stdin)
    guard bytesRead == 4 else { return nil }
    
    return buffer.withUnsafeBytes { $0.load(as: UInt32.self) }
}

func readMessage(length: UInt32) -> [String: Any]? {
    var buffer = [UInt8](repeating: 0, count: Int(length))
    let bytesRead = fread(&buffer, 1, Int(length), stdin)
    guard bytesRead == Int(length) else { return nil }
    
    let data = Data(buffer)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    
    return json
}

func sendMessage(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message),
          let json = String(data: data, encoding: .utf8) else {
        return
    }
    
    let length = UInt32(data.count)
    var lengthBytes = [UInt8](repeating: 0, count: 4)
    withUnsafeBytes(of: length) { lengthBytes = Array($0) }
    
    fwrite(lengthBytes, 1, 4, stdout)
    fwrite([UInt8](data), 1, data.count, stdout)
    fflush(stdout)
}

// MARK: - Communication with Bar App

struct TabUpdate: Codable {
    let type: String
    let windowId: Int
    let url: String
    let favIconUrl: String
}

func forwardToBarApp(message: [String: Any]) {
    // Option 1: Distributed Notification Center (simplest, no setup needed)
    let center = DistributedNotificationCenter.default()
    let notification = Notification.Name("com.bar.faviconUpdate")
    
    if let data = try? JSONSerialization.data(withJSONObject: message),
       let jsonString = String(data: data, encoding: .utf8) {
        center.postNotificationName(notification, object: nil, userInfo: ["payload": jsonString], deliverImmediately: true)
        log("Sent notification: \(jsonString)")
    }
}

// Listen for clearCache commands from Bar app
func listenForBarAppCommands() {
    let center = DistributedNotificationCenter.default()
    center.addObserver(
        forName: Notification.Name("com.bar.clearFaviconCache"),
        object: nil,
        queue: .main
    ) { _ in
        log("Received clearCache command from Bar app")
        // Forward to extension
        let clearMessage: [String: Any] = ["type": "clearCache"]
        sendMessage(clearMessage)
    }
}

// MARK: - Main Loop

log("Bar Favicon Host (Swift) started")

// Start listening for commands from Bar app
listenForBarAppCommands()

// Read from stdin on a background thread so notifications can be processed
DispatchQueue.global(qos: .userInitiated).async {
    while true {
        guard let length = readLength() else {
            log("Failed to read length, exiting")
            exit(0)
        }
        
        guard let message = readMessage(length: length) else {
            log("Failed to read message, exiting")
            exit(0)
        }
        
        log("Received: \(message)")
        
        // Forward to Bar app
        forwardToBarApp(message: message)
        
        // Optional: send acknowledgment back to extension
        // sendMessage(["status": "ok", "received": message["type"] ?? "unknown"])
    }
}

// Keep the main thread alive with a run loop so notifications can be processed
log("Starting run loop to process notifications")
RunLoop.main.run()

log("Bar Favicon Host (Swift) stopped")
