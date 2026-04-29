//
//  BarApp.swift
//  Bar
//
//  Created by Samuel DeSota on 7/31/25.
//

import SwiftUI
import AppKit
import Combine
import ServiceManagement



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
    var statusItem: NSStatusItem?
    private let logger = Logger.shared
    private let keyboardSwitcher = KeyboardSwitcher.shared
    private let keyboardPermissionManager = KeyboardPermissionManager.shared
    private let spaceManager = SpaceManager.shared
    private let windowManager = WindowManager() // Single WindowManager instance
    private let firefoxReceiver = FirefoxFaviconReceiver() // Firefox favicon bridge
    private var cancellables = Set<AnyCancellable>()
    private var currentActiveSpaceID: String = ""
    private var screenChangeObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var reconcileTimer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide app from dock
        NSApp.setActivationPolicy(.accessory)
        
        setupStatusBarItem()
        checkPermissionsAndSetup()
        setupNotificationObservers()
    }

    private func setupStatusBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled",
                                accessibilityDescription: "Bar")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()

        let restartItem = NSMenuItem(title: "Restart Bar",
                                     action: #selector(restartApp),
                                     keyEquivalent: "r")
        restartItem.target = self
        menu.addItem(restartItem)

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettingsWindow),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let launchItem = NSMenuItem(title: "Launch at Login",
                                    action: #selector(toggleLaunchAtLogin(_:)),
                                    keyEquivalent: "")
        launchItem.target = self
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Bar",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    @objc private func restartApp() {
        let bundlePath = Bundle.main.bundlePath
        let escaped = bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 0.5 && /usr/bin/open -n '\(escaped)'"]
        do {
            try task.run()
            logger.info("🔄 Restarting Bar from \(bundlePath)", category: .general)
        } catch {
            logger.error("Failed to spawn restart task: \(error.localizedDescription)", category: .general)
            return
        }
        NSApp.terminate(nil)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                sender.state = .off
                logger.info("Unregistered launch at login", category: .general)
            } else {
                try service.register()
                sender.state = .on
                logger.info("Registered launch at login", category: .general)
            }
        } catch {
            logger.error("Failed to toggle launch at login: \(error.localizedDescription)", category: .general)
        }
    }
    
    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        reconcileTimer?.invalidate()
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
        
        // Observe CLI commands via DistributedNotificationCenter
        setupCLINotificationObservers()
    }
    
    private func setupCLINotificationObservers() {
        let center = DistributedNotificationCenter.default()
        
        center.addObserver(
            forName: Notification.Name("com.bar.cli.fullscreen"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("📟 CLI: received fullscreen command", category: .windowManager)
            self?.windowManager.tileCurrentWindowToFullscreen()
        }

        center.addObserver(
            forName: Notification.Name("com.bar.cli.name-window"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let name = userInfo["name"] as? String else {
                self?.logger.warning("📟 CLI: name-window missing 'name' parameter", category: .windowManager)
                return
            }
            let windowID = (userInfo["windowID"] as? String).flatMap { UInt32($0) }.map { CGWindowID($0) }
            self?.logger.info("📟 CLI: received name-window command (id=\(windowID ?? 0), name='\(name)')", category: .windowManager)
            self?.windowManager.nameWindow(windowID: windowID, name: name)
        }

        logger.info("✅ CLI notification observers registered", category: .windowManager)
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

        // Also reconcile in case a display change implies a new active space.
        reconcileTaskbars()
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
            NSRect(x: newX, y: newY, width: newWidth, height: WindowTiling.taskbarHeight),
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

        // Connect Firefox receiver to WindowManager
        windowManager.setFirefoxReceiver(firefoxReceiver)

        // Start keyboard switching functionality after window is created
        initializeKeyboardSwitching()

        // Observe bar hide state + switching mode for taskbar visibility
        setupBarHideObservers()

        // Wire up reconciliation triggers and run an initial pass.
        setupReconciliationTriggers()
        reconcileTaskbars()
    }

    private func setupBarHideObservers() {
        Publishers.CombineLatest(
            windowManager.$hiddenSpaces,
            keyboardSwitcher.$isSwitchingMode
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] hiddenSpaces, isSwitching in
            self?.updateTaskbarVisibility(hiddenSpaces: hiddenSpaces, isSwitching: isSwitching)
        }
        .store(in: &cancellables)
    }

    private func updateTaskbarVisibility(hiddenSpaces: Set<String>, isSwitching: Bool) {
        for (spaceID, window) in dockWindows {
            let isHidden = hiddenSpaces.contains(spaceID)
            let isActiveSpace = (spaceID == currentActiveSpaceID)
            let shouldShow = !isHidden || (isHidden && isActiveSpace && isSwitching)

            if shouldShow {
                if !window.isVisible {
                    window.orderFrontRegardless()
                }
            } else {
                if window.isVisible {
                    window.orderOut(nil)
                }
            }
        }
    }

    // MARK: - Reconciliation (idempotent, source-of-truth driven)

    /// Wires up every signal that should trigger a reconcile. All triggers converge on
    /// `reconcileTaskbars()`, which is idempotent and reads the active space directly from SLS
    /// (bypassing @Published willSet timing).
    private func setupReconciliationTriggers() {
        // 1. SpaceManager's existing change detector (private API poll + workspace notification).
        spaceManager.onSpaceChangeDetected = { [weak self] in
            self?.reconcileTaskbars()
            // Brief retry burst — handles cases where SLS hasn't fully transitioned yet
            // or the target screen isn't ready on the first call.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self?.reconcileTaskbars() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.reconcileTaskbars() }
        }

        // 2. App activation — covers cases where space changed but our hooks missed it.
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reconcileTaskbars()
        }

        // 3. Periodic safety net — guarantees self-healing within 1s of any missed event.
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reconcileTaskbars()
        }
    }

    /// Idempotent: ensures the active space has a taskbar, garbage-collects stale ones.
    /// Safe to call from any thread/context, any number of times.
    private func reconcileTaskbars() {
        guard let activeSpaceID = spaceManager.liveActiveSpaceID() else {
            logger.warning("⚠️ reconcile: no active space from SLS", category: .taskbar)
            return
        }

        // Update active-space tracking + WindowManager (idempotent — only logs/updates on change).
        if currentActiveSpaceID != activeSpaceID {
            logger.info("🔄 reconcile: active space \(currentActiveSpaceID) → \(activeSpaceID)", category: .spaceManagement)
            currentActiveSpaceID = activeSpaceID
            if let raw = UInt64(activeSpaceID.replacingOccurrences(of: "space-", with: "")) {
                windowManager.updateCurrentSpace(raw)
            }
        }

        // Ensure a taskbar exists for the active space (unless it's a fullscreen space).
        if spaceManager.liveIsFullScreen(spaceIDString: activeSpaceID) {
            logger.debug("🚫 reconcile: \(activeSpaceID) is fullscreen, no taskbar", category: .taskbar)
        } else {
            ensureTaskbar(for: activeSpaceID)
        }

        // Garbage-collect taskbars for spaces that no longer exist.
        let managed = spaceManager.liveManagedSpaceIDs()
        if !managed.isEmpty {
            for staleID in dockWindows.keys where !managed.contains(staleID) {
                logger.info("🗑 reconcile: removing stale taskbar for \(staleID)", category: .taskbar)
                dockWindows[staleID]?.close()
                dockWindows.removeValue(forKey: staleID)
                windowScreenMap.removeValue(forKey: staleID)
            }
        }
    }

    /// Idempotent taskbar creation. Returns true if a window exists (or was just created) for `spaceID`.
    /// If no screen is available yet, schedules a retry instead of giving up.
    @discardableResult
    private func ensureTaskbar(for spaceID: String) -> Bool {
        if dockWindows[spaceID] != nil { return true }

        guard let screen = getScreenWithMouseCursor() ?? NSScreen.main ?? NSScreen.screens.first else {
            logger.warning("⚠️ ensureTaskbar(\(spaceID)): no screen available, will retry via reconcile timer", category: .taskbar)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.reconcileTaskbars()
            }
            return false
        }

        logger.info("🆕 Creating taskbar for \(spaceID) on \(screen.localizedName)", category: .taskbar)

        let contentView = NSHostingView(rootView: ContentView(spaceID: spaceID).environmentObject(windowManager))
        windowScreenMap[spaceID] = screen

        let screenFrame = screen.visibleFrame
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: screenFrame.width - 10, height: WindowTiling.taskbarHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        // Stationary so the window stays bound to whichever space is active when it's first shown.
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.setFrameOrigin(NSPoint(x: screenFrame.minX + 5, y: screenFrame.minY + 5))

        dockWindows[spaceID] = window

        if windowManager.isBarHidden(for: spaceID) {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }

        // Wire keyboard switcher to the WindowManager (idempotent connect).
        keyboardSwitcher.connectWindowManager(windowManager)

        return true
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
