//
//  WindowManager.swift
//  Bar
//
//  Created by Samuel DeSota on 7/31/25.
//

import SwiftUI
import AppKit
import Combine
import ApplicationServices
import Darwin

class WindowManager: ObservableObject {
    @Published var openWindows: [WindowInfo] = []
    @Published var hasAccessibilityPermission: Bool = false
    @Published var debugInfo: String = ""
    private var timer: Timer?
    private var windowOrder: [CGWindowID] = [] // Track order by window ID
    private var taskbarHeight: CGFloat = 42
    private var taskbarY: CGFloat = 0
    private let logger = Logger.shared
    
    init() {
        logger.info("WindowManager initialized", category: .windowManager)
        checkAccessibilityPermission()
        startMonitoring()
        setupTaskbarPosition()
    }
    
    deinit {
        stopMonitoring()
    }
    
    func setupTaskbarPosition() {
        // Calculate taskbar position based on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            taskbarY = screenFrame.maxY - 5 // Same as in BarApp.swift
            logger.info("Taskbar positioned at Y: \(taskbarY), height: \(taskbarHeight)", category: .windowPositioning)
        }
    }
    
    func checkAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let hasPermission = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        DispatchQueue.main.async {
            self.hasAccessibilityPermission = hasPermission
            self.logger.info("Accessibility permission: \(hasPermission)", category: .accessibility)
            
            if !hasPermission {
                self.debugInfo = "Accessibility permission required. Please grant permission in System Preferences > Security & Privacy > Privacy > Accessibility"
                self.logger.warning("Accessibility permission not granted", category: .accessibility)
            } else {
                self.debugInfo = "Found \(self.openWindows.count) windows"
            }
        }
    }
    
    func startMonitoring() {
        logger.info("Starting window monitoring", category: .windowManager)
        // Update immediately
        updateWindowList()
        
        // Set up timer for periodic updates
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkAccessibilityPermission()
            self?.updateWindowList()
            self?.preventTaskbarOverlap()
        }
    }
    
    func stopMonitoring() {
        logger.info("Stopping window monitoring", category: .windowManager)
        timer?.invalidate()
        timer = nil
    }
    
    func updateWindowList() {
        let windows = getVisibleWindows()
        
        DispatchQueue.main.async {
            self.openWindows = windows
            self.debugInfo = "Found \(windows.count) windows"
        }
    }
    
    func preventTaskbarOverlap() {
        guard hasAccessibilityPermission else { 
            logger.debug("Skipping overlap prevention - no accessibility permission", category: .windowPositioning)
            return 
        }
        
        // Update taskbar position in case screen changed
        setupTaskbarPosition()
        
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        
        logger.debug("Checking \(windowList.count) windows for overlap", category: .windowPositioning)
        
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
            
            // Skip our own app and system windows
            if windowOwner == "Bar" || windowOwner == "Dock" || windowOwner == "SystemUIServer" {
                continue
            }
            
            // Check if window overlaps with taskbar
            let windowBottom = y
            let windowTop = y + height
            let taskbarTop = taskbarY + taskbarHeight
            
            logger.debug("Window \(windowOwner): Y=\(y), H=\(height), Bottom=\(windowBottom), Top=\(windowTop), TaskbarY=\(taskbarY), TaskbarTop=\(taskbarTop)", category: .windowPositioning)
            
            // Check if window overlaps with taskbar area
            if windowBottom < taskbarTop && windowTop > taskbarY {
                logger.info("Window \(windowOwner) overlaps taskbar - adjusting position", category: .windowPositioning)
                
                // Try multiple approaches to move the window
                if !adjustWindowPosition(windowID: windowID, currentY: y, currentHeight: height) {
                    // Fallback: try to activate the app and bring it to front
                    logger.info("Trying fallback method for \(windowOwner)", category: .windowPositioning)
                    activateAppToBringWindowToFront(windowOwner: windowOwner)
                }
            }
        }
    }
    
    private func activateAppToBringWindowToFront(windowOwner: String) {
        // Try to activate the app, which might bring its windows to a better position
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == windowOwner }) {
            app.activate(options: .activateIgnoringOtherApps)
            logger.info("Activated app \(windowOwner) as fallback", category: .windowPositioning)
        }
    }
    
    private func adjustWindowPosition(windowID: CGWindowID, currentY: Double, currentHeight: Double) -> Bool {
        logger.debug("Attempting to adjust window position for ID: \(windowID), currentY: \(currentY)", category: .windowPositioning)
        
        // Find the app that owns this window
        let options = CGWindowListOption(arrayLiteral: .optionIncludingWindow)
        let windowList = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]] ?? []
        
        guard let windowOwner = windowList.first?[kCGWindowOwnerName as String] as? String,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == windowOwner }) else {
            logger.error("Could not find app for window ID: \(windowID)", category: .windowPositioning)
            return false
        }
        
        logger.debug("Found app: \(windowOwner) with PID: \(app.processIdentifier)", category: .windowPositioning)
        
        // Get the AXUIElement for the application
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        
        // Get all windows of this application
        var axWindows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindows)
        
        if result != .success {
            let errorMessage = getAXErrorMessage(result)
            logger.warning("Failed to get windows for app \(windowOwner), result: \(result.rawValue) (\(errorMessage))", category: .windowPositioning)
            
            // If it's a trust issue, we can't move this window
            if result.rawValue == -25204 { // kAXErrorNotTrusted
                logger.info("Skipping window adjustment for \(windowOwner) - not trusted", category: .windowPositioning)
                return false
            }
            return false
        }
        
        guard let windows = axWindows as? [AXUIElement] else {
            logger.error("Failed to cast windows array for app \(windowOwner)", category: .windowPositioning)
            return false
        }
        
        logger.debug("Found \(windows.count) windows for app \(windowOwner)", category: .windowPositioning)
        
        // Find the specific window and adjust its position
        for (index, axWindow) in windows.enumerated() {
            var position: CFTypeRef?
            let posResult = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &position)
            
            if posResult == .success, let posValue = position {
                var currentPos = CGPoint.zero
                AXValueGetValue(posValue as! AXValue, .cgPoint, &currentPos)
                
                // Get current window size
                var size: CFTypeRef?
                let sizeResult = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &size)
                
                if sizeResult == .success, let sizeValue = size {
                    var currentSize = CGSize.zero
                    AXValueGetValue(sizeValue as! AXValue, .cgSize, &currentSize)
                    
                    logger.debug("Window \(index) position: (\(currentPos.x), \(currentPos.y)), size: (\(currentSize.width), \(currentSize.height))", category: .windowPositioning)
                    
                    // Calculate window bottom edge
                    let windowBottom = currentPos.y + currentSize.height
                    
                    // Check if the bottom of the window overlaps with the taskbar area
                    if windowBottom > taskbarY {
                        logger.info("Window \(windowOwner) bottom (\(windowBottom)) overlaps with taskbar area (starts at \(taskbarY))", category: .windowPositioning)
                        
                        // Calculate new height to avoid taskbar overlap
                        let newHeight = taskbarY - currentPos.y - 5
                
                        // Ensure minimum window size
                        let minHeight: CGFloat = 200
                        let finalHeight = max(newHeight, minHeight)
                        
                        // Only resize the window (keep same position, just change height)
                        var newSize = CGSize(width: currentSize.width, height: finalHeight)
                        let newSizeValue = AXValueCreate(.cgSize, &newSize)
                        
                        if let newSizeValue = newSizeValue {
                            let setSizeResult = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, newSizeValue)
                            if setSizeResult == .success {
                                logger.info("Successfully resized window \(windowOwner) from height=\(currentSize.height) to height=\(finalHeight)", category: .windowPositioning)
                                return true
                            } else {
                                let errorMessage = getAXErrorMessage(setSizeResult)
                                logger.error("Failed to resize window \(windowOwner), result: \(setSizeResult.rawValue) (\(errorMessage))", category: .windowPositioning)
                            }
                        } else {
                            logger.error("Failed to create size value for window \(windowOwner)", category: .windowPositioning)
                        }
                    }
                }
            } else {
                let errorMessage = getAXErrorMessage(posResult)
                logger.debug("Failed to get position for window \(index), result: \(posResult.rawValue) (\(errorMessage))", category: .windowPositioning)
            }
        }
        return false
    }
    
    private func getAXErrorMessage(_ error: AXError) -> String {
        switch error.rawValue {
        case 0: // kAXErrorSuccess
            return "Success"
        case -25200: // kAXErrorFailure
            return "Failure"
        case -25201: // kAXErrorIllegalArgument
            return "Illegal Argument"
        case -25202: // kAXErrorInvalidUIElement
            return "Invalid UI Element"
        case -25203: // kAXErrorInvalidUIElementObserver
            return "Invalid UI Element Observer"
        case -25204: // kAXErrorNotTrusted
            return "Not Trusted"
        case -25205: // kAXErrorAttributeUnsupported
            return "Attribute Unsupported"
        case -25206: // kAXErrorActionUnsupported
            return "Action Unsupported"
        case -25207: // kAXErrorNotificationUnsupported
            return "Notification Unsupported"
        case -25208: // kAXErrorNotImplemented
            return "Not Implemented"
        case -25209: // kAXErrorApplicationInvalid
            return "Application Invalid"
        case -25210: // kAXErrorCannotComplete
            return "Cannot Complete"
        case -25211: // kAXErrorAPIDisabled
            return "API Disabled"
        default:
            return "Unknown Error (\(error.rawValue))"
        }
    }
    
    private func getVisibleWindows() -> [WindowInfo] {
        var windowInfos: [WindowInfo] = []
        var newWindowOrder: [CGWindowID] = []
        
        // Get all windows
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        
        logger.debug("Total windows found: \(windowList.count)", category: .windowManager)
        
        for (index, windowDict) in windowList.enumerated() {
            guard let windowID = windowDict[kCGWindowNumber as String] as? CGWindowID,
                  let windowOwner = windowDict[kCGWindowOwnerName as String] as? String,
                  let windowBounds = windowDict[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }
            
            let windowName = windowDict[kCGWindowName as String] as? String ?? ""
            let windowLayer = windowDict[kCGWindowLayer as String] as? Int ?? 0
            
            logger.debug("Window \(index): \(windowOwner) - \(windowName) (Layer: \(windowLayer))", category: .windowManager)
            
            // Skip system windows and our own app
            if windowOwner == "Bar" || windowOwner == "Dock" || windowOwner == "SystemUIServer" || 
               windowOwner == "ControlCenter" || windowOwner == "NotificationCenter" {
                logger.debug("Skipping system window: \(windowOwner)", category: .windowManager)
                continue
            }
            
            // Skip windows that are too small (likely UI elements)
            if let width = windowBounds["Width"] as? Double,
               let height = windowBounds["Height"] as? Double {
                if width < 100 || height < 100 {
                    logger.debug("Skipping small window: \(windowOwner) (\(width)x\(height))", category: .windowManager)
                    continue
                }
            }
            
            // Get app icon
            let appIcon = getAppIcon(for: windowOwner)
            
            // Try to get a better window title from Accessibility API
            let betterWindowName = getBetterWindowTitle(for: windowID, owner: windowOwner, fallbackName: windowName)
            
            let windowInfo = WindowInfo(
                id: windowID,
                name: betterWindowName,
                owner: windowOwner,
                icon: appIcon,
                isActive: isWindowActive(windowID)
            )
            
            // Add each window individually (no more filtering by owner)
            if !windowInfos.contains(where: { $0.id == windowInfo.id }) {
                windowInfos.append(windowInfo)
                newWindowOrder.append(windowID)
                logger.debug("Added window: \(windowOwner) - \(windowName) (ID: \(windowID))", category: .windowManager)
            }
        }
        
        // Maintain stable order: existing windows keep their position, new windows go to the end
        let orderedWindows = maintainStableOrderByWindow(currentWindows: windowInfos, newOrder: newWindowOrder)
        
        // Update display names based on whether there are multiple windows per app
        let finalWindows = updateDisplayNamesForMultipleWindows(orderedWindows)
        
        return finalWindows
    }
    
    private func maintainStableOrderByWindow(currentWindows: [WindowInfo], newOrder: [CGWindowID]) -> [WindowInfo] {
        var orderedWindows: [WindowInfo] = []
        var usedWindowIDs: Set<CGWindowID> = []
        
        // First, add existing windows in their current order
        for window in openWindows {
            if let newWindow = currentWindows.first(where: { $0.id == window.id }) {
                orderedWindows.append(newWindow)
                usedWindowIDs.insert(window.id)
            }
        }
        
        // Then add any new windows to the end
        for windowID in newOrder {
            if !usedWindowIDs.contains(windowID) {
                if let newWindow = currentWindows.first(where: { $0.id == windowID }) {
                    orderedWindows.append(newWindow)
                    usedWindowIDs.insert(windowID)
                }
            }
        }
        
        return orderedWindows
    }
    
    private func updateDisplayNamesForMultipleWindows(_ windows: [WindowInfo]) -> [WindowInfo] {
        // Group windows by app owner
        let windowsByApp = Dictionary(grouping: windows) { $0.owner }
        
        // Create new window infos with updated display logic
        var updatedWindows: [WindowInfo] = []
        
        for window in windows {
            let windowsForThisApp = windowsByApp[window.owner] ?? []
            let hasMultipleWindows = windowsForThisApp.count > 1
            
            // Create a new WindowInfo with potentially different display behavior
            let updatedWindow = WindowInfo(
                id: window.id,
                name: window.name,
                owner: window.owner,
                icon: window.icon,
                isActive: window.isActive,
                forceShowTitle: hasMultipleWindows
            )
            
            updatedWindows.append(updatedWindow)
            
            logger.debug("Window \(window.owner) - \(window.name): hasMultiple=\(hasMultipleWindows), displayName='\(updatedWindow.displayName)'", category: .windowManager)
        }
        
        return updatedWindows
    }
    
    private func getAppIcon(for appName: String) -> NSImage? {
        // Try to get the app icon
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) {
            return app.icon
        }
        return nil
    }
    
    private func isWindowActive(_ windowID: CGWindowID) -> Bool {
        // Check if this window is the frontmost window
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            return frontmostApp.localizedName == getWindowOwner(windowID)
        }
        return false
    }
    
    private func getWindowOwner(_ windowID: CGWindowID) -> String? {
        let options = CGWindowListOption(arrayLiteral: .optionIncludingWindow)
        let windowList = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]] ?? []
        
        return windowList.first?[kCGWindowOwnerName as String] as? String
    }
    
    func activateWindow(_ windowInfo: WindowInfo) {
        logger.info("Attempting to activate window: \(windowInfo.displayName) (\(windowInfo.owner))", category: .taskbar)
        
        // Try to focus the specific window first
        if self.focusSpecificWindow(windowInfo) {
            self.logger.info("Successfully focused specific window: \(windowInfo.displayName)", category: .taskbar)
        } else {
            // Fall back to activating the app
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == windowInfo.owner }) {
                app.activate(options: .activateIgnoringOtherApps)
                self.logger.info("Successfully activated app: \(app.localizedName)", category: .taskbar)
            } else {
                self.logger.error("Could not find running app: \(windowInfo.owner)", category: .taskbar)
            }
        }
    }
    
    private func focusSpecificWindow(_ windowInfo: WindowInfo) -> Bool {
        guard hasAccessibilityPermission else {
            logger.debug("Cannot focus specific window - no accessibility permission", category: .taskbar)
            return false
        }
        
        // Find the app that owns this window
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == windowInfo.owner }) else {
            logger.error("Could not find app for window: \(windowInfo.displayName)", category: .taskbar)
            return false
        }
        
        logger.info("Attempting to focus window - Target: '\(windowInfo.name)' (DisplayName: '\(windowInfo.displayName)') in app: \(windowInfo.owner) (PID: \(app.processIdentifier))", category: .taskbar)
        
        // Get the AXUIElement for the application
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        
        // Get all windows of this application
        var axWindows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindows)
        
        if result != .success {
            let errorMessage = getAXErrorMessage(result)
            logger.warning("Failed to get windows for app \(windowInfo.owner), result: \(result.rawValue) (\(errorMessage))", category: .taskbar)
            return false
        }
        
        guard let windows = axWindows as? [AXUIElement] else {
            logger.error("Failed to cast windows array for app \(windowInfo.owner)", category: .taskbar)
            return false
        }
        
        logger.info("Found \(windows.count) AX windows for app \(windowInfo.owner), searching for match...", category: .taskbar)
        
        // Try to find and focus the specific window by ID
        for (index, axWindow) in windows.enumerated() {
            // Try to get the window ID from the AX window
            if let axWindowID = getWindowIDFromAXWindow(axWindow) {
                let isMatch = axWindowID == windowInfo.id
                
                // Also get the title for debugging
                var title: CFTypeRef?
                let titleResult = AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &title)
                let windowTitle = (titleResult == .success) ? (title as? String ?? "<no title>") : "<failed to get title>"
                
                logger.info("AX Window \(index): ID=\(axWindowID) Title='\(windowTitle)' vs Target ID=\(windowInfo.id) - Match: \(isMatch)", category: .taskbar)
                
                // Check if this is our target window (match by ID)
                if isMatch {
                    logger.info("Found matching window by ID! Attempting to activate and raise...", category: .taskbar)
                    
                    // Activate the app first
                    app.activate(options: .activateIgnoringOtherApps)

                    logger.info("Successfully activated app: \(app.localizedName)", category: .taskbar)
                    
                    // Then try to raise this specific window
                    let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                    
                    if raiseResult == .success {
                        logger.info("Successfully raised window: \(windowInfo.displayName)", category: .taskbar)
                        return true
                    } else {
                        let errorMessage = getAXErrorMessage(raiseResult)
                        logger.warning("Failed to raise window: \(windowInfo.displayName), result: \(raiseResult.rawValue) (\(errorMessage))", category: .taskbar)
                    }
                }
            } else {
                logger.debug("Failed to get window ID for AX window \(index)", category: .taskbar)
            }
        }
        
        logger.warning("Could not find matching AX window for: '\(windowInfo.name)' (DisplayName: '\(windowInfo.displayName)') in app: \(windowInfo.owner)", category: .taskbar)
        return false
    }
    
    private func getWindowIDFromAXWindow(_ axWindow: AXUIElement) -> CGWindowID? {
        // Try method 1: Use the undocumented _AXUIElementGetWindow function
        if let windowID = getWindowIDViaPrivateAPI(axWindow) {
            return windowID
        }
        
        // Try method 2: Match by window bounds
        if let windowID = getWindowIDViaPositionMatching(axWindow) {
            return windowID
        }
        
        return nil
    }
    
    private func getWindowIDViaPrivateAPI(_ axWindow: AXUIElement) -> CGWindowID? {
        // This uses a private API function that directly gives us the CGWindowID
        // It's undocumented but widely used in accessibility tools
        let getWindowFunc = unsafeBitCast(
            dlsym(dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY), "_AXUIElementGetWindow"),
            to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self
        )
        
        var windowID: CGWindowID = 0
        let result = getWindowFunc(axWindow, &windowID)
        
        if result == .success && windowID != 0 {
            return windowID
        }
        
        logger.debug("Private API method failed with result: \(result.rawValue)", category: .taskbar)
        return nil
    }
    
    private func getWindowIDViaPositionMatching(_ axWindow: AXUIElement) -> CGWindowID? {
        // Get the position and size of the AX window
        var position: CFTypeRef?
        var size: CFTypeRef?
        
        let posResult = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &position)
        let sizeResult = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &size)
        
        guard posResult == .success && sizeResult == .success,
              let posValue = position, let sizeValue = size else {
            logger.debug("Failed to get position/size for AX window", category: .taskbar)
            return nil
        }
        
        var axPos = CGPoint.zero
        var axSize = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &axPos)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &axSize)
        
        logger.debug("AX window bounds: (\(axPos.x), \(axPos.y), \(axSize.width), \(axSize.height))", category: .taskbar)
        
        // Now find a Core Graphics window with matching bounds
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        
        for windowDict in windowList {
            guard let windowID = windowDict[kCGWindowNumber as String] as? CGWindowID,
                  let windowBounds = windowDict[kCGWindowBounds as String] as? [String: Any],
                  let x = windowBounds["X"] as? Double,
                  let y = windowBounds["Y"] as? Double,
                  let width = windowBounds["Width"] as? Double,
                  let height = windowBounds["Height"] as? Double else {
                continue
            }
            
            // Allow for small differences in position/size (within 5 pixels)
            let tolerance: Double = 5.0
            if abs(axPos.x - x) < tolerance &&
               abs(axPos.y - y) < tolerance &&
               abs(axSize.width - width) < tolerance &&
               abs(axSize.height - height) < tolerance {
                logger.debug("Found matching window by bounds: ID=\(windowID)", category: .taskbar)
                return windowID
            }
        }
        
        logger.debug("No matching window found by bounds", category: .taskbar)
        return nil
    }
    
    private func getBetterWindowTitle(for windowID: CGWindowID, owner: String, fallbackName: String) -> String {
        // If we don't have accessibility permission, just use the fallback
        guard hasAccessibilityPermission else {
            logger.debug("No accessibility permission - using fallback name for window \(windowID)", category: .windowManager)
            return fallbackName
        }
        
        // If fallback is already meaningful and different from owner, use it
        if !fallbackName.isEmpty && fallbackName != owner {
            return fallbackName
        }
        
        // Find the app that owns this window
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == owner }) else {
            logger.debug("Could not find app \(owner) for window \(windowID)", category: .windowManager)
            return fallbackName
        }
        
        // Get the AXUIElement for the application
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        
        // Get all windows of this application
        var axWindows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindows)
        
        guard result == .success, let windows = axWindows as? [AXUIElement] else {
            logger.debug("Failed to get AX windows for app \(owner)", category: .windowManager)
            return fallbackName
        }
        
        // Try to find the specific window by ID and get its title
        for axWindow in windows {
            if let axWindowID = getWindowIDFromAXWindow(axWindow), axWindowID == windowID {
                // Found the matching window, get its title
                var title: CFTypeRef?
                let titleResult = AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &title)
                
                if titleResult == .success, let windowTitle = title as? String {
                    // Only use the AX title if it's meaningful (not empty and not same as app name)
                    if !windowTitle.isEmpty && windowTitle != owner {
                        logger.debug("Got better window title via AX API: '\(windowTitle)' (was: '\(fallbackName)')", category: .windowManager)
                        return windowTitle
                    }
                }
                break
            }
        }
        
        logger.debug("Could not get better title via AX API for window \(windowID), using fallback: '\(fallbackName)'", category: .windowManager)
        return fallbackName
    }
    
    func minimizeWindow(_ windowInfo: WindowInfo) {
        // This would require more complex window management
        // For now, we'll just activate the window
        activateWindow(windowInfo)
    }
}

struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let name: String
    let owner: String
    let icon: NSImage?
    let isActive: Bool
    let forceShowTitle: Bool
    
    init(id: CGWindowID, name: String, owner: String, icon: NSImage?, isActive: Bool, forceShowTitle: Bool = false) {
        self.id = id
        self.name = name
        self.owner = owner
        self.icon = icon
        self.isActive = isActive
        self.forceShowTitle = forceShowTitle
    }
    
    var displayName: String {
        // If forceShowTitle is true (multiple windows from same app), always try to show window title
        if forceShowTitle {
            if !name.isEmpty && name != owner {
                // Truncate long window titles
                let maxLength = 50
                if name.count > maxLength {
                    return String(name.prefix(maxLength)) + "..."
                }
                return name
            } else {
                // Even with forceShowTitle, if no meaningful title, show app name with index
                return owner
            }
        } else {
            // Single window - just show app name for simplicity
            return owner
        }
    }
    
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        return lhs.id == rhs.id && lhs.name == rhs.name && lhs.owner == rhs.owner
    }
} 