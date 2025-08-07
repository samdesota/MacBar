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
    @Published var spaceWindows: [UInt64: [WindowInfo]] = [:] // Maps space IDs to their windows
    @Published var hasAccessibilityPermission: Bool = false
    @Published var debugInfo: String = ""
    @Published var currentSpaceID: String = ""
    
    private var timer: Timer?
    private var windowOrder: [CGWindowID] = [] // Track order by window ID
    private var taskbarHeight: CGFloat = 42
    private var taskbarY: CGFloat = 0
    private let logger = Logger.shared
    private let spaceManager = SpaceManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    // Space-based window tracking
    private var currentActiveSpaceID: UInt64 = 0
    
    // Window cache to avoid duplicate bridge calls
    private struct WindowCache {
        let windows: [NativeDesktopBridge.NativeWindowInfo]
        let timestamp: Date
        
        func isValid(maxAge: TimeInterval = 0.064) -> Bool {
            return Date().timeIntervalSince(timestamp) < maxAge
        }
    }
    private var windowCache: WindowCache?
    
    // Space-specific window cache
    private struct SpaceWindowCache {
        let windows: [NativeDesktopBridge.NativeWindowInfo]
        let timestamp: Date
        let spaceID: UInt64
        
        func isValid(maxAge: TimeInterval = 0.064) -> Bool {
            return Date().timeIntervalSince(timestamp) < maxAge
        }
    }
    private var spaceWindowCache: SpaceWindowCache?
    
    // Cache management methods
    private func getCachedWindows() -> [NativeDesktopBridge.NativeWindowInfo]? {
        if let cache = windowCache, cache.isValid() {
            return cache.windows
        }
        return nil
    }
    
    private func updateCache(windows: [NativeDesktopBridge.NativeWindowInfo]) {
        windowCache = WindowCache(windows: windows, timestamp: Date())
    }
    
    // Space-specific cache management methods
    private func getCachedWindowsForSpace(_ spaceID: UInt64) -> [NativeDesktopBridge.NativeWindowInfo]? {
        if let cache = spaceWindowCache, cache.isValid() && cache.spaceID == spaceID {
            return cache.windows
        }
        return nil
    }
    
    private func updateSpaceCache(windows: [NativeDesktopBridge.NativeWindowInfo], spaceID: UInt64) {
        spaceWindowCache = SpaceWindowCache(windows: windows, timestamp: Date(), spaceID: spaceID)
    }
    
    private func invalidateSpaceCache() {
        spaceWindowCache = nil
    }
    
    /// Gets visible windows from cache if valid, otherwise fetches fresh data and updates cache
    private func getVisibleWindowsWithCache() -> [NativeDesktopBridge.NativeWindowInfo] {
        if let cachedWindows = getCachedWindows() {
            return cachedWindows
        } else {
            let freshWindows = nativeBridge.getVisibleApplicationWindows()
            updateCache(windows: freshWindows)
            return freshWindows
        }
    }
    
    /// Gets visible windows for a specific space using the more efficient space-specific API with caching
    private func getVisibleWindowsForSpace(_ spaceID: UInt64, includeMinimized: Bool = true) -> [NativeDesktopBridge.NativeWindowInfo] {
        if let cachedWindows = getCachedWindowsForSpace(spaceID) {
            return cachedWindows
        } else {
            let freshWindows = nativeBridge.getVisibleWindowsForSpace(spaceID, includeMinimized: includeMinimized)
            updateSpaceCache(windows: freshWindows, spaceID: spaceID)
            return freshWindows
        }
    }
    
    // Native desktop bridge for all low-level windowing operations
    private let nativeBridge = NativeDesktopBridge()
    
    // Window tiling manager
    private var windowTiling: WindowTiling?
    
    init() {
        let instanceID = UUID().uuidString.prefix(8)
        logger.info("🏗️ WindowManager initialized [\(instanceID)]", category: .windowManager)
        nativeBridge.delegate = self
        
        // Initialize window tiling after bridge is set up
        windowTiling = WindowTiling(nativeBridge: nativeBridge)
        
        checkAccessibilityPermission()
        startMonitoring()
        setupTaskbarPosition()
        
        // Initialize with current active space
        let connectionID = SLSMainConnectionID()
        if connectionID != 0 {
            currentActiveSpaceID = SLSGetActiveSpace(connectionID)
            logger.info("🏗️ WindowManager initialized with space: \(currentActiveSpaceID)", category: .windowManager)
        } else {
            logger.warning("⚠️ Cannot get SLS Connection ID for initial space", category: .windowManager)
            currentActiveSpaceID = 0
        }
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
                let totalWindows = self.spaceWindows.values.flatMap { $0 }.count
                self.debugInfo = "Found \(totalWindows) windows across all spaces"
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
    
    func startMonitoring() {
        logger.info("Starting window monitoring", category: .windowManager)
        // Update immediately
        updateWindowList()
        
        // Set up timer for periodic updates (safety net only - window observers handle real-time updates)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.checkAccessibilityPermission()
            self.updateWindowList() // Full window list refresh every 10 seconds as safety net
            self.windowTiling?.preventTaskbarOverlap() // Now handled by WindowTiling
            self.windowTiling?.clearOldRestrictions() // Clean up old size restriction records
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
    
    func updateCurrentSpace(_ spaceID: UInt64) {
        if currentActiveSpaceID != spaceID {
            logger.info("🔄 Space changed from \(currentActiveSpaceID) to \(spaceID)", category: .windowManager)
            currentActiveSpaceID = spaceID
            // Invalidate space cache since we're switching to a different space
            invalidateSpaceCache()
            updateWindowList()
        }
    }
    
    // MARK: - Space Management
    
    func getWindowsForCurrentSpace() -> [WindowInfo] {
        return spaceWindows[currentActiveSpaceID] ?? []
    }
    
    func getWindowsForSpace(_ spaceID: UInt64) -> [WindowInfo] {
        return spaceWindows[spaceID] ?? []
    }
    
    // MARK: - Window Tiling Interface
    
    /// Get all size-restricted windows for debugging/UI purposes
    func getSizeRestrictedWindows() -> [WindowTiling.SizeRestriction] {
        return windowTiling?.getAllSizeRestrictedWindows() ?? []
    }
    
    /// Check if a specific window is size-restricted
    func isWindowSizeRestricted(_ windowID: CGWindowID) -> Bool {
        return windowTiling?.isWindowSizeRestricted(windowID) ?? false
    }
    
    /// Configure window padding (distance from screen edges)
    func setWindowPadding(_ padding: CGFloat) {
        windowTiling?.setWindowPadding(padding)
    }
    
    /// Get current window padding value
    func getWindowPadding() -> CGFloat {
        return windowTiling?.getWindowPadding() ?? 5
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
        // Invalidate both caches since window list changed
        windowCache = nil
        invalidateSpaceCache()
        updateWindowList()
    }
    
    func onAppLaunched(app: NSRunningApplication) {
        logger.info("🚀 Detected app launch: \(app.localizedName ?? "Unknown")", category: .windowManager)
        // Invalidate both caches since app launch may change window list
        windowCache = nil
        invalidateSpaceCache()
        // Window list will be updated via onWindowListChanged()
    }
    
    func onAppTerminated(app: NSRunningApplication) {
        logger.info("🛑 Detected app termination: \(app.localizedName ?? "Unknown")", category: .windowManager)
        // Invalidate both caches since app termination may change window list
        windowCache = nil
        invalidateSpaceCache()
        // Window list will be updated via onWindowListChanged()
    }
    
    /// Fast update of just the focus status for existing windows (reactive)
    private func updateWindowFocusStatus() {
        let currentSpaceWindows = spaceWindows[currentActiveSpaceID] ?? []
        logger.info("🔄 STARTING reactive focus update for \(currentSpaceWindows.count) windows in space \(currentActiveSpaceID)", category: .focusSwitching)
        
        let startTime = Date()
        var focusChanges: [String] = []
        
        // Get focused window ID from bridge
        let focusedWindowID = nativeBridge.getFocusedWindowID()
        logger.info("🔎 Detected focused window ID: \(focusedWindowID ?? 0)", category: .focusSwitching)
        
        // Log all current window IDs for comparison
        logger.info("📋 Current windows in space \(currentActiveSpaceID):", category: .focusSwitching)
        for window in currentSpaceWindows {
            logger.info("  - ID: \(window.id), Name: \(window.displayName), Owner: \(window.owner), WasActive: \(window.isActive)", category: .focusSwitching)
        }
        
        // Update isActive status for existing windows in the current space
        let updatedWindows = currentSpaceWindows.map { window in
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
                forceShowTitle: window.forceShowTitle,
                spaceID: window.spaceID
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
        
        // Update on main thread - only update the current space
        DispatchQueue.main.async {
            self.logger.info("🎨 Updating SwiftUI @Published spaceWindows for space \(self.currentActiveSpaceID)", category: .focusSwitching)
            self.spaceWindows[self.currentActiveSpaceID] = updatedWindows
            self.logger.info("✅ SwiftUI update completed", category: .focusSwitching)
        }
    }
    
    func updateWindowList() {
        logger.info("🔄 STARTING window list update for current space: \(currentActiveSpaceID)", category: .windowManager)
        
        // Use the more efficient space-specific method to get windows for current space only
        let nativeWindows = getVisibleWindowsForSpace(currentActiveSpaceID, includeMinimized: true)
        
        logger.debug("Found \(nativeWindows.count) native windows for space \(currentActiveSpaceID)", category: .windowManager)
        
        // Convert native windows to WindowInfo format
        var windowInfos: [WindowInfo] = []
        var newWindowOrder: [CGWindowID] = []
        
        for nativeWindow in nativeWindows {
            // Get app icon from bridge
            let appIcon = nativeBridge.getAppIcon(for: nativeWindow.owner)
            
            // Try to get a better window title from bridge
            let betterWindowName = nativeBridge.getWindowTitle(windowID: nativeWindow.windowID) ?? nativeWindow.name
            
            let windowInfo = WindowInfo(
                id: nativeWindow.windowID,
                name: betterWindowName.isEmpty ? nativeWindow.name : betterWindowName,
                owner: nativeWindow.owner,
                icon: appIcon,
                isActive: isWindowActive(nativeWindow.windowID),
                spaceID: nativeWindow.spaceID
            )
            
            // Add window if not already present
            if !windowInfos.contains(where: { $0.id == windowInfo.id }) {
                windowInfos.append(windowInfo)
                newWindowOrder.append(nativeWindow.windowID)
                logger.debug("Added window: \(nativeWindow.owner) - \(nativeWindow.name) (ID: \(nativeWindow.windowID))", category: .windowManager)
            }
        }
        
        // Detect new windows for tiling (before order stabilization)
        let existingWindowIDs = Set((spaceWindows[currentActiveSpaceID] ?? []).map { $0.id })
        let currentWindowIDs = Set(nativeWindows.map { $0.windowID })
        let newWindows = nativeWindows.filter { !existingWindowIDs.contains($0.windowID) }
        let removedWindowIDs = existingWindowIDs.subtracting(currentWindowIDs)
        
        // Clean up tiling tracking for removed windows
        for removedWindowID in removedWindowIDs {
            logger.debug("🗑️ Removing window \(removedWindowID) from tiling tracking", category: .windowManager)
            windowTiling?.removeWindowFromTracking(removedWindowID)
        }
        
        // Trigger tiling for new windows
        for newWindow in newWindows {
            logger.info("🆕 Detected new window for tiling: \(newWindow.owner) - \(newWindow.name)", category: .windowManager)
            windowTiling?.handleNewWindow(windowID: newWindow.windowID, windowInfo: newWindow)
        }
        
        // Apply order stabilization to maintain consistent window ordering
        let orderedWindows = maintainStableOrderByWindow(currentWindows: windowInfos, newOrder: newWindowOrder)

        // Update display names based on whether there are multiple windows per app
        let currentSpaceWindows = updateDisplayNamesForMultipleWindows(orderedWindows)

        let activeSpaceId = self.currentActiveSpaceID

        DispatchQueue.main.async {
            if activeSpaceId != self.currentActiveSpaceID {
                self.logger.info("🎨 Skipping update for space \(self.currentActiveSpaceID) because it's not the active space", category: .windowManager)
                return
            }

            self.logger.info("🎨 Updating space \(self.currentActiveSpaceID) windows: \(currentSpaceWindows.count) windows using space-specific API", category: .windowManager)
            
            // Only update the windows for the current active space, leave other spaces alone
            self.spaceWindows[self.currentActiveSpaceID] = currentSpaceWindows
            
            self.debugInfo = "Found \(currentSpaceWindows.count) windows for current space \(self.currentActiveSpaceID)"
            
            // Debug: Show each window ID and focus status
            let currentFocusedID = self.nativeBridge.getFocusedWindowID()
            self.logger.info("🔎 Current focused window ID: \(currentFocusedID ?? 0)", category: .windowManager)
            self.logger.info("📋 Window list for space \(self.currentActiveSpaceID):", category: .windowManager)
            for window in currentSpaceWindows {
                let isFocused = (currentFocusedID == window.id)
                let focusEmoji = isFocused ? "🔥" : "😴"
                self.logger.info("  \(focusEmoji) ID: \(window.id), Name: \(window.displayName), Owner: \(window.owner), Space: space-\(window.spaceID), IsActive: \(window.isActive), ShouldBeFocused: \(isFocused)", category: .windowManager)
            }
            
            self.logger.info("✅ Window list update completed for space \(self.currentActiveSpaceID)", category: .windowManager)
        }
    }
    
    private func activateAppToBringWindowToFront(windowOwner: String) {
        // Try to activate the app, which might bring its windows to a better position
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == windowOwner }) {
            app.activate()
            logger.info("Activated app \(windowOwner) as fallback", category: .windowPositioning)
        }
    }
    
    private func getVisibleWindows() -> [WindowInfo] {
        var windowInfos: [WindowInfo] = []
        var newWindowOrder: [CGWindowID] = []
        
        // Get all visible application windows from bridge (now includes space mapping)
        let nativeWindows = getVisibleWindowsWithCache()
        
        logger.debug("Total windows found: \(nativeWindows.count)", category: .windowManager)
        

        
        for (index, nativeWindow) in nativeWindows.enumerated() {
            logger.debug("Window \(index): \(nativeWindow.owner) - \(nativeWindow.name) (Layer: \(nativeWindow.layer), Space: \(nativeWindow.spaceID))", category: .windowManager)
            
            // Get app icon from bridge
            let appIcon = nativeBridge.getAppIcon(for: nativeWindow.owner)
            
            // Try to get a better window title from bridge
            let betterWindowName = nativeBridge.getWindowTitle(windowID: nativeWindow.windowID) ?? nativeWindow.name
            
            let windowInfo = WindowInfo(
                id: nativeWindow.windowID,
                name: betterWindowName.isEmpty ? nativeWindow.name : betterWindowName,
                owner: nativeWindow.owner,
                icon: appIcon,
                isActive: isWindowActive(nativeWindow.windowID),
                spaceID: nativeWindow.spaceID
            )
            
            // Add each window individually
            if !windowInfos.contains(where: { $0.id == windowInfo.id }) {
                windowInfos.append(windowInfo)
                newWindowOrder.append(nativeWindow.windowID)
                logger.debug("Added window: \(nativeWindow.owner) - \(nativeWindow.name) (ID: \(nativeWindow.windowID), Space: \(nativeWindow.spaceID))", category: .windowManager)
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
        
        // First, add existing windows in their current order (from current space)
        let existingWindows = spaceWindows[currentActiveSpaceID] ?? []
        
        logger.info("🔄 Maintaining stable order for \(existingWindows.count) existing windows and \(newOrder.count) new windows", category: .windowManager)


        for window in existingWindows {
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
                forceShowTitle: hasMultipleWindows,
                spaceID: window.spaceID
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
        logger.info("Attempting to activate window: \(windowInfo.displayName) (\(windowInfo.owner))", category: .focusSwitching)
        
        let result = nativeBridge.activateWindow(windowID: windowInfo.id)
        
        switch result {
        case .success:
            logger.info("Successfully activated window: \(windowInfo.displayName)", category: .focusSwitching)
        case .failed(let error):
            logger.warning("Failed to activate window: \(windowInfo.displayName), error: \(error)", category: .focusSwitching)
            // Fall back to activating the app
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == windowInfo.owner }) {
                app.activate()
                logger.info("Successfully activated app as fallback: \(app.localizedName ?? "Unknown")", category: .focusSwitching)
            }
        case .permissionDenied:
            logger.warning("Permission denied for activating window: \(windowInfo.displayName)", category: .focusSwitching)
        case .windowNotFound:
            logger.error("Window not found: \(windowInfo.displayName)", category: .focusSwitching)
        }
    }
    
    func minimizeWindow(_ windowInfo: WindowInfo) {
        logger.info("Attempting to minimize window: \(windowInfo.displayName)", category: .focusSwitching)
        
        let result = nativeBridge.minimizeWindow(windowID: windowInfo.id)
        
        switch result {
        case .success:
            logger.info("Successfully minimized window: \(windowInfo.displayName)", category: .focusSwitching)
        case .failed(let error):
            logger.warning("Failed to minimize window: \(windowInfo.displayName), error: \(error)", category: .focusSwitching)
        case .permissionDenied:
            logger.warning("Permission denied for minimizing window: \(windowInfo.displayName)", category: .focusSwitching)
        case .windowNotFound:
            logger.error("Window not found: \(windowInfo.displayName)", category: .focusSwitching)
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
    let spaceID: UInt64
    
    init(id: CGWindowID, name: String, owner: String, icon: NSImage?, isActive: Bool, forceShowTitle: Bool = false, spaceID: UInt64) {
        self.id = id
        self.name = name
        self.owner = owner
        self.icon = icon
        self.isActive = isActive
        self.forceShowTitle = forceShowTitle
        self.spaceID = spaceID
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
