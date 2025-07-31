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
            taskbarY = screenFrame.minY + 10 // Same as in BarApp.swift
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
                adjustWindowPosition(windowID: windowID, currentY: y, currentHeight: height)
            }
        }
    }
    
    private func adjustWindowPosition(windowID: CGWindowID, currentY: Double, currentHeight: Double) {
        logger.debug("Attempting to adjust window position for ID: \(windowID), currentY: \(currentY)", category: .windowPositioning)
        
        // Find the app that owns this window
        let options = CGWindowListOption(arrayLiteral: .optionIncludingWindow)
        let windowList = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]] ?? []
        
        guard let windowOwner = windowList.first?[kCGWindowOwnerName as String] as? String,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == windowOwner }) else {
            logger.error("Could not find app for window ID: \(windowID)", category: .windowPositioning)
            return
        }
        
        logger.debug("Found app: \(windowOwner) with PID: \(app.processIdentifier)", category: .windowPositioning)
        
        // Get the AXUIElement for the application
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        
        // Get all windows of this application
        var axWindows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindows)
        
        guard result == .success, let windows = axWindows as? [AXUIElement] else {
            logger.error("Failed to get windows for app \(windowOwner), result: \(result.rawValue)", category: .windowPositioning)
            return
        }
        
        logger.debug("Found \(windows.count) windows for app \(windowOwner)", category: .windowPositioning)
        
        // Find the specific window and adjust its position
        for (index, axWindow) in windows.enumerated() {
            var position: CFTypeRef?
            let posResult = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &position)
            
            if posResult == .success, let posValue = position {
                var currentPos = CGPoint.zero
                AXValueGetValue(posValue as! AXValue, .cgPoint, &currentPos)
                
                logger.debug("Window \(index) position: (\(currentPos.x), \(currentPos.y))", category: .windowPositioning)
                
                // Check if this window is the one we want to move
                if abs(currentPos.y - currentY) < 10 { // Within 10px tolerance
                    // Calculate new position (move window up so it doesn't overlap taskbar)
                    let newY = taskbarY + taskbarHeight + 5 // Add 5px gap
                    var newPosition = CGPoint(x: currentPos.x, y: newY)
                    let newPositionValue = AXValueCreate(.cgPoint, &newPosition)
                    
                    if let newPositionValue = newPositionValue {
                        let setResult = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, newPositionValue)
                        if setResult == .success {
                            logger.info("Successfully moved window \(windowOwner) from Y=\(currentPos.y) to Y=\(newY)", category: .windowPositioning)
                        } else {
                            logger.error("Failed to move window \(windowOwner), result: \(setResult.rawValue)", category: .windowPositioning)
                        }
                    } else {
                        logger.error("Failed to create position value for window \(windowOwner)", category: .windowPositioning)
                    }
                    break
                }
            } else {
                logger.debug("Failed to get position for window \(index), result: \(posResult.rawValue)", category: .windowPositioning)
            }
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