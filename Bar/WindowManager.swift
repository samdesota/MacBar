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
    @Published var hiddenSpaces: Set<String> = []
    
    private var timer: Timer?
    private var windowOrder: [UInt64: [CGWindowID]] = [:] // Track order by space ID -> window IDs
    private var taskbarY: CGFloat = 0
    private let logger = Logger.shared
    private let spaceManager = SpaceManager.shared
    private var cancellables = Set<AnyCancellable>()
    private let backgroundQueue = DispatchQueue(label: "com.bar.window-manager", qos: .userInitiated)
    
    // Space-based window tracking
    private var currentActiveSpaceID: UInt64 = 0

    // Custom window names (windowID -> custom name)
    private var customWindowNames: [CGWindowID: String] = [:]
    
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
    
    // Firefox favicon receiver for browser window icons
    private var firefoxReceiver: FirefoxFaviconReceiver?
    
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
    
    // MARK: - Firefox Integration
    
    func setFirefoxReceiver(_ receiver: FirefoxFaviconReceiver) {
        self.firefoxReceiver = receiver
        
        // Set up callback to refresh window list when favicon is updated
        receiver.onFaviconUpdated = { [weak self] in
            guard let self = self else { return }
            self.logger.info("🔔 Favicon updated, refreshing window list immediately", category: .windowManager)
            self.updateWindowList()
        }
        
        logger.info("🦊 Firefox favicon receiver connected to WindowManager", category: .windowManager)
    }
    
    func setupTaskbarPosition() {
        // Calculate taskbar position based on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            taskbarY = screenFrame.maxY - 5 // Same as in BarApp.swift
            logger.info("Taskbar positioned at Y: \(taskbarY), height: \(WindowTiling.taskbarHeight)", category: .windowPositioning)
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
        // The timer fires on main but dispatches AX-heavy work to a background queue
        // so unresponsive apps don't freeze the UI.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.checkAccessibilityPermission()

            self.backgroundQueue.async { [weak self] in
                guard let self = self else { return }
                self.updateWindowList()
                self.windowTiling?.preventTaskbarOverlap()
                self.windowTiling?.rebalanceSplitViews()
                self.windowTiling?.clearOldRestrictions()

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // Clean up split groups for windows that no longer exist
                    let currentWindowIDs = Set((self.spaceWindows[self.currentActiveSpaceID] ?? []).map { $0.id })
                    self.windowTiling?.cleanupSplitGroups(availableWindowIDs: currentWindowIDs)

                    // Clean up custom names — check all spaces, not just current
                    if !self.customWindowNames.isEmpty {
                        let allWindowIDs = Set(self.spaceWindows.values.flatMap { $0 }.map { $0.id })
                        let removed = self.customWindowNames.filter { !allWindowIDs.contains($0.key) }
                        if !removed.isEmpty {
                            for (id, name) in removed {
                                self.logger.info("🗑️ Removing custom name '\(name)' for window \(id) — not found in any space (spaces: \(self.spaceWindows.keys.sorted()), allWindowIDs count: \(allWindowIDs.count))", category: .windowManager)
                            }
                        }
                        self.customWindowNames = self.customWindowNames.filter { allWindowIDs.contains($0.key) }
                    }
                }
            }
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
            syncBarHiddenToTiling()
            updateWindowList()
        }
    }
    
    // MARK: - Space Management
    
    func getWindowsForCurrentSpace() -> [WindowInfo] {
        return getWindowsForSpace(currentActiveSpaceID)
    }
    
    func getWindowsForSpace(_ spaceID: UInt64) -> [WindowInfo] {
        guard let windows = spaceWindows[spaceID] else { return [] }
        
        // Get the custom order for this space, or use natural order
        guard let order = windowOrder[spaceID] else {
            return windows
        }
        
        // Sort windows according to custom order
        let orderedWindows = order.compactMap { windowID in
            windows.first { $0.id == windowID }
        }
        
        // Add any windows not in the order list (newly appeared windows)
        let unorderedWindows = windows.filter { window in
            !order.contains(window.id)
        }
        
        return orderedWindows + unorderedWindows
    }
    
    /// Reorder windows within a space by moving a window from one position to another
    func reorderWindow(windowID: CGWindowID, fromIndex: Int, toIndex: Int, spaceID: UInt64) {
        guard let windows = spaceWindows[spaceID] else { return }
        
        // Initialize window order if it doesn't exist
        if windowOrder[spaceID] == nil {
            windowOrder[spaceID] = windows.map { $0.id }
        }
        
        guard var order = windowOrder[spaceID] else { return }
        
        // Ensure indices are valid
        guard fromIndex >= 0 && fromIndex < order.count && 
              toIndex >= 0 && toIndex < order.count && 
              fromIndex != toIndex else { return }
        
        // Move the window ID from one position to another
        let movedWindowID = order.remove(at: fromIndex)
        order.insert(movedWindowID, at: toIndex)
        
        // Update the order
        windowOrder[spaceID] = order
        
        // Trigger UI update
        objectWillChange.send()
        
        logger.info("Reordered window \(windowID) from index \(fromIndex) to \(toIndex) in space \(spaceID)", category: .taskbar)
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
    
    /// Execute vertical split layout for multiple windows
    func executeVerticalSplit(windows: [WindowInfo]) {
        windowTiling?.executeVerticalSplit(windows: windows)
    }
    
    /// Remove the currently focused window from its split group
    func removeFocusedWindowFromSplit() {
        let focused = nativeBridge.getFocusedWindowID()
        if let id = focused {
            logger.info("Removing focused window from split: \(id)", category: .windowManager)
            _ = windowTiling?.removeWindowFromSplit(windowID: id, dissolveIfPair: true)
        } else {
            logger.debug("No focused window to remove from split", category: .windowManager)
        }
    }
    
    /// Tile the currently focused window to fullscreen (manual user action)
    func tileCurrentWindowToFullscreen() {
        guard let focusedWindowID = nativeBridge.getFocusedWindowID() else {
            logger.warning("No focused window to tile to fullscreen", category: .windowManager)
            return
        }
        
        logger.info("🔲 Tiling focused window \(focusedWindowID) to fullscreen", category: .windowManager)
        windowTiling?.tileWindowToFullscreen(windowID: focusedWindowID)
    }
    
    /// Set a custom name for a window
    func nameWindow(windowID: CGWindowID?, name: String) {
        let targetID: CGWindowID
        if let windowID = windowID {
            targetID = windowID
        } else if let focusedID = nativeBridge.getFocusedWindowID() {
            targetID = focusedID
        } else {
            logger.warning("No window ID provided and no focused window", category: .windowManager)
            return
        }
        customWindowNames[targetID] = name
        logger.info("Named window \(targetID) as '\(name)'", category: .windowManager)
        updateWindowList()
    }

    /// Handle focus change for split window synchronization
    private func handleFocusChangeForSplitSync(windowID: CGWindowID?) {
        windowTiling?.handleWindowFocusChanged(focusedWindowID: windowID)
    }

    // MARK: - Bar Hide Mode

    func isBarHidden(for spaceID: String) -> Bool {
        return hiddenSpaces.contains(spaceID)
    }

    func isBarHiddenForCurrentSpace() -> Bool {
        let spaceIDString = "space-\(currentActiveSpaceID)"
        return hiddenSpaces.contains(spaceIDString)
    }

    func toggleBarHidden() {
        let spaceIDString = "space-\(currentActiveSpaceID)"
        if hiddenSpaces.contains(spaceIDString) {
            hiddenSpaces.remove(spaceIDString)
            logger.info("🙈 Bar unhidden for space \(spaceIDString)", category: .windowManager)
        } else {
            hiddenSpaces.insert(spaceIDString)
            logger.info("🙈 Bar hidden for space \(spaceIDString)", category: .windowManager)
        }
        syncBarHiddenToTiling()
        windowTiling?.adjustWindowsForBarToggle()
    }

    func syncBarHiddenToTiling() {
        windowTiling?.isBarHidden = isBarHiddenForCurrentSpace()
    }

    // MARK: - NativeDesktopBridgeDelegate
    
    func onFocusedWindowChanged(windowID: CGWindowID?) {
        logger.info("🔄 Focus changed to window ID: \(windowID ?? 0)", category: .focusSwitching)
        updateWindowFocusStatus()
    }
    
    func onFrontmostAppChanged(app: NSRunningApplication?) {
        let appName = app?.localizedName ?? "None"
        logger.info("🎯 App changed to: \(appName)", category: .focusSwitching)
        backgroundQueue.async { [weak self] in
            self?.updateWindowFocusStatus()
        }
    }

    func onWindowListChanged() {
        logger.info("📋 Window list changed", category: .windowManager)
        // Invalidate both caches since window list changed
        windowCache = nil
        invalidateSpaceCache()
        backgroundQueue.async { [weak self] in
            self?.updateWindowList()
        }
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
                spaceID: window.spaceID,
                customName: window.customName
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
        
        // Handle split window synchronization before updating UI
        if let focusedWindowID = focusedWindowID {
            handleFocusChangeForSplitSync(windowID: focusedWindowID)
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
            // Try to get a better window title from bridge first
            let betterWindowName = nativeBridge.getWindowTitle(windowID: nativeWindow.windowID) ?? nativeWindow.name
            
            // Try to get Firefox favicon first if this is a Firefox window
            var appIcon: NSImage? = nil
            var isFavicon = false
            if nativeWindow.owner == "Firefox", let receiver = firefoxReceiver {
                appIcon = receiver.getFavicon(forWindowTitle: betterWindowName)
                if appIcon != nil {
                    isFavicon = true
                    logger.debug("🦊 Using Firefox favicon for window '\(betterWindowName)'", category: .windowManager)
                } else {
                    logger.debug("🦊 No Firefox favicon match for window '\(betterWindowName)'", category: .windowManager)
                }
            }
            
            // Fall back to app icon if no Firefox favicon
            if appIcon == nil {
                appIcon = nativeBridge.getAppIcon(for: nativeWindow.owner)
            }
            
            let windowInfo = WindowInfo(
                id: nativeWindow.windowID,
                name: betterWindowName.isEmpty ? nativeWindow.name : betterWindowName,
                owner: nativeWindow.owner,
                icon: appIcon,
                isActive: isWindowActive(nativeWindow.windowID),
                spaceID: nativeWindow.spaceID,
                isFavicon: isFavicon
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
        windowOrder[currentActiveSpaceID] = orderedWindows.map { $0.id }

        // Update display names based on whether there are multiple windows per app
        let currentSpaceWindows = updateDisplayNamesForMultipleWindows(orderedWindows)

        let activeSpaceId = self.currentActiveSpaceID

        // Resolve focused window ID here (off main thread) so the AX call
        // doesn't block the UI if an app is unresponsive.
        let currentFocusedID = self.nativeBridge.getFocusedWindowID()

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
        let existingWindows = getWindowsForSpace(currentActiveSpaceID)
        
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
                spaceID: window.spaceID,
                customName: customWindowNames[window.id]
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
    
    func closeWindow(_ windowInfo: WindowInfo) {
        logger.info("Attempting to close window: \(windowInfo.displayName)", category: .focusSwitching)
        
        let result = nativeBridge.closeWindow(windowID: windowInfo.id)
        
        switch result {
        case .success:
            logger.info("Successfully closed window: \(windowInfo.displayName)", category: .focusSwitching)
        case .failed(let error):
            logger.warning("Failed to close window: \(windowInfo.displayName), error: \(error)", category: .focusSwitching)
        case .permissionDenied:
            logger.warning("Permission denied for closing window: \(windowInfo.displayName)", category: .focusSwitching)
        case .windowNotFound:
            logger.error("Window not found: \(windowInfo.displayName)", category: .focusSwitching)
        }
    }
    
    /// Close all windows except the currently focused one
    func closeOtherWindows() {
        logger.info("Attempting to close all other windows except current", category: .focusSwitching)
        
        let currentWindows = getWindowsForCurrentSpace()
        let focusedWindowID = nativeBridge.getFocusedWindowID()
        
        guard let focusedID = focusedWindowID else {
            logger.warning("No focused window found, cannot close other windows", category: .focusSwitching)
            return
        }
        
        let windowsToClose = currentWindows.filter { $0.id != focusedID }
        logger.info("Closing \(windowsToClose.count) windows (keeping focused window \(focusedID))", category: .focusSwitching)
        
        for window in windowsToClose {
            closeWindow(window)
        }
    }
    
    /// Close all windows to the left of the currently focused window in the taskbar order
    func closeWindowsToLeft() {
        logger.info("Attempting to close windows to the left of current window", category: .focusSwitching)
        
        let currentWindows = getWindowsForCurrentSpace()
        let focusedWindowID = nativeBridge.getFocusedWindowID()
        
        guard let focusedID = focusedWindowID else {
            logger.warning("No focused window found, cannot close windows to left", category: .focusSwitching)
            return
        }
        
        guard let focusedIndex = currentWindows.firstIndex(where: { $0.id == focusedID }) else {
            logger.warning("Focused window not found in current space windows", category: .focusSwitching)
            return
        }
        
        let windowsToClose = Array(currentWindows[0..<focusedIndex])
        logger.info("Closing \(windowsToClose.count) windows to the left of focused window", category: .focusSwitching)
        
        for window in windowsToClose {
            closeWindow(window)
        }
    }
    
    /// Close all windows to the right of the currently focused window in the taskbar order
    func closeWindowsToRight() {
        logger.info("Attempting to close windows to the right of current window", category: .focusSwitching)
        
        let currentWindows = getWindowsForCurrentSpace()
        let focusedWindowID = nativeBridge.getFocusedWindowID()
        
        guard let focusedID = focusedWindowID else {
            logger.warning("No focused window found, cannot close windows to right", category: .focusSwitching)
            return
        }
        
        guard let focusedIndex = currentWindows.firstIndex(where: { $0.id == focusedID }) else {
            logger.warning("Focused window not found in current space windows", category: .focusSwitching)
            return
        }
        
        let windowsToClose = Array(currentWindows[(focusedIndex + 1)...])
        logger.info("Closing \(windowsToClose.count) windows to the right of focused window", category: .focusSwitching)
        
        for window in windowsToClose {
            closeWindow(window)
        }
    }
    
    // MARK: - Screen Movement
    
    /// Move the focused window to a screen in the specified direction
    func moveFocusedWindowToScreen(direction: ScreenDirection) {
        guard let focusedWindowID = nativeBridge.getFocusedWindowID() else {
            logger.warning("No focused window to move to screen", category: .windowManager)
            return
        }
        
        logger.info("🖥️ Moving focused window \(focusedWindowID) to screen in direction: \(direction.rawValue)", category: .windowManager)
        nativeBridge.moveWindowToScreen(windowID: focusedWindowID, direction: direction)
    }
}

enum ScreenDirection: String {
    case left = "left"
    case right = "right"
    case up = "up"
    case down = "down"
}

struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let name: String
    let owner: String
    let icon: NSImage?
    let isActive: Bool
    let forceShowTitle: Bool
    let spaceID: UInt64
    let isFavicon: Bool
    
    init(id: CGWindowID, name: String, owner: String, icon: NSImage?, isActive: Bool, forceShowTitle: Bool = false, spaceID: UInt64, isFavicon: Bool = false, customName: String? = nil) {
        self.id = id
        self.name = name
        self.owner = owner
        self.icon = icon
        self.isActive = isActive
        self.forceShowTitle = forceShowTitle
        self.spaceID = spaceID
        self.isFavicon = isFavicon
        self.customName = customName
    }
    
    let customName: String?

    var displayName: String {
        // Custom name takes priority
        if let customName = customName, !customName.isEmpty {
            return customName
        }
        // Always show window title when available
        if !name.isEmpty && name != owner {
            let maxLength = 50
            if name.count > maxLength {
                return String(name.prefix(maxLength)) + "..."
            }
            return name
        }
        return owner
    }
    
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        return lhs.id == rhs.id && lhs.name == rhs.name && lhs.owner == rhs.owner
    }
} 
