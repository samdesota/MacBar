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
    var settingsWindow: NSWindow?
    private let logger = Logger.shared
    private let keyboardSwitcher = KeyboardSwitcher.shared
    private let keyboardPermissionManager = KeyboardPermissionManager.shared
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide app from dock
        NSApp.setActivationPolicy(.accessory)
        
        checkPermissionsAndSetup()
        setupNotificationObservers()
    }
    
    func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettingsWindow),
            name: NSNotification.Name("OpenSettings"),
            object: nil
        )
    }
    
    @objc func openSettingsWindow() {
        // Close existing settings window if open
        settingsWindow?.close()
        
        logger.info("Creating settings window", category: .taskbar)
        
        let contentView = NSHostingView(rootView: SettingsView())
        
        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        guard let window = settingsWindow else { return }
        
        window.contentView = contentView
        window.title = "Bar Settings"
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    
    func checkPermissionsAndSetup() {
        // Use prompt option to automatically add app to accessibility permissions
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
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
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
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
        
        // Start keyboard switching functionality after window is created
        initializeKeyboardSwitching()
        
        // Create WindowManager for the content view
        let windowManager = WindowManager()
        let contentView = NSHostingView(rootView: ContentView().environmentObject(windowManager))
        
        // Get screen width to make taskbar full width
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 1200
        
        dockWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: screenWidth - 10, height: 42),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        guard let window = dockWindow else { return }
        
        window.contentView = contentView
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        window.isMovableByWindowBackground = false
        
        // Position at bottom of screen, full width
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.minX + 5
            let y = screenFrame.minY + 5
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        window.makeKeyAndOrderFront(nil)
        
        // Connect WindowManager to KeyboardSwitcher for real window data
        keyboardSwitcher.connectWindowManager(windowManager)
    }
    
    private func initializeKeyboardSwitching() {
        logger.info("Initializing keyboard switching functionality", category: .keyboardSwitching)
        
        // Start permission monitoring
        keyboardPermissionManager.startPermissionMonitoring()
        
        // Check if we have permissions and start keyboard switcher
        if keyboardPermissionManager.hasAllRequiredPermissions {
            logger.info("All permissions available - starting keyboard switcher", category: .keyboardSwitching)
            keyboardSwitcher.start()
            
            // Phase 2 complete - key assignment algorithm ready
        } else {
            logger.warning("Missing keyboard permissions - will monitor until available", category: .keyboardSwitching)
            
            // Monitor for permission changes and start switcher when ready
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                
                if self.keyboardPermissionManager.hasAllRequiredPermissions && !self.keyboardSwitcher.isActive {
                    self.logger.info("Permissions now available - starting keyboard switcher", category: .keyboardSwitching)
                    self.keyboardSwitcher.start()
                    
                    // Phase 2 complete - key assignment algorithm ready
                    
                    timer.invalidate()
                }
            }
        }
    }
}
