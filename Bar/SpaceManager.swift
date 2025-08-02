//
//  SpaceManager.swift
//  Bar
//
//  Created by Samuel DeSota on 7/31/25.
//

import Foundation
import AppKit
import ApplicationServices

/// Manages spaces, space detection, and per-space window caching
class SpaceManager: ObservableObject {
    static let shared = SpaceManager()
    
    @Published var currentSpaceID: String = ""
    @Published var availableSpaces: [SpaceInfo] = []
    @Published var isFullScreenSpace: Bool = false
    
    // Callback for immediate space change notification
    var onSpaceChangeDetected: (() -> Void)?
    
    private let logger = Logger.shared
    private var spaceChangeObserver: NSObjectProtocol?
    private var workspaceNotificationObserver: NSObjectProtocol?
    
    // Per-space window cache
    private var spaceWindowCache: [String: [WindowInfo]] = [:]
    private var spaceCacheTimestamps: [String: Date] = [:]
    private let cacheTimeout: TimeInterval = 30.0 // 30 seconds
    
    // Space tracking with private APIs
    private var spaceCounter: Int = 0
    private var lastKnownSpaceID: String = ""
    private var connectionID: Int32 = 0
    private var allSpaces: [PrivateSpaceInfo] = []
    private var currentPrivateSpaceID: UInt64 = 0
    
    struct SpaceInfo {
        let id: String
        let name: String
        let isFullScreen: Bool
        let isVisible: Bool
    }
    
    init() {
        logger.info("🏠 SpaceManager initialized", category: .spaceManagement)
        
        // Initialize private API connection
        connectionID = SLSMainConnectionID()
        if connectionID == 0 {
            logger.warning("⚠️ Failed to get SLS Connection ID, falling back to heuristic space detection", category: .spaceManagement)
        } else {
            logger.info("🔗 SLS Connection ID: \(connectionID)", category: .spaceManagement)
        }
        
        // Initialize with current space
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        lastKnownSpaceID = "\(frontmostApp)_\(NSScreen.main?.hashValue ?? 0)"
        currentSpaceID = getCurrentSpaceID()
        
        setupSpaceObservers()
        
        // Initial space refresh with a small delay to ensure everything is set up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.refreshSpaces()
        }
    }
    
    deinit {
        removeSpaceObservers()
    }
    
    // MARK: - Space Detection
    
    private func setupSpaceObservers() {
        logger.info("🔍 Setting up space change observers", category: .spaceManagement)
        
        // Listen for workspace changes (spaces, full screen, etc.)
        workspaceNotificationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSpaceChange()
        }
        
        // Also listen for screen changes that might affect spaces
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        
        // Listen for app activation changes (this can indicate space changes)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppActivation),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        
        // Set up a timer to periodically check for space changes
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkForSpaceChanges()
        }
    }
    
    private func removeSpaceObservers() {
        if let observer = workspaceNotificationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceNotificationObserver = nil
        }
        
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleScreenChange() {
        logger.info("🖥️ Screen parameters changed", category: .spaceManagement)
        refreshSpaces()
    }
    
    @objc private func handleAppActivation() {
        logger.info("📱 App activation detected", category: .spaceManagement)
        checkForSpaceChanges()
    }
    
    private func handleSpaceChange() {
        logger.info("🔄 Space change detected - refreshing synchronously", category: .spaceManagement)
        
        // Notify immediately to pause all WindowManagers before refresh
        onSpaceChangeDetected?()
        
        // Refresh spaces synchronously to avoid race conditions
        refreshSpaces()
    }
    
    private func checkForSpaceChanges() {
        // Try to use private API first
        if connectionID != 0 {
            let newActiveSpaceID = SLSGetActiveSpace(connectionID)
            if newActiveSpaceID != 0 && newActiveSpaceID != currentPrivateSpaceID {
                logger.info("🔄 Space change detected (private API): \(currentPrivateSpaceID) -> \(newActiveSpaceID)", category: .spaceManagement)
                currentPrivateSpaceID = newActiveSpaceID
                
                // Notify immediately to pause all WindowManagers
                onSpaceChangeDetected?()
                
                refreshSpaces()
                return
            }
        }
        
        // Fallback to heuristic approach
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let currentAppKey = "\(frontmostApp)_\(NSScreen.main?.hashValue ?? 0)"
        
        if currentAppKey != lastKnownSpaceID {
            logger.info("🔄 Potential space change detected (heuristic): \(lastKnownSpaceID) -> \(currentAppKey)", category: .spaceManagement)
            lastKnownSpaceID = currentAppKey
            spaceCounter += 1
            
            // Notify immediately to pause all WindowManagers
            onSpaceChangeDetected?()
            
            refreshSpaces()
        }
    }
    
    func refreshSpaces() {
        logger.info("🔄 Refreshing space information", category: .spaceManagement)
        
        let newSpaces = getAvailableSpaces()
        let newCurrentSpace = getCurrentSpaceID()
        let newIsFullScreen = isCurrentSpaceFullScreen()
        
        // Update synchronously to avoid race conditions
        self.availableSpaces = newSpaces
        self.currentSpaceID = newCurrentSpace
        self.isFullScreenSpace = newIsFullScreen
        
        self.logger.info("📊 Space update - Current: \(newCurrentSpace), FullScreen: \(newIsFullScreen), Total: \(newSpaces.count)", category: .spaceManagement)
    }
    
    private func getAvailableSpaces() -> [SpaceInfo] {
        var spaces: [SpaceInfo] = []
        
        // Get all managed display spaces using private API
        guard let managedSpaces = SLSCopyManagedDisplaySpaces(connectionID) as? [[String: Any]] else {
            logger.error("Failed to get managed display spaces", category: .spaceManagement)
            return []
        }
        
        logger.info("📊 Found \(managedSpaces.count) managed display spaces", category: .spaceManagement)
        
        // Process each display's spaces
        for (displayIndex, displayData) in managedSpaces.enumerated() {
            guard let spacesData = displayData["Spaces"] as? [[String: Any]] else { continue }
            
            logger.info("🖥️ Display \(displayIndex) has \(spacesData.count) spaces", category: .spaceManagement)
            
            for (spaceIndex, spaceData) in spacesData.enumerated() {
                guard let privateSpaceInfo = PrivateSpaceInfo(from: spaceData) else { continue }
                
                let spaceInfo = SpaceInfo(
                    id: "space-\(privateSpaceInfo.spaceID)",
                    name: "Space \(spaceIndex + 1) (Display \(displayIndex + 1))",
                    isFullScreen: privateSpaceInfo.spaceType == .fullscreen,
                    isVisible: privateSpaceInfo.spaceID == currentPrivateSpaceID
                )
                
                spaces.append(spaceInfo)
                allSpaces.append(privateSpaceInfo)
                
                logger.info("📍 Space: \(spaceInfo.id) - Type: \(privateSpaceInfo.spaceType) - FullScreen: \(spaceInfo.isFullScreen)", category: .spaceManagement)
            }
        }
        
        return spaces
    }
    
    private func getCurrentSpaceID() -> String {
        // Try to get the active space using private API
        if connectionID != 0 {
            let activeSpaceID = SLSGetActiveSpace(connectionID)
            if activeSpaceID != 0 {
                currentPrivateSpaceID = activeSpaceID
                logger.info("🎯 Active space ID: \(activeSpaceID)", category: .spaceManagement)
                return "space-\(activeSpaceID)"
            }
        }
        
        // Fallback to heuristic approach
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let currentAppKey = "\(frontmostApp)_\(NSScreen.main?.hashValue ?? 0)"
        
        if currentAppKey != lastKnownSpaceID {
            lastKnownSpaceID = currentAppKey
            spaceCounter += 1
        }
        
        logger.info("🎯 Using heuristic space ID: space-\(spaceCounter)", category: .spaceManagement)
        return "space-\(spaceCounter)"
    }
    
    private func isCurrentSpaceFullScreen() -> Bool {
        // Check if current space is full screen using private API
        let spaceType = SLSSpaceGetType(connectionID, currentPrivateSpaceID)
        let isFullScreen = spaceType == SpaceType.fullscreen.rawValue
        
        logger.info("🖥️ Current space type: \(spaceType) (FullScreen: \(isFullScreen))", category: .spaceManagement)
        return isFullScreen
    }
    

    
    // MARK: - Window Caching
    
    func cacheWindows(_ windows: [WindowInfo], for spaceID: String) {
        spaceWindowCache[spaceID] = windows
        spaceCacheTimestamps[spaceID] = Date()
        
        logger.debug("💾 Cached \(windows.count) windows for space \(spaceID)", category: .spaceManagement)
    }
    
    func getCachedWindows(for spaceID: String) -> [WindowInfo]? {
        guard let timestamp = spaceCacheTimestamps[spaceID] else {
            return nil
        }
        
        // Check if cache is still valid
        if Date().timeIntervalSince(timestamp) > cacheTimeout {
            logger.debug("⏰ Cache expired for space \(spaceID)", category: .spaceManagement)
            spaceWindowCache.removeValue(forKey: spaceID)
            spaceCacheTimestamps.removeValue(forKey: spaceID)
            return nil
        }
        
        return spaceWindowCache[spaceID]
    }
    
    func clearCache(for spaceID: String? = nil) {
        if let spaceID = spaceID {
            spaceWindowCache.removeValue(forKey: spaceID)
            spaceCacheTimestamps.removeValue(forKey: spaceID)
            logger.debug("🗑️ Cleared cache for space \(spaceID)", category: .spaceManagement)
        } else {
            spaceWindowCache.removeAll()
            spaceCacheTimestamps.removeAll()
            logger.debug("🗑️ Cleared all space caches", category: .spaceManagement)
        }
    }
    
    // MARK: - Space Management
    
    func shouldShowTaskbarOnCurrentSpace() -> Bool {
        // Don't show taskbar on full screen spaces
        if isFullScreenSpace {
            logger.debug("🚫 Skipping taskbar on full screen space", category: .spaceManagement)
            return false
        }
        
        return true
    }
    
    func getSpaceName(for spaceID: String) -> String {
        return availableSpaces.first(where: { $0.id == spaceID })?.name ?? "Unknown Space"
    }
    
    func isSpaceFullScreen(_ spaceID: String) -> Bool {
        return availableSpaces.first(where: { $0.id == spaceID })?.isFullScreen ?? false
    }
    
    func isReady() -> Bool {
        return !availableSpaces.isEmpty && !currentSpaceID.isEmpty
    }
} 