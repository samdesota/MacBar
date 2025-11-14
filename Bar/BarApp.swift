//
//  BarApp.swift
//  Bar
//
//  Created by Samuel DeSota on 7/31/25.
//

import SwiftUI
import AppKit
import Combine



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
    var dockWindows: [String: NSWindow] = [:] // Space ID -> Window mapping
    var windowScreenMap: [String: NSScreen] = [:] // Space ID -> Screen mapping
    var permissionWindow: NSWindow?
    var settingsWindow: NSWindow?
    private let logger = Logger.shared
    private let keyboardSwitcher = KeyboardSwitcher.shared
    private let keyboardPermissionManager = KeyboardPermissionManager.shared
    private let spaceManager = SpaceManager.shared
    private let windowManager = WindowManager() // Single WindowManager instance
    private var cancellables = Set<AnyCancellable>()
    private var currentActiveSpaceID: String = ""
    private var screenChangeObserver: NSObjectProtocol?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide app from dock
        NSApp.setActivationPolicy(.accessory)
        
        checkPermissionsAndSetup()
        setupNotificationObservers()
    }
    
    deinit {
        // Clean up screen change observer
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettingsWindow),
            name: NSNotification.Name("OpenSettings"),
            object: nil
        )
        
        // Observe screen parameter changes (resolution, arrangement, etc.)
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleScreenParametersChanged()
        }
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
    
    func handleScreenParametersChanged() {
        logger.info("🖥️ Screen parameters changed - updating taskbar windows", category: .taskbar)
        
        // Update all existing taskbar windows to match their screen's current resolution
        for (spaceID, window) in dockWindows {
            updateTaskbarWindowSize(for: spaceID, window: window)
        }
    }
    
    func updateTaskbarWindowSize(for spaceID: String, window: NSWindow) {
        // Get the screen this window should be on
        let targetScreen = getScreenForWindow(window) ?? NSScreen.main
        
        guard let screen = targetScreen else {
            logger.warning("⚠️ No screen found for taskbar window", category: .taskbar)
            return
        }
        
        // Update the stored screen mapping
        windowScreenMap[spaceID] = screen
        
        // Calculate new window frame based on screen's visible frame
        let screenFrame = screen.visibleFrame
        let newWidth = screenFrame.width - 10
        let newX = screenFrame.minX + 5
        let newY = screenFrame.minY + 5
        
        logger.info("🖥️ Updating taskbar for space \(spaceID): width=\(newWidth), screen=\(screen.localizedName)", category: .taskbar)
        
        // Update window size and position
        window.setFrame(
            NSRect(x: newX, y: newY, width: newWidth, height: 42),
            display: true,
            animate: true
        )
    }
    
    func getScreenForWindow(_ window: NSWindow) -> NSScreen? {
        // Get the screen that contains the window's center point
        let windowCenter = CGPoint(
            x: window.frame.midX,
            y: window.frame.midY
        )
        
        // Find the screen that contains this point
        for screen in NSScreen.screens {
            if screen.frame.contains(windowCenter) {
                return screen
            }
        }
        
        // If no screen contains the center, return the screen closest to the window
        return window.screen ?? NSScreen.main
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
        logger.info("Creating initial taskbar window", category: .taskbar)
        
        // Start keyboard switching functionality after window is created
        initializeKeyboardSwitching()
        
        // Create initial taskbar window for current space
        createTaskbarWindowForCurrentSpace()
        
        // Set up space change observer to create windows for new spaces
        setupSpaceChangeObserver()
    }
    
    private func createTaskbarWindowForCurrentSpace() {
        let currentSpaceID = spaceManager.currentSpaceID.isEmpty ? "space-0" : spaceManager.currentSpaceID
        
        // Check if we already have a window for this space
        if dockWindows[currentSpaceID] != nil {
            logger.info("Taskbar window already exists for space: \(currentSpaceID)", category: .taskbar)
            return
        }
        
        logger.info("Creating taskbar window for space: \(currentSpaceID)", category: .taskbar)
        
        // Use the single WindowManager instance
        let windowManager = self.windowManager
        
        let contentView = NSHostingView(rootView: ContentView(spaceID: currentSpaceID).environmentObject(windowManager))
        
        // Determine which screen to use - prefer the screen with the mouse cursor
        let targetScreen = getScreenWithMouseCursor() ?? NSScreen.main ?? NSScreen.screens.first
        
        guard let screen = targetScreen else {
            logger.warning("⚠️ No screen available for taskbar window", category: .taskbar)
            return
        }
        
        // Store the screen mapping
        windowScreenMap[currentSpaceID] = screen
        
        // Get screen width to make taskbar full width
        let screenFrame = screen.visibleFrame
        let screenWidth = screenFrame.width
        
        logger.info("🖥️ Creating taskbar on screen: \(screen.localizedName), width: \(screenWidth)", category: .taskbar)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: screenWidth - 10, height: 42),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        window.contentView = contentView
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        
        // Set collection behavior to NOT join all spaces - this makes it space-specific
        window.collectionBehavior = [.stationary, .ignoresCycle]
        
        // Position at bottom of screen, full width
        let x = screenFrame.minX + 5
        let y = screenFrame.minY + 5
        window.setFrameOrigin(NSPoint(x: x, y: y))
        
        // Store window for this space
        dockWindows[currentSpaceID] = window
        
        // Show the window
        window.makeKeyAndOrderFront(nil)
        logger.info("Created and showed taskbar window for space: \(currentSpaceID) on screen: \(screen.localizedName)", category: .taskbar)
        
        // Connect WindowManager to KeyboardSwitcher for real window data
        keyboardSwitcher.connectWindowManager(windowManager)
        
        // Set this as the active space
        currentActiveSpaceID = currentSpaceID
    }
    
    private func getScreenWithMouseCursor() -> NSScreen? {
        // Get the current mouse location
        let mouseLocation = NSEvent.mouseLocation
        
        // Find the screen that contains the mouse cursor
        for screen in NSScreen.screens {
            if screen.frame.contains(mouseLocation) {
                return screen
            }
        }
        
        return nil
    }
    

    
    private func setupSpaceChangeObserver() {
        // Observe space changes to update the WindowManager
        spaceManager.$currentSpaceID
            .sink { [weak self] newSpaceID in
                self?.handleSpaceChange(newSpaceID)
            }
            .store(in: &cancellables)
    }
    
    private func handleSpaceChange(_ newSpaceID: String) {
        logger.info("🔄 Space change detected: \(newSpaceID)", category: .spaceManagement)
        
        // Update current active space
        currentActiveSpaceID = newSpaceID
        
        // Update the WindowManager with the new space ID
        if let spaceID = UInt64(newSpaceID.replacingOccurrences(of: "space-", with: "")) {
            windowManager.updateCurrentSpace(spaceID)
        }
        
        // Check if we should show taskbar on this space
        if !spaceManager.shouldShowTaskbarOnCurrentSpace() {
            logger.info("🚫 Skipping taskbar on full screen space", category: .spaceManagement)
            return
        }
        
        // Check if we need to create a taskbar window for this space
        if dockWindows[newSpaceID] == nil {
            logger.info("🆕 Creating new taskbar window for space: \(newSpaceID)", category: .spaceManagement)
            createTaskbarWindowForCurrentSpace()
        } else {
            logger.info("✅ Taskbar window already exists for space: \(newSpaceID)", category: .spaceManagement)
        }
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
