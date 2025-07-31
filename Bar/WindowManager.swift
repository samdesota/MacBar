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

class WindowManager: ObservableObject {
    @Published var openWindows: [WindowInfo] = []
    @Published var hasAccessibilityPermission: Bool = false
    @Published var debugInfo: String = ""
    private var timer: Timer?
    private var windowOrder: [String] = [] // Track order by app name
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
            taskbarY = screenFrame.maxY - 10 // Same as in BarApp.swift
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
                        let newHeight = taskbarY - currentPos.y - 5 // 5px gap above taskbar
                
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
        var newWindowOrder: [String] = []
        
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
            
            let windowInfo = WindowInfo(
                id: windowID,
                name: windowName,
                owner: windowOwner,
                icon: appIcon,
                isActive: isWindowActive(windowID)
            )
            
            // Avoid duplicates based on owner only (since window names might be empty)
            if !windowInfos.contains(where: { $0.owner == windowInfo.owner }) {
                windowInfos.append(windowInfo)
                newWindowOrder.append(windowOwner)
                logger.debug("Added window: \(windowOwner) - \(windowName)", category: .windowManager)
            }
        }
        
        // Maintain stable order: existing windows keep their position, new windows go to the end
        let orderedWindows = maintainStableOrder(currentWindows: windowInfos, newOrder: newWindowOrder)
        
        return orderedWindows
    }
    
    private func maintainStableOrder(currentWindows: [WindowInfo], newOrder: [String]) -> [WindowInfo] {
        var orderedWindows: [WindowInfo] = []
        var usedOwners: Set<String> = []
        
        // First, add existing windows in their current order
        for window in openWindows {
            if let newWindow = currentWindows.first(where: { $0.owner == window.owner }) {
                orderedWindows.append(newWindow)
                usedOwners.insert(window.owner)
            }
        }
        
        // Then add any new windows to the end
        for owner in newOrder {
            if !usedOwners.contains(owner) {
                if let newWindow = currentWindows.first(where: { $0.owner == owner }) {
                    orderedWindows.append(newWindow)
                    usedOwners.insert(owner)
                }
            }
        }
        
        return orderedWindows
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
        // Find and activate the app
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == windowInfo.owner }) {
            app.activate(options: .activateIgnoringOtherApps)
        }
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
    
    var displayName: String {
        // Show app name if window name is generic or empty
        if name.isEmpty || name == owner {
            return owner
        }
        return name
    }
    
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        return lhs.id == rhs.id && lhs.name == rhs.name && lhs.owner == rhs.owner
    }
} 