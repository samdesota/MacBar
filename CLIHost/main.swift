#!/usr/bin/swift

import Foundation

// MARK: - Usage

func printUsage() {
    let name = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    print("""
    Usage: \(name) <command>

    Commands:
      fullscreen              Tile the currently focused window to fullscreen
      name-window <name>      Name the focused window (shown instead of title)
      name-window <id> <name> Name a specific window by ID

    Examples:
      \(name) fullscreen
      \(name) name-window "My Terminal"
      \(name) name-window 1234 "My Terminal"
    """)
}

// MARK: - Notification Names

let notificationPrefix = "com.bar.cli"

// MARK: - Send Command

func sendCommand(_ command: String, userInfo: [String: Any] = [:]) {
    let center = DistributedNotificationCenter.default()
    let notificationName = Notification.Name("\(notificationPrefix).\(command)")

    var info = userInfo
    info["command"] = command

    center.postNotificationName(
        notificationName,
        object: nil,
        userInfo: info,
        deliverImmediately: true
    )
}

// MARK: - Main

let args = CommandLine.arguments

guard args.count >= 2 else {
    printUsage()
    exit(1)
}

let command = args[1]

switch command {
case "fullscreen":
    sendCommand("fullscreen")
    print("✅ Sent fullscreen command to Bar")

case "name-window":
    guard args.count >= 3 else {
        fputs("❌ Usage: bar name-window <name> or bar name-window <id> <name>\n", stderr)
        exit(1)
    }
    var info: [String: Any] = [:]
    if args.count >= 4, let _ = UInt32(args[2]) {
        info["windowID"] = args[2]
        info["name"] = args[3]
    } else {
        info["name"] = args[2]
    }
    sendCommand("name-window", userInfo: info)
    print("✅ Sent name-window command to Bar")

case "--help", "-h", "help":
    printUsage()
    exit(0)

default:
    fputs("❌ Unknown command: \(command)\n", stderr)
    printUsage()
    exit(1)
}
