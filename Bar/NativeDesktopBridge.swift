//
//  NativeDesktopBridge.swift
//  Bar
//
//  Created by Samuel DeSota on 7/31/25.
//

import Foundation
import AppKit
import ApplicationServices
import Darwin

// Global C callback function for accessibility observers
private func windowNotificationCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    userData: UnsafeMutableRawPointer?
) {
    guard let userData = userData else { return }
    
    // Extract the bridge instance and PID from userData
    let callbackData = userData.assumingMemoryBound(to: CallbackData.self).pointee
    guard let bridge = callbackData.bridge else { return }
    
    let notificationName = notification as String
    bridge.handleWindowNotification(notification: notificationName, element: element, appPID: callbackData.pid)
}

// Helper struct to pass both bridge and PID to the callback
private struct CallbackData {
    weak var bridge: NativeDesktopBridge?
    let pid: pid_t
}

/// Protocol for receiving window management events from the native desktop
protocol NativeDesktopBridgeDelegate: AnyObject {
    func onFocusedWindowChanged(windowID: CGWindowID?)
    func onFrontmostAppChanged(app: NSRunningApplication?)
    func onWindowListChanged()
    func onAppLaunched(app: NSRunningApplication)
    func onAppTerminated(app: NSRunningApplication)
}

/// Abstracts all native macOS window management functionality
/// Handles Accessibility API, Core Graphics, and Cocoa interactions
class NativeDesktopBridge: ObservableObject {
    weak var delegate: NativeDesktopBridgeDelegate?
    
    @Published var hasAccessibilityPermission: Bool = false
    
    private let logger = Logger.shared
    private var frontmostAppObservation: NSKeyValueObservation?
    private var appLaunchObservation: NSObjectProtocol?
    private var appTerminateObservation: NSObjectProtocol?
    
    // Hammerspoon-style accessibility observers
    private var globalObserver: AXObserver?
    private var appObservers: [pid_t: AXObserver] = [:]
    private var callbackDataStorage: [pid_t: UnsafeMutablePointer<CallbackData>] = [:]
    
    // Focus caching for performance
    private var cachedFocusedWindowID: CGWindowID?
    private var cachedFocusedApp: NSRunningApplication?
    private var lastFocusCheckTime: Date = Date()
    private let focusCacheTimeout: TimeInterval = 0.1 // 100ms
    
    init() {
        logger.info("🌉 NativeDesktopBridge initialized", category: .general)
        checkAccessibilityPermission()
        setupEventListeners()
    }
    
    deinit {
        teardownEventListeners()
    }
    
    // MARK: - Permission Management
    
    func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let hasPermission = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        let previousPermission = self.hasAccessibilityPermission
        
        DispatchQueue.main.async {
            self.hasAccessibilityPermission = hasPermission
            
            // If permission was just granted, refresh window observers
            if !previousPermission && hasPermission {
                self.logger.info("✅ Accessibility permission granted - refreshing window observers", category: .accessibility)
                self.refreshWindowObservers()
            }
        }
        
        logger.info("Accessibility permission: \(hasPermission)", category: .accessibility)
        return hasPermission
    }
    
    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    // MARK: - Event Listeners
    
    private func setupEventListeners() {
        logger.info("🔧 Setting up native desktop event listeners", category: .focusSwitching)
        
        // 1. Frontmost app changes (focus switching)
        frontmostAppObservation = NSWorkspace.shared.observe(
            \.frontmostApplication,
            options: [.new, .old]
        ) { [weak self] workspace, change in
            guard let self = self else { return }
            
            let oldApp = change.oldValue??.localizedName ?? "None"
            let newApp = change.newValue??.localizedName ?? "None"
            
            self.logger.info("🚨 Frontmost app changed: \(oldApp) → \(newApp)", category: .focusSwitching)
            
            // Clear focus cache since app changed
            self.clearFocusCache()
            
            // Notify delegate
            DispatchQueue.main.async {
                self.delegate?.onFrontmostAppChanged(app: change.newValue ?? nil)
                
                // Also check for focused window change
                let focusedWindowID = self.getFocusedWindowID()
                self.delegate?.onFocusedWindowChanged(windowID: focusedWindowID)
                self.delegate?.onWindowListChanged()
            }
        }
        
        // 2. App launch events (setup window observers)
        appLaunchObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            
            self.logger.info("🚀 App launched: \(app.localizedName ?? "Unknown")", category: .windowManager)
            
            // Set up window observers for this app
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.setupWindowObserver(for: app)
                self.delegate?.onAppLaunched(app: app)
                self.delegate?.onWindowListChanged()
            }
        }
        
        // 3. App termination events (cleanup observers)
        appTerminateObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            
            self.logger.info("🛑 App terminated: \(app.localizedName ?? "Unknown")", category: .windowManager)
            
            self.removeWindowObserver(for: app.processIdentifier)
            self.delegate?.onAppTerminated(app: app)
            self.delegate?.onWindowListChanged()
        }
        
        // 4. Setup window observers for existing apps
        setupExistingAppObservers()
        
        logger.info("✅ Native desktop event listeners established", category: .focusSwitching)
    }
    
    private func teardownEventListeners() {
        frontmostAppObservation?.invalidate()
        frontmostAppObservation = nil
        
        if let appLaunchObservation = appLaunchObservation {
            NSWorkspace.shared.notificationCenter.removeObserver(appLaunchObservation)
            self.appLaunchObservation = nil
        }
        
        if let appTerminateObservation = appTerminateObservation {
            NSWorkspace.shared.notificationCenter.removeObserver(appTerminateObservation)
            self.appTerminateObservation = nil
        }
        
        // Clean up all accessibility observers
        removeAllWindowObservers()
        
        logger.debug("Removed native desktop event listeners", category: .focusSwitching)
    }
    
    // MARK: - Hammerspoon-style Window Observers
    
    private func setupExistingAppObservers() {
        // Double-check accessibility permission
        let hasPermission = checkAccessibilityPermission()
        guard hasPermission else {
            logger.warning("⚠️ Cannot set up window observers - no accessibility permission", category: .windowManager)
            return
        }
        
        logger.info("🔍 Setting up window observers for existing apps", category: .windowManager)
        
        let runningApps = NSWorkspace.shared.runningApplications
        logger.info("📱 Found \(runningApps.count) running applications", category: .windowManager)
        
        var observerCount = 0
        for app in runningApps {
            if app.activationPolicy == .regular {
                let appName = app.localizedName ?? "Unknown"
                logger.debug("🔍 Checking app: \(appName) (PID: \(app.processIdentifier))", category: .windowManager)
                setupWindowObserver(for: app)
                observerCount += 1
            }
        }
        
        logger.info("✅ Attempted to set up observers for \(observerCount) apps, active observers: \(appObservers.count)", category: .windowManager)
        
        // Special check for Finder
        if let finderApp = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Finder" }) {
            if appObservers[finderApp.processIdentifier] != nil {
                logger.info("✅ Finder observer is active", category: .windowManager)
            } else {
                logger.warning("⚠️ Finder observer failed to set up", category: .windowManager)
            }
        }
    }
    
    // Public method to refresh observers (useful after permission granted)
    func refreshWindowObservers() {
        logger.info("🔄 Refreshing window observers", category: .windowManager)
        removeAllWindowObservers()
        setupExistingAppObservers()
    }
    
    // Diagnostic method to check observer status
    func printObserverStatus() {
        logger.info("🔍 Observer Status Report:", category: .windowManager)
        logger.info("  - Accessibility Permission: \(hasAccessibilityPermission)", category: .windowManager)
        logger.info("  - Active Observers: \(appObservers.count)", category: .windowManager)
        logger.info("  - Callback Data Storage: \(callbackDataStorage.count)", category: .windowManager)
        
        for (pid, _) in appObservers {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) {
                let appName = app.localizedName ?? "Unknown"
                logger.info("  - Observer for: \(appName) (PID: \(pid))", category: .windowManager)
            } else {
                logger.info("  - Observer for: Unknown app (PID: \(pid))", category: .windowManager)
            }
        }
    }
    
    private func setupWindowObserver(for app: NSRunningApplication) {
        guard hasAccessibilityPermission else { 
            logger.debug("Skipping observer setup - no accessibility permission", category: .windowManager)
            return 
        }
        
        let pid = app.processIdentifier
        let appName = app.localizedName ?? "Unknown"
        
        // Skip system apps and our own app (but not Finder - we want to track Finder windows)
        let systemApps = ["Bar", "Dock", "SystemUIServer", "ControlCenter", "NotificationCenter"]
        if systemApps.contains(appName) {
            logger.debug("Skipping system app: \(appName)", category: .windowManager)
            return
        }
        
        // Don't set up duplicate observers
        if appObservers[pid] != nil {
            logger.debug("Observer already exists for \(appName) (PID: \(pid))", category: .windowManager)
            return
        }
        
        logger.info("🎯 Setting up window observer for \(appName) (PID: \(pid))", category: .windowManager)
        
        // Allocate callback data
        let callbackData = UnsafeMutablePointer<CallbackData>.allocate(capacity: 1)
        callbackData.initialize(to: CallbackData(bridge: self, pid: pid))
        callbackDataStorage[pid] = callbackData
        
        var observer: AXObserver?
        let result = AXObserverCreate(pid, windowNotificationCallback, &observer)
        
        guard result == .success, let validObserver = observer else {
            let errorMsg = getAXErrorMessage(result)
            logger.warning("❌ Failed to create accessibility observer for \(appName): \(result.rawValue) (\(errorMsg))", category: .windowManager)
            // Clean up allocated memory on failure
            callbackData.deallocate()
            callbackDataStorage.removeValue(forKey: pid)
            return
        }
        
        logger.debug("✅ Created AX observer for \(appName)", category: .windowManager)
        
        // Add to our observers map
        appObservers[pid] = validObserver
        
        // Set up the observer on the main run loop
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(validObserver), .defaultMode)
        logger.debug("📡 Added observer to run loop for \(appName)", category: .windowManager)
        
        // Get the application AX element
        let axApp = AXUIElementCreateApplication(pid)
        
        // Add observers for window events
        let notifications = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification
        ]
        
        var successCount = 0
        for notification in notifications {
            let addResult = AXObserverAddNotification(validObserver, axApp, notification as CFString, callbackData)
            if addResult == .success {
                successCount += 1
                logger.debug("✅ Added \(notification) observer for \(appName)", category: .windowManager)
            } else {
                let errorMsg = getAXErrorMessage(addResult)
                logger.warning("❌ Failed to add \(notification) observer for \(appName): \(addResult.rawValue) (\(errorMsg))", category: .windowManager)
            }
        }
        
        if successCount > 0 {
            logger.info("✅ Window observer active for \(appName) (\(successCount)/\(notifications.count) notifications)", category: .windowManager)
        } else {
            logger.warning("⚠️ No notifications registered for \(appName) - observer may not work", category: .windowManager)
        }
    }
    
    private func removeWindowObserver(for pid: pid_t) {
        guard let observer = appObservers.removeValue(forKey: pid) else { return }
        
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        
        // Clean up allocated callback data
        if let callbackData = callbackDataStorage.removeValue(forKey: pid) {
            callbackData.deinitialize(count: 1)
            callbackData.deallocate()
        }
        
        logger.debug("Removed window observer for PID: \(pid)", category: .windowManager)
    }
    
    private func removeAllWindowObservers() {
        for (pid, observer) in appObservers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        appObservers.removeAll()
        
        // Clean up all allocated callback data
        for (_, callbackData) in callbackDataStorage {
            callbackData.deinitialize(count: 1)
            callbackData.deallocate()
        }
        callbackDataStorage.removeAll()
        
        logger.debug("Removed all window observers", category: .windowManager)
    }
    
    func handleWindowNotification(notification: String, element: AXUIElement, appPID: pid_t) {
        logger.info("🔔 Window notification: \(notification) from PID: \(appPID)", category: .windowManager)
        
        switch notification {
        case kAXWindowCreatedNotification as String:
            logger.info("🆕 Window created", category: .windowManager)
            // Add delay to allow Core Graphics window list to update
            self.scheduleWindowListUpdate(reason: "window creation", initialDelay: 0.1)
            
        case kAXUIElementDestroyedNotification as String:
            logger.info("🗑️ Window destroyed", category: .windowManager)
            // Add delay to allow Core Graphics window list to update
            self.scheduleWindowListUpdate(reason: "window destruction", initialDelay: 0.1)
            
        case kAXWindowMiniaturizedNotification as String:
            logger.info("📦 Window minimized", category: .windowManager)
            // Smaller delay for minimize/restore as these are state changes, not list changes
            self.scheduleWindowListUpdate(reason: "window minimize", initialDelay: 0.05)
            
        case kAXWindowDeminiaturizedNotification as String:
            logger.info("📤 Window restored", category: .windowManager)
            // Smaller delay for minimize/restore as these are state changes, not list changes
            self.scheduleWindowListUpdate(reason: "window restore", initialDelay: 0.05)
            
        default:
            logger.debug("Unknown window notification: \(notification)", category: .windowManager)
        }
    }
    
    // MARK: - Window List Update Scheduling
    
    private var pendingUpdates: Set<String> = []
    private let updateQueue = DispatchQueue(label: "window-update-queue", qos: .userInteractive)
    
    private func scheduleWindowListUpdate(reason: String, initialDelay: TimeInterval) {
        updateQueue.async {
            // Prevent duplicate updates for the same reason
            guard !self.pendingUpdates.contains(reason) else {
                self.logger.debug("⏭️ Skipping duplicate update for \(reason)", category: .windowManager)
                return
            }
            
            self.pendingUpdates.insert(reason)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) {
                self.logger.debug("🔄 Updating window list after \(reason) delay (\(Int(initialDelay * 1000))ms)", category: .windowManager)
                
                // Store window count before update
                let windowsBefore = self.getAllWindows(includeOffscreen: false).count
                
                self.delegate?.onWindowListChanged()
                
                // Check if we should retry (for window creation events)
                if reason.contains("creation") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        let windowsAfter = self.getAllWindows(includeOffscreen: false).count
                        self.logger.debug("📊 Window count: before=\(windowsBefore), after=\(windowsAfter)", category: .windowManager)
                        
                        // If no change detected and this was a creation event, try one more time
                        if windowsAfter <= windowsBefore {
                            self.logger.debug("🔄 Retrying window list update - no new windows detected", category: .windowManager)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                self.delegate?.onWindowListChanged()
                            }
                        }
                    }
                }
                
                // Remove from pending updates
                self.updateQueue.async {
                    self.pendingUpdates.remove(reason)
                }
            }
        }
    }
    
    // MARK: - Window Discovery
    
    struct NativeWindowInfo {
        let windowID: CGWindowID
        let name: String
        let owner: String
        let bounds: CGRect
        let layer: Int
        let isMinimized: Bool
    }
    
    func getAllWindows(includeOffscreen: Bool = false) -> [NativeWindowInfo] {
        var options: CGWindowListOption = [.excludeDesktopElements]
        if !includeOffscreen {
            options.insert(.optionOnScreenOnly)
        }
        
        let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        var windowInfos: [NativeWindowInfo] = []
        
        for windowDict in windowList {
            guard let windowID = windowDict[kCGWindowNumber as String] as? CGWindowID,
                  let windowOwner = windowDict[kCGWindowOwnerName as String] as? String,
                  let windowBounds = windowDict[kCGWindowBounds as String] as? [String: Any],
                  let x = windowBounds["X"] as? Double,
                  let y = windowBounds["Y"] as? Double,
                  let width = windowBounds["Width"] as? Double,
                  let height = windowBounds["Height"] as? Double else {
                continue
            }
            
            let windowName = windowDict[kCGWindowName as String] as? String ?? ""
            let windowLayer = windowDict[kCGWindowLayer as String] as? Int ?? 0
            
            let windowInfo = NativeWindowInfo(
                windowID: windowID,
                name: windowName,
                owner: windowOwner,
                bounds: CGRect(x: x, y: y, width: width, height: height),
                layer: windowLayer,
                isMinimized: false // TODO: Detect minimized state
            )
            
            windowInfos.append(windowInfo)
        }
        
        return windowInfos
    }
    
    func getVisibleApplicationWindows() -> [NativeWindowInfo] {
        return getAllWindows(includeOffscreen: false).filter { windowInfo in
            // Skip system windows
            let systemApps = ["Bar", "Dock", "SystemUIServer", "ControlCenter", "NotificationCenter"]
            if systemApps.contains(windowInfo.owner) {
                return false
            }
            
            // Skip tiny windows (likely UI elements)
            if windowInfo.bounds.width < 100 || windowInfo.bounds.height < 100 {
                return false
            }
            
            // Only normal layer windows
            return windowInfo.layer == 0
        }
    }
    
    // MARK: - Focus Detection
    
    func getFocusedWindowID() -> CGWindowID? {
        let now = Date()
        
        // Check cache first
        if let cachedID = cachedFocusedWindowID,
           let cachedApp = cachedFocusedApp,
           cachedApp == NSWorkspace.shared.frontmostApplication,
           now.timeIntervalSince(lastFocusCheckTime) < focusCacheTimeout {
            return cachedID
        }
        
        // Get frontmost application
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            logger.debug("No frontmost application found", category: .focusSwitching)
            return nil
        }
        
        // Try AX API first (fast when it works)
        if let axFocusedID = getAXFocusedWindowID(frontmostApp: frontmostApp) {
            cacheFocusResult(windowID: axFocusedID, app: frontmostApp)
            return axFocusedID
        }
        
        // Fallback to window ordering
        if let orderFocusedID = getWindowOrderingFocusedWindow(frontmostApp: frontmostApp) {
            cacheFocusResult(windowID: orderFocusedID, app: frontmostApp)
            return orderFocusedID
        }
        
        return nil
    }
    
    private func getAXFocusedWindowID(frontmostApp: NSRunningApplication) -> CGWindowID? {
        guard hasAccessibilityPermission else { return nil }
        
        let axApp = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedElement)
        
        guard result == .success, let axWindow = focusedElement else {
            return nil
        }
        
        return getWindowIDFromAXWindow(axWindow as! AXUIElement)
    }
    
    private func getWindowOrderingFocusedWindow(frontmostApp: NSRunningApplication) -> CGWindowID? {
        let appName = frontmostApp.localizedName ?? "Unknown"
        let windowList = getAllWindows(includeOffscreen: false)
        
        // Find the first (frontmost) window belonging to the frontmost app
        for windowInfo in windowList {
            // Skip non-normal windows
            if windowInfo.layer != 0 {
                continue
            }
            
            // Skip system windows
            let systemApps = ["Bar", "Dock", "SystemUIServer", "ControlCenter", "NotificationCenter"]
            if systemApps.contains(windowInfo.owner) {
                continue
            }
            
            // Skip tiny windows
            if windowInfo.bounds.width < 100 || windowInfo.bounds.height < 100 {
                continue
            }
            
            // Check if this belongs to frontmost app
            if windowInfo.owner == appName {
                return windowInfo.windowID
            } else {
                // If first valid window isn't from frontmost app, no window is focused
                return nil
            }
        }
        
        return nil
    }
    
    private func cacheFocusResult(windowID: CGWindowID, app: NSRunningApplication) {
        cachedFocusedWindowID = windowID
        cachedFocusedApp = app
        lastFocusCheckTime = Date()
    }
    
    private func clearFocusCache() {
        cachedFocusedWindowID = nil
        cachedFocusedApp = nil
    }
    
    // MARK: - Window Manipulation
    
    enum WindowMoveResult {
        case success
        case failed(String)
        case permissionDenied
        case windowNotFound
    }
    
    func moveWindow(windowID: CGWindowID, to position: CGPoint) -> WindowMoveResult {
        guard hasAccessibilityPermission else {
            return .permissionDenied
        }
        
        guard let axWindow = getAXWindowElement(for: windowID) else {
            return .windowNotFound
        }
        
        var newPosition = position
        let positionValue = AXValueCreate(.cgPoint, &newPosition)
        
        guard let positionValue = positionValue else {
            return .failed("Could not create position value")
        }
        
        let result = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
        
        if result == .success {
            return .success
        } else {
            return .failed(getAXErrorMessage(result))
        }
    }
    
    func resizeWindow(windowID: CGWindowID, to size: CGSize) -> WindowMoveResult {
        guard hasAccessibilityPermission else {
            return .permissionDenied
        }
        
        guard let axWindow = getAXWindowElement(for: windowID) else {
            return .windowNotFound
        }
        
        var newSize = size
        let sizeValue = AXValueCreate(.cgSize, &newSize)
        
        guard let sizeValue = sizeValue else {
            return .failed("Could not create size value")
        }
        
        let result = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
        
        if result == .success {
            return .success
        } else {
            return .failed(getAXErrorMessage(result))
        }
    }
    
    func activateWindow(windowID: CGWindowID) -> WindowMoveResult {
        guard hasAccessibilityPermission else {
            return .permissionDenied
        }
        
        guard let axWindow = getAXWindowElement(for: windowID) else {
            return .windowNotFound
        }
        
        // First activate the application
        if let app = getAppForWindow(windowID: windowID) {
            app.activate(options: .activateIgnoringOtherApps)
        }
        
        // Then raise the specific window
        let result = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        
        if result == .success {
            return .success
        } else {
            return .failed(getAXErrorMessage(result))
        }
    }
    
    func minimizeWindow(windowID: CGWindowID) -> WindowMoveResult {
        guard hasAccessibilityPermission else {
            return .permissionDenied
        }
        
        guard let axWindow = getAXWindowElement(for: windowID) else {
            return .windowNotFound
        }
        
        let result = AXUIElementPerformAction(axWindow, "AXMinimize" as CFString)
        
        if result == .success {
            return .success
        } else {
            return .failed(getAXErrorMessage(result))
        }
    }
    
    // MARK: - Window Information
    
    func getWindowTitle(windowID: CGWindowID) -> String? {
        guard hasAccessibilityPermission else { return nil }
        guard let axWindow = getAXWindowElement(for: windowID) else { return nil }
        
        var title: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &title)
        
        return (result == .success) ? (title as? String) : nil
    }
    
    func getWindowBounds(windowID: CGWindowID) -> CGRect? {
        guard hasAccessibilityPermission else { return nil }
        guard let axWindow = getAXWindowElement(for: windowID) else { return nil }
        
        var position: CFTypeRef?
        var size: CFTypeRef?
        
        let posResult = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &position)
        let sizeResult = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &size)
        
        guard posResult == .success && sizeResult == .success,
              let posValue = position, let sizeValue = size else {
            return nil
        }
        
        var pos = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &sz)
        
        return CGRect(origin: pos, size: sz)
    }
    
    func getAppIcon(for appName: String) -> NSImage? {
        return NSWorkspace.shared.runningApplications
            .first(where: { $0.localizedName == appName })?
            .icon
    }
    
    // MARK: - Utility Functions
    
    private func getAXWindowElement(for windowID: CGWindowID) -> AXUIElement? {
        guard let app = getAppForWindow(windowID: windowID) else { return nil }
        
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        
        var axWindows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindows)
        
        guard result == .success, let windows = axWindows as? [AXUIElement] else {
            return nil
        }
        
        // Find the matching window
        for axWindow in windows {
            if let axWindowID = getWindowIDFromAXWindow(axWindow), axWindowID == windowID {
                return axWindow
            }
        }
        
        return nil
    }
    
    private func getAppForWindow(windowID: CGWindowID) -> NSRunningApplication? {
        let windowList = getAllWindows(includeOffscreen: true)
        
        guard let windowInfo = windowList.first(where: { $0.windowID == windowID }) else {
            return nil
        }
        
        return NSWorkspace.shared.runningApplications
            .first(where: { $0.localizedName == windowInfo.owner })
    }
    
    private func getWindowIDFromAXWindow(_ axWindow: AXUIElement) -> CGWindowID? {
        // Try private API method first
        if let windowID = getWindowIDViaPrivateAPI(axWindow) {
            return windowID
        }
        
        // Fallback to position matching
        return getWindowIDViaPositionMatching(axWindow)
    }
    
    private func getWindowIDViaPrivateAPI(_ axWindow: AXUIElement) -> CGWindowID? {
        let getWindowFunc = unsafeBitCast(
            dlsym(dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY), "_AXUIElementGetWindow"),
            to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self
        )
        
        var windowID: CGWindowID = 0
        let result = getWindowFunc(axWindow, &windowID)
        
        return (result == .success && windowID != 0) ? windowID : nil
    }
    
    private func getWindowIDViaPositionMatching(_ axWindow: AXUIElement) -> CGWindowID? {
        guard let axBounds = getWindowBounds(from: axWindow) else { return nil }
        
        let windowList = getAllWindows(includeOffscreen: true)
        let tolerance: Double = 5.0
        
        for windowInfo in windowList {
            if abs(axBounds.origin.x - windowInfo.bounds.origin.x) < tolerance &&
               abs(axBounds.origin.y - windowInfo.bounds.origin.y) < tolerance &&
               abs(axBounds.size.width - windowInfo.bounds.size.width) < tolerance &&
               abs(axBounds.size.height - windowInfo.bounds.size.height) < tolerance {
                return windowInfo.windowID
            }
        }
        
        return nil
    }
    
    private func getWindowBounds(from axWindow: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        
        let posResult = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &position)
        let sizeResult = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &size)
        
        guard posResult == .success && sizeResult == .success,
              let posValue = position, let sizeValue = size else {
            return nil
        }
        
        var pos = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &sz)
        
        return CGRect(origin: pos, size: sz)
    }
    
    private func getAXErrorMessage(_ error: AXError) -> String {
        switch error.rawValue {
        case 0: return "Success"
        case -25200: return "Failure"
        case -25201: return "Illegal Argument"
        case -25202: return "Invalid UI Element"
        case -25203: return "Invalid UI Element Observer"
        case -25204: return "Not Trusted"
        case -25205: return "Attribute Unsupported"
        case -25206: return "Action Unsupported"
        case -25207: return "Notification Unsupported"
        case -25208: return "Not Implemented"
        case -25209: return "Application Invalid"
        case -25210: return "Cannot Complete"
        case -25211: return "API Disabled"
        default: return "Unknown Error (\(error.rawValue))"
        }
    }
}