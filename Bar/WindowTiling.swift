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
}