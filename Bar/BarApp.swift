//
//  BarApp.swift
//  Bar
//
//  Created by Samuel DeSota on 7/31/25.
//

import SwiftUI
import AppKit

@main
struct BarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var dockWindow: NSWindow?
    var permissionWindow: NSWindow?
    private let logger = Logger.shared
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        checkPermissionsAndSetup()
    }
    
    func checkPermissionsAndSetup() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let hasPermission = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        logger.info("Initial permission check: \(hasPermission)", category: .accessibility)
        
        if hasPermission {
            createDockWindow()
        } else {
            createPermissionWindow()
        }
    }
    
    func createPermissionWindow() {
        logger.info("Creating permission window", category: .accessibility)
        
        let contentView = NSHostingView(rootView: PermissionGateView())
        
        permissionWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        guard let window = permissionWindow else { return }
        
        window.contentView = contentView
        window.title = "Bar - Permission Required"
        window.center()
        window.makeKeyAndOrderFront(nil)
        
        // Close the permission window when permissions are granted
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
            let hasPermission = AXIsProcessTrustedWithOptions(options as CFDictionary)
            
            if hasPermission {
                self?.logger.info("Permissions granted, switching to taskbar", category: .accessibility)
                timer.invalidate()
                self?.permissionWindow?.close()
                self?.permissionWindow = nil
                self?.createDockWindow()
            }
        }
    }
    
    func createDockWindow() {
        logger.info("Creating taskbar window", category: .taskbar)
        
        let contentView = NSHostingView(rootView: ContentView())
        
        dockWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 42),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        guard let window = dockWindow else { return }
        
        window.contentView = contentView
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = false
        
        // Position at bottom center of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = window.frame
            let x = screenFrame.midX - windowFrame.width / 2
            let y = screenFrame.minY + 10
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        window.makeKeyAndOrderFront(nil)
    }
}
