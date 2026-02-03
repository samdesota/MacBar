//
//  FirefoxFaviconReceiver.swift
//  Bar
//
//  Receives favicon updates from Firefox extension via native messaging host
//

import Foundation
import AppKit

/// Receives favicon updates from Firefox extension
class FirefoxFaviconReceiver: ObservableObject {
    @Published var firefoxWindows: [String: FirefoxWindowInfo] = [:] // Keyed by URL
    
    private let logger = Logger.shared
    private var notificationObserver: NSObjectProtocol?
    
    // Callback to notify when a favicon is updated
    var onFaviconUpdated: (() -> Void)?
    
    struct FirefoxWindowInfo {
        let windowId: Int
        let url: String
        let title: String
        let favIconUrl: String
        var favicon: NSImage?
        let lastUpdated: Date
    }
    
    init() {
        logger.info("🦊 FirefoxFaviconReceiver initialized", category: .general)
        
        // Delay observer setup until after main run loop is active
        DispatchQueue.main.async { [weak self] in
            self?.setupNotificationListener()
            self?.sendClearCacheCommand()
        }
    }
    
    deinit {
        if let observer = notificationObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
    
    // MARK: - Notification Listener
    
    private func setupNotificationListener() {
        let center = DistributedNotificationCenter.default()
        
        notificationObserver = center.addObserver(
            forName: Notification.Name("com.bar.faviconUpdate"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let userInfo = notification.userInfo,
                  let payloadString = userInfo["payload"] as? String,
                  let payloadData = payloadString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                return
            }
            
            self.handleFaviconUpdate(json)
        }
        
        logger.info("✅ Listening for Firefox favicon updates via DistributedNotificationCenter", category: .general)
    }
    
    // MARK: - Message Handling
    
    private func handleFaviconUpdate(_ message: [String: Any]) {
        guard let type = message["type"] as? String,
              type == "tabUpdate",
              let windowId = message["windowId"] as? Int,
              let url = message["url"] as? String,
              let title = message["title"] as? String,
              let favIconUrl = message["favIconUrl"] as? String else {
            logger.warning("Invalid favicon update message: \(message)", category: .general)
            return
        }
        
        logger.info("🦊 Firefox: \(title) - \(url)", category: .general)
        
        var windowInfo = FirefoxWindowInfo(
            windowId: windowId,
            url: url,
            title: title,
            favIconUrl: favIconUrl,
            favicon: nil,
            lastUpdated: Date()
        )
        
        // Load favicon image
        if let favicon = loadFavicon(from: favIconUrl) {
            windowInfo.favicon = favicon
            logger.info("✅ Loaded favicon for \(title)", category: .general)
        }
        
        // Store by URL for easy lookup
        firefoxWindows[url] = windowInfo
        
        // Trigger callback to update UI immediately
        logger.info("🔔 Triggering favicon update callback", category: .general)
        onFaviconUpdated?()
    }
    
    // MARK: - Favicon Loading
    
    private func loadFavicon(from urlString: String) -> NSImage? {
        // Handle data URLs
        if urlString.hasPrefix("data:image/") {
            return loadDataURLImage(urlString)
        }
        
        // Handle HTTP(S) URLs
        guard let url = URL(string: urlString) else { return nil }
        
        // Synchronous load for now (consider async with caching)
        if let data = try? Data(contentsOf: url),
           let image = NSImage(data: data) {
            return image
        }
        
        return nil
    }
    
    private func loadDataURLImage(_ dataURL: String) -> NSImage? {
        // Format: data:image/png;base64,iVBORw0KG...
        guard let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        
        let base64String = String(dataURL[dataURL.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else { return nil }
        
        return NSImage(data: data)
    }
    
    // MARK: - Public API
    
    /// Get favicon by matching window title
    func getFavicon(forWindowTitle windowTitle: String) -> NSImage? {
        // Try exact URL match first
        if let windowInfo = firefoxWindows[windowTitle] {
            return windowInfo.favicon
        }
        
        // Try fuzzy matching: check if any stored title/URL matches the window title
        for (_, windowInfo) in firefoxWindows {
            logger.debug("🔍 Checking window title: '\(windowTitle)' against '\(windowInfo.title)'", category: .general)
            // Check if window title contains the page title
            if windowTitle.contains(windowInfo.title) && !windowInfo.title.isEmpty {
                logger.debug("🎯 Matched by title: '\(windowTitle)' contains '\(windowInfo.title)'", category: .general)
                return windowInfo.favicon
            }
            
            // Check if window title contains the domain
            if let domain = extractDomain(from: windowInfo.url),
               windowTitle.lowercased().contains(domain.lowercased()) {
                logger.debug("🎯 Matched by domain: '\(windowTitle)' contains '\(domain)'", category: .general)
                return windowInfo.favicon
            }
        }
        
        logger.debug("❌ No favicon match for window title: '\(windowTitle)'", category: .general)
        return nil
    }
    
    /// Extract domain from URL (e.g., "https://www.reddit.com/path" -> "reddit.com")
    private func extractDomain(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host else {
            return nil
        }
        
        // Remove "www." prefix if present
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        
        return host
    }
    
    func getAllWindows() -> [FirefoxWindowInfo] {
        return Array(firefoxWindows.values).sorted { $0.windowId < $1.windowId }
    }
    
    // MARK: - Cache Management
    
    /// Send clearCache command to native host (which forwards to extension)
    private func sendClearCacheCommand() {
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            Notification.Name("com.bar.clearFaviconCache"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        logger.info("📤 Sent clearCache command to native host", category: .general)
    }
}
