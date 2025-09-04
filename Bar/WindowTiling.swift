//
//  WindowTiling.swift
//  Bar
//
//  Created by Samuel DeSota on 7/31/25.
//

import Foundation
import AppKit
import ApplicationServices

/// Manages window tiling behavior and state
class WindowTiling: ObservableObject {
    private let logger = Logger.shared
    private weak var nativeBridge: NativeDesktopBridge?
    
    // Configuration - matches WindowManager values
    private let taskbarHeight: CGFloat = 42
    
    // Window padding configuration - adjustable for user preferences
    var windowPadding: CGFloat = 5  // Padding around all sides of windows
    
    // State tracking for size-restricted windows
    @Published var sizeRestrictedWindows: [CGWindowID: SizeRestriction] = [:]
    
    // Window tiling state
    private var tiledWindows: Set<CGWindowID> = []
    
    // Split group tracking
    private var splitGroups: [Set<CGWindowID>] = []
    private var windowToSplitGroup: [CGWindowID: Int] = [:]
    
    // Active split group focus state
    private var activeSplitGroupIndex: Int?
    private var hasBroughtActiveGroupToFront: Bool = false

    // Rebalancing state
    private var previousWindowBounds: [CGWindowID: CGRect] = [:]
    private var lastAdjustedWindows: [CGWindowID: Date] = [:]
    private let rebalanceCooldown: TimeInterval = 2.2 // seconds
    
    // Focus synchronization debouncing
    private var lastFocusSyncTime: Date = Date.distantPast
    private var lastSyncedWindowID: CGWindowID?
    private let focusSyncCooldown: TimeInterval = 1.0  // 1 second cooldown
    
    struct SizeRestriction {
        let windowID: CGWindowID
        let maxSize: CGSize
        let minSize: CGSize
        let canResize: Bool
        let owner: String
        let detectedAt: Date
    }
    
    init(nativeBridge: NativeDesktopBridge) {
        self.nativeBridge = nativeBridge
        logger.info("🧩 WindowTiling initialized", category: .windowTiling)
    }
    
    // MARK: - Public Interface
    
    /// Attempt to tile a newly created window to fullscreen (respecting taskbar)
    func handleNewWindow(windowID: CGWindowID, windowInfo: NativeDesktopBridge.NativeWindowInfo) {
        logger.info("🧩 Handling new window: \(windowInfo.owner) - \(windowInfo.name) (ID: \(windowID))", category: .windowTiling)
        
        // Skip system windows and tiny windows, but use higher thresholds for new window tiling
        if shouldSkipWindow(windowInfo.owner, windowInfo.bounds) || 
           windowInfo.bounds.width < 200 || windowInfo.bounds.height < 100 {
            logger.debug("Skipping window: \(windowInfo.owner) (\(windowInfo.bounds.width)x\(windowInfo.bounds.height))", category: .windowTiling)
            return
        }
        
        // Also skip Finder for new window tiling (but allow it in overlap prevention)
        if windowInfo.owner == "Finder" {
            logger.debug("Skipping Finder for tiling", category: .windowTiling)
            return
        }
        
        // Calculate the ideal fullscreen bounds (respecting taskbar)
        guard let targetBounds = calculateFullscreenBounds() else {
            logger.warning("Cannot calculate fullscreen bounds for window tiling", category: .windowTiling)
            return
        }
        
        logger.info("🧩 Attempting to tile window \(windowInfo.owner) to fullscreen: \(targetBounds)", category: .windowTiling)
        
        // Attempt to resize and position the window
        attemptFullscreenTiling(windowID: windowID, targetBounds: targetBounds, windowInfo: windowInfo)
    }
    
    /// Check if a window has been identified as size-restricted
    func isWindowSizeRestricted(_ windowID: CGWindowID) -> Bool {
        return sizeRestrictedWindows[windowID] != nil
    }
    
    /// Get size restriction info for a window
    func getSizeRestriction(for windowID: CGWindowID) -> SizeRestriction? {
        return sizeRestrictedWindows[windowID]
    }
    
    /// Get all size-restricted windows
    func getAllSizeRestrictedWindows() -> [SizeRestriction] {
        return Array(sizeRestrictedWindows.values)
    }

    /// Periodically rebalance split view windows to remove gaps created by user-initiated resizes
    func rebalanceSplitViews() {
        guard let bridge = nativeBridge else {
            logger.warning("NativeBridge not available for rebalance", category: .windowTiling)
            return
        }

        // Permission and mode checks similar to overlap prevention
        if !bridge.checkAccessibilityPermission() { return }
        if bridge.maybeMissionControlIsActive() { return }

        // Prune old adjusted markers
        let now = Date()
        lastAdjustedWindows = lastAdjustedWindows.filter { now.timeIntervalSince($0.value) < rebalanceCooldown }

        // Process each split group
        for (groupIndex, idSet) in splitGroups.enumerated() {
            let windowIDs = Array(idSet)
            guard windowIDs.count >= 2 else { continue }

            // Collect current bounds; drop windows we cannot read
            var currentBoundsByID: [CGWindowID: CGRect] = [:]
            for id in windowIDs {
                if let b = bridge.getWindowBounds(windowID: id) {
                    currentBoundsByID[id] = b
                }
            }
            // If we failed to read all, continue but only with those available
            let availableIDs = windowIDs.compactMap { currentBoundsByID[$0] != nil ? $0 : nil }
            if availableIDs.count < 2 { continue }

            // Sort windows left-to-right based on current X
            let ordered = availableIDs.sorted { (lhs, rhs) -> Bool in
                guard let lb = currentBoundsByID[lhs], let rb = currentBoundsByID[rhs] else { return false }
                return lb.minX < rb.minX
            }

            // Detect user-initiated changes (size change vs previous), skipping windows we adjusted recently
            let sizeTolerance: CGFloat = 2.0
            var candidates: [Int] = [] // indices into ordered
            for (idx, wid) in ordered.enumerated() {
                guard let cur = currentBoundsByID[wid] else { continue }
                if let prev = previousWindowBounds[wid] {
                    let wDiff = abs(cur.width - prev.width)
                    let hDiff = abs(cur.height - prev.height)
                    let changedByUser = (wDiff > sizeTolerance || hDiff > sizeTolerance) && (lastAdjustedWindows[wid] == nil)
                    if changedByUser {
                        candidates.append(idx)
                    }
                } else {
                    // No previous record; seed it but don't act this frame
                    previousWindowBounds[wid] = cur
                }
            }

            // If no user-changed windows detected, update previous and continue
            if candidates.isEmpty {
                for wid in ordered { if let cur = currentBoundsByID[wid] { previousWindowBounds[wid] = cur } }
                continue
            }

            // For each changed window, fill the largest adjacent gap by expanding the neighbor
            for idx in candidates {
                let wid = ordered[idx]
                guard let cur = currentBoundsByID[wid] else { continue }

                // Determine neighbors
                let count = ordered.count
                let hasPrev = idx - 1 >= 0
                let hasNext = idx + 1 < count
                let onlyPairWrap = (count == 2)

                let prevIdx: Int? = hasPrev ? idx - 1 : (onlyPairWrap ? (idx + 1) % count : nil)
                let nextIdx: Int? = hasNext ? idx + 1 : (onlyPairWrap ? (idx + count - 1) % count : nil)

                // Compute gaps (positive means space to fill). Use configured padding between windows
                var leftGap: CGFloat = 0
                var rightGap: CGFloat = 0
                if let p = prevIdx, let pb = currentBoundsByID[ordered[p]] {
                    leftGap = max(0, cur.minX - pb.maxX - windowPadding)
                }
                if let n = nextIdx, let nb = currentBoundsByID[ordered[n]] {
                    rightGap = max(0, nb.minX - cur.maxX - windowPadding)
                }

                // Choose neighbor with larger gap; if equal and pair, pick the other window
                var chooseNext = false
                if onlyPairWrap {
                    // Always adjust the other window in a pair
                    chooseNext = (nextIdx != nil && ordered[nextIdx!] != wid)
                } else {
                    chooseNext = rightGap >= leftGap
                }

                if chooseNext, let n = nextIdx, let nb = currentBoundsByID[ordered[n]] {
                    let gap = max(rightGap, 0)
                    if gap > sizeTolerance {
                        // Expand next window into the gap: move its X left by gap and increase width by gap
                        let newOrigin = CGPoint(x: nb.minX - gap, y: nb.minY)
                        let newSize = CGSize(width: nb.width + gap, height: nb.height)
                        applyWindowBounds(windowID: ordered[n], bounds: CGRect(origin: newOrigin, size: newSize), windowName: "Rebalanced Next")
                        lastAdjustedWindows[ordered[n]] = now
                        // Update current bounds snapshot for subsequent calculations
                        currentBoundsByID[ordered[n]] = CGRect(origin: newOrigin, size: newSize)
                    }
                } else if let p = prevIdx, let pb = currentBoundsByID[ordered[p]] {
                    let gap = max(leftGap, 0)
                    if gap > sizeTolerance {
                        // Expand previous window to the right by the gap (keep origin)
                        let newOrigin = CGPoint(x: pb.minX, y: pb.minY)
                        let newSize = CGSize(width: pb.width + gap, height: pb.height)
                        applyWindowBounds(windowID: ordered[p], bounds: CGRect(origin: newOrigin, size: newSize), windowName: "Rebalanced Prev")
                        lastAdjustedWindows[ordered[p]] = now
                        currentBoundsByID[ordered[p]] = CGRect(origin: newOrigin, size: newSize)
                    }
                }
            }

            // Store previous bounds for next frame comparison
            for wid in ordered {
                if let cur = currentBoundsByID[wid] {
                    previousWindowBounds[wid] = cur
                }
            }

            logger.debug("Rebalanced split group \(groupIndex) with \(ordered.count) window(s)", category: .windowTiling)
        }
    }
    
    /// Configure window padding (distance from screen edges)
    func setWindowPadding(_ padding: CGFloat) {
        let oldPadding = windowPadding
        windowPadding = padding
        logger.info("🔧 Window padding updated from \(oldPadding)px to \(padding)px", category: .windowTiling)
    }
    
    /// Get current window padding value
    func getWindowPadding() -> CGFloat {
        return windowPadding
    }
    
    /// Handle focus change to synchronize split windows
    func handleWindowFocusChanged(focusedWindowID: CGWindowID?) {
        guard let focusedWindowID = focusedWindowID else {
            // Focus left our known windows; clear active group
            activeSplitGroupIndex = nil
            hasBroughtActiveGroupToFront = false
            return
        }
        
        // Determine if focused window is in a split group
        if let groupIndex = windowToSplitGroup[focusedWindowID], groupIndex < splitGroups.count {
            // Entering or inside a split group
            if activeSplitGroupIndex != groupIndex {
                // New active split group
                activeSplitGroupIndex = groupIndex
                hasBroughtActiveGroupToFront = false
            }
            
            // Bring all in group to front only once per entry into the group
            if hasBroughtActiveGroupToFront == false {
                let group = splitGroups[groupIndex]
                logger.info("🔄 Focus sync (once): bringing \(group.count) split window(s) to front", category: .windowTiling)
                // After bringing partners forward, restore focus to the originally focused window
                bringWindowsToFront(windowIDs: Array(group), returnFocusTo: focusedWindowID)
                hasBroughtActiveGroupToFront = true
            }
            
            // Otherwise, already brought to front; do nothing
            return
        } else {
            // Focused window not in current active split group; clear state
            if activeSplitGroupIndex != nil {
                logger.debug("🧹 Leaving split group focus state", category: .windowTiling)
            }
            activeSplitGroupIndex = nil
            hasBroughtActiveGroupToFront = false
            return
        }
    }
    
    /// Execute vertical split layout for multiple windows
    func executeVerticalSplit(windows: [WindowInfo]) {
        guard !windows.isEmpty else {
            logger.warning("Cannot execute vertical split - no windows provided", category: .windowTiling)
            return
        }
        
        logger.info("🔀 Executing vertical split layout for \(windows.count) windows", category: .windowTiling)
        
        // Calculate split bounds for each window
        guard let splitBounds = calculateVerticalSplitBounds(windowCount: windows.count) else {
            logger.warning("Cannot calculate split bounds", category: .windowTiling)
            return
        }
        
        // Create split group and track windows
        let windowIDs = Set(windows.map { $0.id })
        let groupIndex = splitGroups.count
        splitGroups.append(windowIDs)
        
        // Map each window to its split group
        for windowID in windowIDs {
            windowToSplitGroup[windowID] = groupIndex
        }
        
        logger.info("📝 Created split group \(groupIndex) with \(windowIDs.count) windows", category: .windowTiling)
        
        // Apply the split layout to each window
        for (index, window) in windows.enumerated() {
            let bounds = splitBounds[index]
            logger.info("🔀 Positioning window \(window.displayName) at split \(index + 1): \(bounds)", category: .windowTiling)
            
            applyWindowBounds(windowID: window.id, bounds: bounds, windowName: window.displayName)
        }
        
        // Bring all split windows to the front with a small delay to avoid conflicts
        // Preserve current focused window by restoring focus at the end
        let currentFocused = nativeBridge?.getFocusedWindowID()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.bringWindowsToFront(windowIDs: Array(windowIDs), returnFocusTo: currentFocused)
        }
        
        logger.info("✅ Vertical split layout completed for \(windows.count) windows", category: .windowTiling)
    }

    /// Remove a window from its current split group. If the group would have only one window left
    /// and dissolveIfPair is true, dissolve the entire group (removing the last remaining member as well).
    @discardableResult
    func removeWindowFromSplit(windowID: CGWindowID, dissolveIfPair: Bool = true) -> Bool {
        guard let groupIndex = windowToSplitGroup[windowID], groupIndex < splitGroups.count else {
            logger.debug("removeWindowFromSplit: window not in any split group: \(windowID)", category: .windowTiling)
            return false
        }

        var group = splitGroups[groupIndex]
        let originalCount = group.count
        group.remove(windowID)
        windowToSplitGroup.removeValue(forKey: windowID)

        if dissolveIfPair && group.count <= 1 {
            // Dissolve the entire group
            logger.info("🧨 Dissolving split group \(groupIndex) after removing window \(windowID)", category: .windowTiling)
            // Remove mapping for the last remaining member too
            for remaining in group { windowToSplitGroup.removeValue(forKey: remaining) }
            splitGroups.remove(at: groupIndex)

            // Adjust active group index bookkeeping
            if activeSplitGroupIndex == groupIndex {
                activeSplitGroupIndex = nil
                hasBroughtActiveGroupToFront = false
            } else if let active = activeSplitGroupIndex, groupIndex < active {
                activeSplitGroupIndex = active - 1
            }

            // Rebuild mapping for remaining groups
            windowToSplitGroup = [:]
            for (newIndex, ids) in splitGroups.enumerated() {
                for id in ids { windowToSplitGroup[id] = newIndex }
            }
            
            // Retile removed window and the last remaining window back to fullscreen
            retileWindowToFullscreen(windowID: windowID)
            if let lastRemaining = group.first {
                retileWindowToFullscreen(windowID: lastRemaining)
            }
            return true
        } else {
            // Update group with the removal
            splitGroups[groupIndex] = group
            logger.info("➖ Removed window \(windowID) from split group \(groupIndex) (now \(group.count)/\(originalCount))", category: .windowTiling)
            
            // Retile only the removed window back to fullscreen
            retileWindowToFullscreen(windowID: windowID)
            return true
        }
    }

    // Retile a window back to fullscreen area respecting taskbar/padding
    private func retileWindowToFullscreen(windowID: CGWindowID) {
        guard let targetBounds = calculateFullscreenBounds() else {
            logger.warning("Cannot retile window to fullscreen - no target bounds", category: .windowTiling)
            return
        }
        
        guard let bridge = nativeBridge else {
            logger.warning("NativeBridge not available for retile", category: .windowTiling)
            return
        }
        
        // Try to fetch window info for richer tiling (restriction handling)
        let all = bridge.getAllWindows(includeOffscreen: false)
        if let info = all.first(where: { $0.windowID == windowID }) {
            attemptFullscreenTiling(windowID: windowID, targetBounds: targetBounds, windowInfo: info)
            return
        }
        
        // Fallback: move/resize directly if window info not found
        logger.debug("Fallback retile (no info) for window \(windowID) to \(targetBounds)", category: .windowTiling)
        applyWindowBounds(windowID: windowID, bounds: targetBounds, windowName: "Window \(windowID)")
    }
    
    /// Prevent all windows from overlapping with the taskbar (safety net)
    func preventTaskbarOverlap() {
        guard let bridge = nativeBridge else {
            logger.warning("NativeBridge not available for taskbar overlap prevention", category: .windowTiling)
            return
        }
        
        // Check for accessibility permission
        if !bridge.checkAccessibilityPermission() {
            logger.debug("Skipping overlap prevention - no accessibility permission", category: .windowTiling)
            return
        }
        
        // Check if Mission Control is active by counting Dock windows
        if bridge.maybeMissionControlIsActive() {
            logger.debug("Skipping overlap prevention - Mission Control is active", category: .windowTiling)
            return
        }
        
        // Get all visible windows from bridge
        let allWindows = bridge.getVisibleApplicationWindows()
        
        logger.debug("Checking \(allWindows.count) windows for taskbar overlap", category: .windowTiling)
        
        // Get current taskbar bounds
        guard let screen = NSScreen.main else {
            logger.warning("Cannot get main screen for taskbar overlap prevention", category: .windowTiling)
            return
        }
        
        let screenFrame = screen.visibleFrame
        let taskbarY = screenFrame.maxY - 5  // Same calculation as elsewhere
        let taskbarTop = taskbarY + taskbarHeight
        
        for window in allWindows {
            // Skip system windows using same logic
            if shouldSkipWindow(window.owner, window.bounds) {
                continue
            }
            
            // Check if window overlaps with taskbar
            let windowBottom = window.bounds.minY
            let windowTop = window.bounds.maxY
            
                            logger.debug("Window \(window.owner): Y=\(window.bounds.minY), H=\(window.bounds.height), Bottom=\(windowBottom), Top=\(windowTop), TaskbarY=\(taskbarY), TaskbarTop=\(taskbarTop)", category: .windowTiling)
            
            // Check if window overlaps with taskbar area
            if windowBottom < taskbarTop && windowTop > taskbarY {
                logger.info("Window \(window.owner) overlaps taskbar - adjusting position", category: .windowTiling)
                
                // Calculate new height to avoid taskbar overlap
                let newHeight = taskbarY - window.bounds.minY - windowPadding
                let minHeight: CGFloat = 200
                let finalHeight = max(newHeight, minHeight)
                
                // Resize window using bridge
                let newSize = CGSize(width: window.bounds.width, height: finalHeight)
                let result = bridge.resizeWindow(windowID: window.windowID, to: newSize)
                
                switch result {
                case .success:
                                            logger.info("Successfully resized window \(window.owner) to avoid taskbar overlap", category: .windowTiling)
                case .failed(let error):
                                            logger.warning("Failed to resize window \(window.owner): \(error)", category: .windowTiling)
                    // Try to record size restriction if resize failed
                    recordSizeRestriction(
                        windowID: window.windowID,
                        maxSize: window.bounds.size,
                        minSize: window.bounds.size,
                        windowInfo: window
                    )
                case .permissionDenied:
                                            logger.warning("Permission denied for resizing window \(window.owner)", category: .windowTiling)
                case .windowNotFound:
                                            logger.warning("Window not found for resizing: \(window.owner)", category: .windowTiling)
                }
            }
        }
    }
    
    // MARK: - Private Implementation
    
    private func shouldSkipWindow(_ owner: String, _ bounds: CGRect) -> Bool {
        // Skip system apps and our own app
        let systemApps = ["Bar", "Dock", "SystemUIServer", "ControlCenter", "NotificationCenter"]
        if systemApps.contains(owner) {
            return true
        }
        
        // Skip tiny windows (likely dialogs or utility windows)
        if bounds.width < 100 || bounds.height < 100 {
            return true
        }
        
        return false
    }
    
    private func calculateVerticalSplitBounds(windowCount: Int) -> [CGRect]? {
        guard windowCount > 0 else { return nil }
        
        guard let screen = NSScreen.main else {
            logger.warning("Cannot get main screen for split bounds calculation", category: .windowTiling)
            return nil
        }
        
        // Use same screen calculation as fullscreen
        let fullScreenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = fullScreenFrame.maxY - visibleFrame.maxY
        let taskbarY = fullScreenFrame.maxY - 5
        
        // Calculate available area
        let availableTop = fullScreenFrame.minY + menuBarHeight + windowPadding
        let availableBottom = taskbarY - taskbarHeight - windowPadding
        let availableHeight = availableBottom - availableTop
        let availableWidth = fullScreenFrame.width - (windowPadding * 2)
        
        // Calculate width per window (including padding between windows)
        let totalPaddingBetweenWindows = CGFloat(windowCount - 1) * windowPadding
        let widthPerWindow = (availableWidth - totalPaddingBetweenWindows) / CGFloat(windowCount)
        
        var splitBounds: [CGRect] = []
        
        for i in 0..<windowCount {
            let xOffset = fullScreenFrame.minX + windowPadding + (CGFloat(i) * (widthPerWindow + windowPadding))
            
            let bounds = CGRect(
                x: xOffset,
                y: availableTop,
                width: widthPerWindow,
                height: availableHeight
            )
            
            splitBounds.append(bounds)
        }
        
        logger.debug("Calculated \(windowCount) vertical split bounds with \(windowPadding)px padding", category: .windowTiling)
        logger.debug("Width per window: \(widthPerWindow), total height: \(availableHeight)", category: .windowTiling)
        
        return splitBounds
    }
    
    private func bringWindowsToFront(windowIDs: [CGWindowID], returnFocusTo: CGWindowID? = nil) {
        guard let bridge = nativeBridge else {
            logger.warning("NativeBridge not available for bringing windows to front", category: .windowTiling)
            return
        }
        
        for windowID in windowIDs {
            let activateResult = bridge.activateWindow(windowID: windowID)
            switch activateResult {
            case .success:
                logger.debug("✅ Brought window \(windowID) to front", category: .windowTiling)
            case .failed(let error):
                logger.warning("⚠️ Failed to bring window \(windowID) to front: \(error)", category: .windowTiling)
            case .permissionDenied:
                logger.warning("⚠️ Permission denied for bringing window \(windowID) to front", category: .windowTiling)
            case .windowNotFound:
                logger.warning("⚠️ Window \(windowID) not found for bringing to front", category: .windowTiling)
            }
        }

        // Ensure final focus returns to the intended original window
        if let originalID = returnFocusTo {
            let finalResult = bridge.activateWindow(windowID: originalID)
            switch finalResult {
            case .success:
                logger.debug("🎯 Restored focus to original window \(originalID)", category: .windowTiling)
            case .failed(let error):
                logger.warning("⚠️ Failed to restore focus to original window \(originalID): \(error)", category: .windowTiling)
            case .permissionDenied:
                logger.warning("⚠️ Permission denied restoring focus to window \(originalID)", category: .windowTiling)
            case .windowNotFound:
                logger.warning("⚠️ Original window not found when restoring focus: \(originalID)", category: .windowTiling)
            }
        }
    }
    
    private func applyWindowBounds(windowID: CGWindowID, bounds: CGRect, windowName: String) {
        guard let bridge = nativeBridge else {
            logger.warning("NativeBridge not available for applying window bounds", category: .windowTiling)
            return
        }
        
        // First move the window to position
        let moveResult = bridge.moveWindow(windowID: windowID, to: bounds.origin)
        switch moveResult {
        case .success:
            logger.debug("✅ Moved window \(windowName) to position \(bounds.origin)", category: .windowTiling)
        case .failed(let error):
            logger.warning("⚠️ Failed to move window \(windowName): \(error)", category: .windowTiling)
            return
        case .permissionDenied:
            logger.warning("⚠️ Permission denied for moving window \(windowName)", category: .windowTiling)
            return
        case .windowNotFound:
            logger.warning("⚠️ Window not found for moving: \(windowName)", category: .windowTiling)
            return
        }
        
        // Then resize the window
        let resizeResult = bridge.resizeWindow(windowID: windowID, to: bounds.size)
        switch resizeResult {
        case .success:
            logger.debug("✅ Resized window \(windowName) to size \(bounds.size)", category: .windowTiling)
        case .failed(let error):
            logger.warning("⚠️ Failed to resize window \(windowName): \(error)", category: .windowTiling)
        case .permissionDenied:
            logger.warning("⚠️ Permission denied for resizing window \(windowName)", category: .windowTiling)
        case .windowNotFound:
            logger.warning("⚠️ Window not found for resizing: \(windowName)", category: .windowTiling)
        }
    }
    
    private func calculateFullscreenBounds() -> CGRect? {
        guard let screen = NSScreen.main else {
            logger.warning("Cannot get main screen for fullscreen bounds calculation", category: .windowTiling)
            return nil
        }
        
        // Use full screen frame and manually calculate menu bar height
        let fullScreenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        
        // Calculate menu bar height (difference between full frame and visible frame top)
        let menuBarHeight = fullScreenFrame.maxY - visibleFrame.maxY
        logger.debug("Menu bar height: \(menuBarHeight)", category: .windowTiling)
        
        // Calculate available space, accounting for menu bar at top, taskbar at bottom, and padding
        let taskbarY = fullScreenFrame.maxY - 5  // Same as in WindowManager
        logger.debug("Taskbar Y: \(taskbarY)", category: .windowTiling)
        
        // Start from the bottom of the menu bar, not the top of the screen
        let availableTop = fullScreenFrame.minY + menuBarHeight + windowPadding
        let availableBottom = taskbarY - taskbarHeight - windowPadding
        let availableHeight = availableBottom - availableTop
        let availableWidth = fullScreenFrame.width - (windowPadding * 2)
        logger.debug("Available height: \(availableHeight)", category: .windowTiling)
        logger.debug("Available width: \(availableWidth)", category: .windowTiling)
        logger.debug("Available top: \(availableTop)", category: .windowTiling)
        logger.debug("Available bottom: \(availableBottom)", category: .windowTiling)
        
        let targetBounds = CGRect(
            x: fullScreenFrame.minX + windowPadding,  // Left padding
            y: availableTop,  // Below menu bar + top padding
            width: availableWidth,
            height: availableHeight
        )
        
        logger.debug("Calculated fullscreen bounds: \(targetBounds) with \(windowPadding)px padding", category: .windowTiling)
        logger.debug("Full screen: \(fullScreenFrame), visible: \(visibleFrame), menu bar height: \(menuBarHeight)", category: .windowTiling)
        logger.debug("Available area: top=\(availableTop), bottom=\(availableBottom), taskbar Y: \(taskbarY)", category: .windowTiling)
        
        return targetBounds
    }
    
    private func attemptFullscreenTiling(windowID: CGWindowID, targetBounds: CGRect, windowInfo: NativeDesktopBridge.NativeWindowInfo) {
        guard let bridge = nativeBridge else {
            logger.warning("NativeBridge not available for window tiling", category: .windowTiling)
            return
        }
        
        // First, try to move the window to the target position
        let moveResult = bridge.moveWindow(windowID: windowID, to: targetBounds.origin)
        
        switch moveResult {
        case .success:
                            logger.info("✅ Successfully moved window \(windowInfo.owner) to position \(targetBounds.origin)", category: .windowTiling)
        case .failed(let error):
                            logger.warning("⚠️ Failed to move window \(windowInfo.owner): \(error)", category: .windowTiling)
        case .permissionDenied:
                            logger.warning("⚠️ Permission denied for moving window \(windowInfo.owner)", category: .windowTiling)
            return
        case .windowNotFound:
                            logger.warning("⚠️ Window not found for moving: \(windowInfo.owner)", category: .windowTiling)
            return
        }
        
        // Next, try to resize the window to the target size
        let resizeResult = bridge.resizeWindow(windowID: windowID, to: targetBounds.size)
        
        switch resizeResult {
        case .success:
                            logger.info("✅ Successfully resized window \(windowInfo.owner) to fullscreen size", category: .windowTiling)
            tiledWindows.insert(windowID)
            
            // Verify the actual size after resize attempt
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.verifyWindowSizeAfterTiling(windowID: windowID, targetSize: targetBounds.size, windowInfo: windowInfo)
            }
            
        case .failed(let error):
                            logger.warning("⚠️ Failed to resize window \(windowInfo.owner): \(error) - checking for size restrictions", category: .windowTiling)
            // Window might have size restrictions - investigate further
            investigateSizeRestrictions(windowID: windowID, targetSize: targetBounds.size, windowInfo: windowInfo)
            
        case .permissionDenied:
                            logger.warning("⚠️ Permission denied for resizing window \(windowInfo.owner)", category: .windowTiling)
            
        case .windowNotFound:
                            logger.warning("⚠️ Window not found for resizing: \(windowInfo.owner)", category: .windowTiling)
        }
    }
    
    private func verifyWindowSizeAfterTiling(windowID: CGWindowID, targetSize: CGSize, windowInfo: NativeDesktopBridge.NativeWindowInfo) {
        guard let bridge = nativeBridge,
              let actualBounds = bridge.getWindowBounds(windowID: windowID) else {
            logger.warning("Cannot verify window size after tiling", category: .windowTiling)
            return
        }
        
        let tolerance: CGFloat = 10.0
        let widthDiff = abs(actualBounds.size.width - targetSize.width)
        let heightDiff = abs(actualBounds.size.height - targetSize.height)
        
        if widthDiff > tolerance || heightDiff > tolerance {
            logger.info("🔍 Window \(windowInfo.owner) didn't reach target size - investigating restrictions", category: .windowTiling)
            logger.info("Target: \(targetSize), Actual: \(actualBounds.size), Diff: (\(widthDiff), \(heightDiff))", category: .windowTiling)
            
            // Window has size restrictions
            recordSizeRestriction(
                windowID: windowID,
                maxSize: actualBounds.size,
                minSize: actualBounds.size, // For now, assume min = max
                windowInfo: windowInfo
            )
        } else {
            logger.info("✅ Window \(windowInfo.owner) successfully tiled to fullscreen", category: .windowTiling)
        }
    }
    
    private func investigateSizeRestrictions(windowID: CGWindowID, targetSize: CGSize, windowInfo: NativeDesktopBridge.NativeWindowInfo) {
        guard let bridge = nativeBridge else { return }
        
        // Get current window bounds to understand its restrictions
        guard let currentBounds = bridge.getWindowBounds(windowID: windowID) else {
            logger.warning("Cannot get current bounds for size restriction investigation", category: .windowTiling)
            return
        }
        
        logger.info("🔍 Investigating size restrictions for \(windowInfo.owner)", category: .windowTiling)
        logger.info("Current size: \(currentBounds.size), Target size: \(targetSize)", category: .windowTiling)
        
        // Try a series of smaller sizes to find the maximum
        let testSizes = [
            CGSize(width: targetSize.width * 0.9, height: targetSize.height * 0.9),
            CGSize(width: targetSize.width * 0.8, height: targetSize.height * 0.8),
            CGSize(width: targetSize.width * 0.7, height: targetSize.height * 0.7),
            CGSize(width: currentBounds.size.width * 1.2, height: currentBounds.size.height * 1.2),
            CGSize(width: currentBounds.size.width * 1.1, height: currentBounds.size.height * 1.1)
        ]
        
        var maxAchievedSize = currentBounds.size
        
        for testSize in testSizes {
            let result = bridge.resizeWindow(windowID: windowID, to: testSize)
            
            if case .success = result {
                // Wait a bit and check actual size
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let actualBounds = bridge.getWindowBounds(windowID: windowID) {
                        if actualBounds.size.width > maxAchievedSize.width || actualBounds.size.height > maxAchievedSize.height {
                            maxAchievedSize = actualBounds.size
                        }
                    }
                }
            }
        }
        
        // Record the findings after testing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.recordSizeRestriction(
                windowID: windowID,
                maxSize: maxAchievedSize,
                minSize: currentBounds.size,
                windowInfo: windowInfo
            )
        }
    }
    
    private func recordSizeRestriction(windowID: CGWindowID, maxSize: CGSize, minSize: CGSize, windowInfo: NativeDesktopBridge.NativeWindowInfo) {
        let restriction = SizeRestriction(
            windowID: windowID,
            maxSize: maxSize,
            minSize: minSize,
            canResize: maxSize.width > minSize.width || maxSize.height > minSize.height,
            owner: windowInfo.owner,
            detectedAt: Date()
        )
        
        sizeRestrictedWindows[windowID] = restriction
        
        logger.info("📏 Recorded size restriction for \(windowInfo.owner):", category: .windowTiling)
        logger.info("  Max size: \(maxSize)", category: .windowTiling)
        logger.info("  Min size: \(minSize)", category: .windowTiling)
        logger.info("  Can resize: \(restriction.canResize)", category: .windowTiling)
        
        // For size-restricted windows, try to position them optimally within their constraints
        positionSizeRestrictedWindow(windowID: windowID, restriction: restriction)
    }
    
    private func positionSizeRestrictedWindow(windowID: CGWindowID, restriction: SizeRestriction) {
        guard let bridge = nativeBridge,
              let screenBounds = calculateFullscreenBounds() else { return }
        
        // Center the size-restricted window within the available screen space
        let centerX = screenBounds.midX - (restriction.maxSize.width / 2)
        let centerY = screenBounds.midY - (restriction.maxSize.height / 2)
        
        let optimalPosition = CGPoint(x: centerX, y: centerY)
        
        let moveResult = bridge.moveWindow(windowID: windowID, to: optimalPosition)
        
        switch moveResult {
        case .success:
                            logger.info("✅ Positioned size-restricted window \(restriction.owner) at center", category: .windowTiling)
        case .failed(let error):
                            logger.warning("⚠️ Failed to position size-restricted window \(restriction.owner): \(error)", category: .windowTiling)
        case .permissionDenied, .windowNotFound:
            break // Already logged
        }
    }
    
    // MARK: - Cleanup
    
    func removeWindowFromTracking(_ windowID: CGWindowID) {
        tiledWindows.remove(windowID)
        if sizeRestrictedWindows.removeValue(forKey: windowID) != nil {
            logger.debug("Removed size restriction tracking for window \(windowID)", category: .windowTiling)
        }
    }
    
    func clearOldRestrictions(olderThan interval: TimeInterval = 3600) { // 1 hour default
        let cutoff = Date().addingTimeInterval(-interval)
        let oldWindowIDs = sizeRestrictedWindows.compactMap { (windowID, restriction) in
            restriction.detectedAt < cutoff ? windowID : nil
        }
        
        for windowID in oldWindowIDs {
            sizeRestrictedWindows.removeValue(forKey: windowID)
        }
        
        if !oldWindowIDs.isEmpty {
            logger.info("Cleaned up \(oldWindowIDs.count) old size restriction records", category: .windowTiling)
        }
    }
    
    /// Remove windows from split groups when they're no longer available
    func cleanupSplitGroups(availableWindowIDs: Set<CGWindowID>) {
        var groupsToRemove: [Int] = []
        
        for (groupIndex, windowIDs) in splitGroups.enumerated() {
            let remainingWindows = windowIDs.intersection(availableWindowIDs)
            
            if remainingWindows.count < 2 {
                // If less than 2 windows remain, remove the split group
                groupsToRemove.append(groupIndex)
                for windowID in windowIDs {
                    windowToSplitGroup.removeValue(forKey: windowID)
                }
                logger.info("🗑️ Removed split group \(groupIndex) - insufficient windows remaining", category: .windowTiling)
            } else if remainingWindows.count < windowIDs.count {
                // Some windows were removed, update the group
                splitGroups[groupIndex] = remainingWindows
                logger.info("📝 Updated split group \(groupIndex) - removed \(windowIDs.count - remainingWindows.count) windows", category: .windowTiling)
            }
        }
        
        // Remove groups in reverse order to maintain indices
        for groupIndex in groupsToRemove.reversed() {
            splitGroups.remove(at: groupIndex)
            
            // If we removed the active group, clear focus state
            if activeSplitGroupIndex == groupIndex {
                activeSplitGroupIndex = nil
                hasBroughtActiveGroupToFront = false
            } else if let active = activeSplitGroupIndex, groupIndex < active {
                // Adjust active index if groups shifted down
                activeSplitGroupIndex = active - 1
            }
            
            // Update windowToSplitGroup mappings for remaining groups
            windowToSplitGroup = [:]
            for (newIndex, windowIDs) in splitGroups.enumerated() {
                for windowID in windowIDs {
                    windowToSplitGroup[windowID] = newIndex
                }
            }
        }
    }
}