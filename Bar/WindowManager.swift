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

class WindowManager: ObservableObject, NativeDesktopBridgeDelegate {
    @Published var openWindows: [WindowInfo] = []
    @Published var hasAccessibilityPermission: Bool = false
    @Published var debugInfo: String = ""
    private var timer: Timer?
    private var windowOrder: [CGWindowID] = [] // Track order by window ID
    private var taskbarHeight: CGFloat = 42
    private var taskbarY: CGFloat = 0
    private let logger = Logger.shared
    
    // Native desktop bridge for all low-level windowing operations
    private let nativeBridge = NativeDesktopBridge()
    
    init() {
        let instanceID = UUID().uuidString.prefix(8)
        logger.info("🏗️ WindowManager initialized [\(instanceID)]", category: .focusSwitching)
        nativeBridge.delegate = self
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
        let hasPermission = nativeBridge.checkAccessibilityPermission()
        
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
    
    func refreshWindowObservers() {
        logger.info("Manually refreshing window observers", category: .windowManager)
        nativeBridge.refreshWindowObservers()
    }
    
    func printObserverStatus() {
        nativeBridge.printObserverStatus()
    }
    
    func testWindowDetection() {
        logger.info("🧪 Manual window detection test", category: .windowManager)
        updateWindowList()
        printObserverStatus()
    }
    
    func testFinderDetection() {
        logger.info("🗂️ Testing Finder window detection", category: .windowManager)
        refreshWindowObservers() // This will now include Finder
        printObserverStatus()
        
        // Check if Finder windows are being detected
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let finderWindows = self.openWindows.filter { $0.owner == "Finder" }
            self.logger.info("📁 Found \(finderWindows.count) Finder windows", category: .windowManager)
            for window in finderWindows {
                self.logger.info("  - \(window.displayName) (ID: \(window.id))", category: .windowManager)
            }
        }
    }
    
    func startMonitoring() {
        logger.info("Starting window monitoring", category: .windowManager)
        // Update immediately
        updateWindowList()
        
        // Set up timer for periodic updates (safety net only - window observers handle real-time updates)
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkAccessibilityPermission()
            self?.updateWindowList() // Full window list refresh every 5 minutes as safety net
            self?.preventTaskbarOverlap()
        }
        
        // Refresh observers after a delay to ensure everything is set up properly
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.logger.info("🔄 Initial observer refresh after startup delay", category: .windowManager)
            self?.refreshWindowObservers()
            
            // Print status for debugging
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.printObserverStatus()
            }
        }
    }
    
    func stopMonitoring() {
        logger.info("Stopping window monitoring", category: .windowManager)
        timer?.invalidate()
        timer = nil
    }
    
    // MARK: - NativeDesktopBridgeDelegate
    
    func onFocusedWindowChanged(windowID: CGWindowID?) {
        logger.info("🔄 Focus changed to window ID: \(windowID ?? 0)", category: .focusSwitching)
        updateWindowFocusStatus()
    }
    
    func onFrontmostAppChanged(app: NSRunningApplication?) {
        let appName = app?.localizedName ?? "None"
        logger.info("🎯 App changed to: \(appName)", category: .focusSwitching)
        updateWindowFocusStatus()
    }
    
    func onWindowListChanged() {
        logger.info("📋 Window list changed", category: .windowManager)
        updateWindowList()
    }
    
    func onAppLaunched(app: NSRunningApplication) {
        logger.info("🚀 Detected app launch: \(app.localizedName ?? "Unknown")", category: .windowManager)
        // Window list will be updated via onWindowListChanged()
    }
    
    func onAppTerminated(app: NSRunningApplication) {
        logger.info("🛑 Detected app termination: \(app.localizedName ?? "Unknown")", category: .windowManager)
        // Window list will be updated via onWindowListChanged()
    }
    
    /// Fast update of just the focus status for existing windows (reactive)
    private func updateWindowFocusStatus() {
        logger.info("🔄 STARTING reactive focus update for \(openWindows.count) windows", category: .focusSwitching)
        
        let startTime = Date()
        var focusChanges: [String] = []
        
        // Get focused window ID from bridge
        let focusedWindowID = nativeBridge.getFocusedWindowID()
        logger.info("🔎 Detected focused window ID: \(focusedWindowID ?? 0)", category: .focusSwitching)
        
        // Log all current window IDs for comparison
        logger.info("📋 Current windows in array:", category: .focusSwitching)
        for window in openWindows {
            logger.info("  - ID: \(window.id), Name: \(window.displayName), Owner: \(window.owner), WasActive: \(window.isActive)", category: .focusSwitching)
        }
        
        // Update isActive status for existing windows
        let updatedWindows = openWindows.map { window in
            let wasActive = window.isActive
            let isNowActive = (focusedWindowID == window.id)
            
            logger.debug("🔍 Window \(window.id): focused=\(focusedWindowID ?? 0), wasActive=\(wasActive), isNowActive=\(isNowActive)", category: .focusSwitching)
            
            if wasActive != isNowActive {
                let changeType = isNowActive ? "GAINED" : "LOST"
                let emoji = isNowActive ? "🔥" : "😴"
                focusChanges.append("\(emoji) \(window.displayName) (\(window.owner)) \(changeType) focus")
            }
            
            return WindowInfo(
                id: window.id,
                name: window.name,
                owner: window.owner,
                icon: window.icon,
                isActive: isNowActive,
                forceShowTitle: window.forceShowTitle
            )
        }
        
        let duration = Date().timeIntervalSince(startTime) * 1000
        
        if focusChanges.isEmpty {
            logger.debug("🔄 No focus changes detected (\(String(format: "%.1f", duration))ms)", category: .focusSwitching)
        } else {
            logger.info("🔄 Focus changes detected (\(String(format: "%.1f", duration))ms):", category: .focusSwitching)
            for change in focusChanges {
                logger.info("  \(change)", category: .focusSwitching)
            }
        }
        
        // Update on main thread
        DispatchQueue.main.async {
            self.logger.info("🎨 Updating SwiftUI @Published openWindows array", category: .focusSwitching)
            self.openWindows = updatedWindows
            self.logger.info("✅ SwiftUI update completed", category: .focusSwitching)
        }
    }
    
    func updateWindowList() {
        logger.info("🔄 STARTING full window list update (timer-based)", category: .focusSwitching)
        let windows = getVisibleWindows()
        
        DispatchQueue.main.async {
            self.logger.info("🎨 Updating SwiftUI @Published openWindows (full refresh: \(windows.count) windows)", category: .focusSwitching)
            self.openWindows = windows
            self.debugInfo = "Found \(windows.count) windows"
            
            // Debug: Show each window ID and focus status
            let currentFocusedID = self.nativeBridge.getFocusedWindowID()
            self.logger.info("🔎 Current focused window ID: \(currentFocusedID ?? 0)", category: .focusSwitching)
            self.logger.info("📋 Window list with focus status:", category: .focusSwitching)
            for window in windows {
                let isFocused = (currentFocusedID == window.id)
                let focusEmoji = isFocused ? "🔥" : "😴"
                self.logger.info("  \(focusEmoji) ID: \(window.id), Name: \(window.displayName), Owner: \(window.owner), IsActive: \(window.isActive), ShouldBeFocused: \(isFocused)", category: .focusSwitching)
            }
            
            self.logger.info("✅ Full window list update completed", category: .focusSwitching)
        }
    }
    
    func preventTaskbarOverlap() {
        guard hasAccessibilityPermission else { 
            logger.debug("Skipping overlap prevention - no accessibility permission", category: .windowPositioning)
            return 
        }
        
        // Update taskbar position in case screen changed
        setupTaskbarPosition()
        
        let allWindows = nativeBridge.getAllWindows(includeOffscreen: false)
        
        logger.debug("Checking \(allWindows.count) windows for overlap", category: .windowPositioning)
        
        for window in allWindows {
            // Skip our own app and system windows
            let systemApps = ["Bar", "Dock", "SystemUIServer", "ControlCenter", "NotificationCenter"]
            if systemApps.contains(window.owner) {
                continue
            }
            
            // Check if window overlaps with taskbar
            let windowBottom = window.bounds.minY
            let windowTop = window.bounds.maxY
            let taskbarTop = taskbarY + taskbarHeight
            
            logger.debug("Window \(window.owner): Y=\(window.bounds.minY), H=\(window.bounds.height), Bottom=\(windowBottom), Top=\(windowTop), TaskbarY=\(taskbarY), TaskbarTop=\(taskbarTop)", category: .windowPositioning)
            
            // Check if window overlaps with taskbar area
            if windowBottom < taskbarTop && windowTop > taskbarY {
                logger.info("Window \(window.owner) overlaps taskbar - adjusting position", category: .windowPositioning)
                
                // Calculate new height to avoid taskbar overlap
                let newHeight = taskbarY - window.bounds.minY - 5
                let minHeight: CGFloat = 200
                let finalHeight = max(newHeight, minHeight)
                
                // Resize window using bridge
                let newSize = CGSize(width: window.bounds.width, height: finalHeight)
                let result = nativeBridge.resizeWindow(windowID: window.windowID, to: newSize)
                
                switch result {
                case .success:
                    logger.info("Successfully resized window \(window.owner) to avoid taskbar overlap", category: .windowPositioning)
                case .failed(let error):
                    logger.warning("Failed to resize window \(window.owner): \(error)", category: .windowPositioning)
                case .permissionDenied:
                    logger.warning("Permission denied for resizing window \(window.owner)", category: .windowPositioning)
                case .windowNotFound:
                    logger.warning("Window not found for resizing: \(window.owner)", category: .windowPositioning)
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
    
    private func getVisibleWindows() -> [WindowInfo] {
        var windowInfos: [WindowInfo] = []
        var newWindowOrder: [CGWindowID] = []
        
        // Get all visible application windows from bridge
        let nativeWindows = nativeBridge.getVisibleApplicationWindows()
        
        logger.debug("Total windows found: \(nativeWindows.count)", category: .windowManager)
        
        for (index, nativeWindow) in nativeWindows.enumerated() {
            logger.debug("Window \(index): \(nativeWindow.owner) - \(nativeWindow.name) (Layer: \(nativeWindow.layer))", category: .windowManager)
            
            // Get app icon from bridge
            let appIcon = nativeBridge.getAppIcon(for: nativeWindow.owner)
            
            // Try to get a better window title from bridge
            let betterWindowName = nativeBridge.getWindowTitle(windowID: nativeWindow.windowID) ?? nativeWindow.name
            
            let windowInfo = WindowInfo(
                id: nativeWindow.windowID,
                name: betterWindowName.isEmpty ? nativeWindow.name : betterWindowName,
                owner: nativeWindow.owner,
                icon: appIcon,
                isActive: isWindowActive(nativeWindow.windowID)
            )
            
            // Add each window individually
            if !windowInfos.contains(where: { $0.id == windowInfo.id }) {
                windowInfos.append(windowInfo)
                newWindowOrder.append(nativeWindow.windowID)
                logger.debug("Added window: \(nativeWindow.owner) - \(nativeWindow.name) (ID: \(nativeWindow.windowID))", category: .windowManager)
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
    
    private func isWindowActive(_ windowID: CGWindowID) -> Bool {
        let focusedID = nativeBridge.getFocusedWindowID()
        return focusedID == windowID
    }
    
    private func getWindowOwner(_ windowID: CGWindowID) -> String? {
        let options = CGWindowListOption(arrayLiteral: .optionIncludingWindow)
        let windowList = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]] ?? []
        
        return windowList.first?[kCGWindowOwnerName as String] as? String
    }
    
    func activateWindow(_ windowInfo: WindowInfo) {
        logger.info("Attempting to activate window: \(windowInfo.displayName) (\(windowInfo.owner))", category: .taskbar)
        
        let result = nativeBridge.activateWindow(windowID: windowInfo.id)
        
        switch result {
        case .success:
            logger.info("Successfully activated window: \(windowInfo.displayName)", category: .taskbar)
        case .failed(let error):
            logger.warning("Failed to activate window: \(windowInfo.displayName), error: \(error)", category: .taskbar)
            // Fall back to activating the app
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == windowInfo.owner }) {
                app.activate(options: .activateIgnoringOtherApps)
                logger.info("Successfully activated app as fallback: \(app.localizedName)", category: .taskbar)
            }
        case .permissionDenied:
            logger.warning("Permission denied for activating window: \(windowInfo.displayName)", category: .taskbar)
        case .windowNotFound:
            logger.error("Window not found: \(windowInfo.displayName)", category: .taskbar)
        }
    }
    
    func minimizeWindow(_ windowInfo: WindowInfo) {
        logger.info("Attempting to minimize window: \(windowInfo.displayName)", category: .taskbar)
        
        let result = nativeBridge.minimizeWindow(windowID: windowInfo.id)
        
        switch result {
        case .success:
            logger.info("Successfully minimized window: \(windowInfo.displayName)", category: .taskbar)
        case .failed(let error):
            logger.warning("Failed to minimize window: \(windowInfo.displayName), error: \(error)", category: .taskbar)
        case .permissionDenied:
            logger.warning("Permission denied for minimizing window: \(windowInfo.displayName)", category: .taskbar)
        case .windowNotFound:
            logger.error("Window not found: \(windowInfo.displayName)", category: .taskbar)
        }
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
