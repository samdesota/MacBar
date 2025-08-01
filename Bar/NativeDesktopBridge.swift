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

/// Protocol for receiving window management events from the native desktop
protocol NativeDesktopBridgeDelegate: AnyObject {
    func onFocusedWindowChanged(windowID: CGWindowID?)
    func onFrontmostAppChanged(app: NSRunningApplication?)
    func onWindowListChanged()
}

/// Abstracts all native macOS window management functionality
/// Handles Accessibility API, Core Graphics, and Cocoa interactions
class NativeDesktopBridge: ObservableObject {
    weak var delegate: NativeDesktopBridgeDelegate?
    
    @Published var hasAccessibilityPermission: Bool = false
    
    private let logger = Logger.shared
    private var frontmostAppObservation: NSKeyValueObservation?
    
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
        
        DispatchQueue.main.async {
            self.hasAccessibilityPermission = hasPermission
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
            }
        }
        
        logger.info("✅ Native desktop event listeners established", category: .focusSwitching)
    }
    
    private func teardownEventListeners() {
        frontmostAppObservation?.invalidate()
        frontmostAppObservation = nil
        logger.debug("Removed native desktop event listeners", category: .focusSwitching)
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