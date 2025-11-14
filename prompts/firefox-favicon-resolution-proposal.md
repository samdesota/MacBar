# Firefox Favicon Resolution - Implementation Proposal

## Overview

Add favicon resolution for Firefox windows to replace the generic Firefox icon with site-specific favicons. This will make it easier to identify different web pages in the taskbar when using Firefox in "one window per tab" mode.

## Current Architecture

### Window Information Flow
```
NativeDesktopBridge → WindowManager → WindowInfo → ContentView (WindowButton)
     ↓
  getAppIcon() returns generic Firefox icon for all Firefox windows
```

### Key Components
- **WindowInfo**: Struct containing window metadata including `icon: NSImage?`
- **WindowManager**: Manages window list and updates
- **NativeDesktopBridge**: Low-level window detection via Accessibility APIs
- **WindowButton**: UI component that displays window icon and name

## Proposed Solution

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     WindowManager                            │
│  - Detects Firefox windows                                  │
│  - Extracts URL from window title                           │
│  - Requests favicon from FaviconManager                     │
└──────────────────┬──────────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────────┐
│                    FaviconManager                            │
│  - Checks cache for favicon                                 │
│  - Fetches favicon if not cached                            │
│  - Maintains in-memory and disk cache                       │
└──────────────────┬──────────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────────┐
│                   FaviconFetcher                             │
│  - Tries multiple favicon resolution strategies:            │
│    1. /favicon.ico                                          │
│    2. HTML <link rel="icon">                                │
│    3. Apple touch icon                                      │
│    4. Google favicon service (fallback)                     │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Components

### 1. Firefox Window Detection & URL Extraction

**Location**: Extension to `WindowManager.swift`

Firefox windows typically have titles in format:
- "Page Title - Mozilla Firefox"
- For URLs, Firefox sometimes shows the domain in the title

**Approach**:
- Use Accessibility API to get the URL from Firefox's address bar
- Fallback to parsing window title
- Use Firefox's native APIs if available

```swift
extension WindowManager {
    /// Detect if window belongs to Firefox
    func isFirefoxWindow(_ windowInfo: WindowInfo) -> Bool {
        return windowInfo.owner == "Firefox" || 
               windowInfo.owner == "Firefox Nightly" ||
               windowInfo.owner == "Firefox Developer Edition"
    }
    
    /// Extract URL from Firefox window
    func getFirefoxURL(for windowID: CGWindowID) -> URL? {
        // Try 1: Accessibility API to read address bar
        if let url = getURLFromAccessibilityAPI(windowID) {
            return url
        }
        
        // Try 2: Parse from window title (less reliable)
        if let url = getURLFromWindowTitle(windowID) {
            return url
        }
        
        return nil
    }
}
```

### 2. FaviconManager - Central Favicon Service

**New File**: `Bar/FaviconManager.swift`

Singleton service that manages favicon fetching and caching.

```swift
@MainActor
class FaviconManager: ObservableObject {
    static let shared = FaviconManager()
    
    // In-memory cache: URL -> NSImage
    private var memoryCache: [URL: NSImage] = [:]
    
    // Disk cache directory
    private let cacheDirectory: URL
    
    // Network fetch queue
    private let fetchQueue = DispatchQueue(label: "favicon.fetch", qos: .userInitiated)
    
    // Pending fetch requests (avoid duplicate requests)
    private var pendingFetches: Set<URL> = []
    
    /// Get favicon for URL (returns cached or initiates fetch)
    func getFavicon(for url: URL, completion: @escaping (NSImage?) -> Void) {
        // 1. Check memory cache
        if let cachedIcon = memoryCache[url] {
            completion(cachedIcon)
            return
        }
        
        // 2. Check disk cache
        if let diskIcon = loadFromDiskCache(url) {
            memoryCache[url] = diskIcon
            completion(diskIcon)
            return
        }
        
        // 3. Fetch from network
        fetchFavicon(for: url, completion: completion)
    }
    
    /// Prefetch favicon in background (for performance)
    func prefetchFavicon(for url: URL) {
        guard !memoryCache.keys.contains(url) && !pendingFetches.contains(url) else {
            return
        }
        
        fetchFavicon(for: url) { _ in }
    }
}
```

### 3. FaviconFetcher - Network Layer

**New File**: `Bar/FaviconFetcher.swift`

Handles actual favicon fetching with multiple strategies.

```swift
class FaviconFetcher {
    enum FaviconSource {
        case standardFavicon  // /favicon.ico
        case htmlLink         // <link rel="icon">
        case appleTouchIcon   // <link rel="apple-touch-icon">
        case googleService    // https://www.google.com/s2/favicons?domain=
    }
    
    /// Fetch favicon trying multiple methods
    static func fetchFavicon(for url: URL) async -> NSImage? {
        // Try methods in order of reliability
        if let icon = await tryStandardFavicon(url) { return icon }
        if let icon = await tryHTMLParsing(url) { return icon }
        if let icon = await tryGoogleFaviconService(url) { return icon }
        
        return nil
    }
    
    private static func tryStandardFavicon(_ url: URL) async -> NSImage? {
        guard let baseURL = url.baseURL else { return nil }
        let faviconURL = baseURL.appendingPathComponent("favicon.ico")
        return await downloadImage(from: faviconURL)
    }
    
    private static func tryGoogleFaviconService(_ url: URL) async -> NSImage? {
        guard let domain = url.host else { return nil }
        let serviceURL = URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=32")!
        return await downloadImage(from: serviceURL)
    }
}
```

### 4. Cache Management

**Disk Cache Structure**:
```
~/Library/Caches/com.bar.app/favicons/
  ├── domain.com.png
  ├── github.com.png
  └── stackoverflow.com.png
```

**Cache Strategy**:
- **Memory Cache**: LRU cache with max 100 favicons
- **Disk Cache**: Persistent, max 500MB
- **Expiration**: 7 days for disk cache
- **Cache Key**: Use domain name as key (not full URL)

```swift
extension FaviconManager {
    /// Save to disk cache
    private func saveToDiskCache(_ image: NSImage, for url: URL) {
        guard let domain = url.host else { return }
        let cacheURL = cacheDirectory.appendingPathComponent("\(domain).png")
        
        if let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: cacheURL)
        }
    }
    
    /// Load from disk cache
    private func loadFromDiskCache(_ url: URL) -> NSImage? {
        guard let domain = url.host else { return nil }
        let cacheURL = cacheDirectory.appendingPathComponent("\(domain).png")
        
        // Check if file exists and is not expired
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let modificationDate = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modificationDate) < 7 * 24 * 60 * 60 else {
            return nil
        }
        
        return NSImage(contentsOf: cacheURL)
    }
    
    /// Clean expired cache entries
    func cleanExpiredCache() {
        // Run in background
        DispatchQueue.global(qos: .utility).async {
            // Remove files older than 7 days
        }
    }
}
```

### 5. Integration with WindowManager

**Modify**: `Bar/WindowManager.swift`

Update the window creation logic to fetch favicons for Firefox windows.

```swift
// In updateWindowList() method, after creating windowInfo:
if isFirefoxWindow(windowInfo) {
    // Get URL for Firefox window
    if let url = getFirefoxURL(for: nativeWindow.windowID) {
        // Request favicon (async)
        FaviconManager.shared.getFavicon(for: url) { [weak self] faviconImage in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                // Update the window info with the favicon
                self.updateWindowIcon(windowID: nativeWindow.windowID, icon: faviconImage)
            }
        }
    }
}
```

### 6. URL Extraction from Firefox

**Accessibility API Approach** (Most Reliable):

```swift
extension NativeDesktopBridge {
    /// Get URL from Firefox address bar using Accessibility API
    func getFirefoxURL(for windowID: CGWindowID) -> URL? {
        guard let app = getAppForWindow(windowID) else { return nil }
        
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        
        var windowElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowElement
        )
        
        guard result == .success else { return nil }
        
        // Navigate to address bar
        // Firefox's accessibility tree: Window -> Toolbar -> ComboBox (address bar)
        if let urlString = findAddressBarValue(windowElement as! AXUIElement) {
            return URL(string: urlString)
        }
        
        return nil
    }
    
    private func findAddressBarValue(_ windowElement: AXUIElement) -> String? {
        // Traverse accessibility tree to find the address bar
        // This requires reverse engineering Firefox's accessibility hierarchy
        // Can be done using Accessibility Inspector tool
        
        // Example path (may vary by Firefox version):
        // AXWindow -> AXToolbar -> AXComboBox[role="address-bar"]
        
        return nil // TODO: Implement traversal
    }
}
```

**Alternative: AppleScript Approach** (Requires Firefox Automation):

```swift
extension WindowManager {
    /// Get URL via AppleScript (if Firefox supports it)
    func getFirefoxURLViaAppleScript() -> URL? {
        let script = """
        tell application "Firefox"
            set currentURL to URL of active tab of front window
            return currentURL
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let output = scriptObject.executeAndReturnError(&error)
            if let urlString = output.stringValue {
                return URL(string: urlString)
            }
        }
        
        return nil
    }
}
```

## Implementation Phases

### Phase 1: Core Infrastructure (2-3 hours)
- [ ] Create `FaviconManager.swift` with basic memory cache
- [ ] Create `FaviconFetcher.swift` with standard favicon fetch
- [ ] Implement disk cache structure
- [ ] Add unit tests for caching logic

### Phase 2: Firefox Integration (2-3 hours)
- [ ] Implement Firefox window detection in `WindowManager`
- [ ] Add URL extraction via Accessibility API
- [ ] Research Firefox's accessibility tree structure
- [ ] Implement fallback URL extraction methods
- [ ] Add logging for debugging

### Phase 3: Favicon Fetching (2-3 hours)
- [ ] Implement multiple favicon fetch strategies
- [ ] Add HTML parsing for `<link rel="icon">`
- [ ] Add Google favicon service fallback
- [ ] Handle network errors gracefully
- [ ] Add timeout mechanisms (3 seconds max)

### Phase 4: UI Integration (1-2 hours)
- [ ] Update `WindowInfo` to support dynamic icon updates
- [ ] Modify `WindowButton` to react to icon changes
- [ ] Add loading state (show generic Firefox icon while fetching)
- [ ] Test with multiple Firefox windows

### Phase 5: Polish & Optimization (2-3 hours)
- [ ] Implement LRU cache eviction
- [ ] Add cache size management (max 500MB)
- [ ] Implement cache cleanup on startup
- [ ] Add user preferences for favicon resolution
- [ ] Performance testing with 50+ Firefox windows
- [ ] Memory profiling

## Technical Challenges & Solutions

### Challenge 1: Getting URL from Firefox Windows
**Problem**: Firefox doesn't expose URL in standard window properties.

**Solutions**:
1. **Accessibility API**: Navigate Firefox's accessibility tree to find address bar (most reliable)
2. **AppleScript**: Use Firefox's AppleScript support (requires Firefox automation)
3. **Title Parsing**: Extract domain from window title (least reliable, fallback only)

**Recommendation**: Start with Accessibility API, use Accessibility Inspector to map Firefox's tree structure.

### Challenge 2: Favicon Quality & Size
**Problem**: Favicons come in various sizes (16x16 to 512x512) and formats.

**Solutions**:
1. Request 32x32 size for taskbar display
2. Use `NSImage` scaling for consistent display
3. Cache at multiple resolutions if needed

### Challenge 3: Performance with Many Firefox Windows
**Problem**: Fetching favicons for 50+ windows could be slow.

**Solutions**:
1. **Batch Fetching**: Limit concurrent network requests (max 5)
2. **Prioritization**: Fetch visible windows first
3. **Background Prefetch**: Prefetch when window is created
4. **Debouncing**: Wait 500ms after window appears before fetching

```swift
// Implement request throttling
class FaviconManager {
    private let maxConcurrentFetches = 5
    private var activeFetches = 0
    private var fetchQueue: [FetchRequest] = []
    
    func enqueueFetch(_ request: FetchRequest) {
        if activeFetches < maxConcurrentFetches {
            executeFetch(request)
        } else {
            fetchQueue.append(request)
        }
    }
}
```

### Challenge 4: Cache Invalidation
**Problem**: When to refresh cached favicons?

**Solutions**:
1. **Time-based**: Expire after 7 days
2. **Version-based**: Store ETag/Last-Modified headers
3. **Manual**: User can force refresh (Cmd+R on window button)

### Challenge 5: Privacy & Network Requests
**Problem**: Fetching favicons makes network requests to third-party sites.

**Solutions**:
1. **User Consent**: Show permission dialog on first use
2. **Privacy Mode**: Option to disable favicon fetching
3. **Local Only**: Option to only use cached favicons
4. **DNS Leak Prevention**: Use Google favicon service to avoid direct requests

## Testing Strategy

### Unit Tests
```swift
class FaviconManagerTests: XCTestCase {
    func testMemoryCacheHit() {
        let manager = FaviconManager()
        let testURL = URL(string: "https://example.com")!
        let testImage = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!
        
        manager.saveToCacheSync(testImage, for: testURL)
        
        let expectation = expectation(description: "Cache hit")
        manager.getFavicon(for: testURL) { image in
            XCTAssertNotNil(image)
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 1.0)
    }
    
    func testDiskCachePersistence() { /* ... */ }
    func testCacheEviction() { /* ... */ }
    func testNetworkFetchWithTimeout() { /* ... */ }
}
```

### Integration Tests
1. Create Firefox windows for known sites (github.com, stackoverflow.com)
2. Verify favicons are fetched and displayed
3. Close and reopen app, verify favicons load from cache
4. Test with 50+ Firefox windows for performance

### Manual Testing Checklist
- [ ] Open 5 different websites in separate Firefox windows
- [ ] Verify each window shows correct favicon in taskbar
- [ ] Restart app, verify favicons load from cache
- [ ] Disconnect network, verify cached favicons still appear
- [ ] Test with malformed URLs
- [ ] Test with sites that have no favicon
- [ ] Test with HTTPS and HTTP sites
- [ ] Test with non-standard ports

## Configuration & Preferences

Add user preferences for favicon resolution:

```swift
// In UserDefaults or Settings
struct FaviconSettings {
    var enabled: Bool = true
    var useGoogleService: Bool = true
    var cacheMaxSizeMB: Int = 500
    var cacheExpirationDays: Int = 7
    var fetchTimeoutSeconds: Double = 3.0
    var maxConcurrentFetches: Int = 5
}
```

## Error Handling

### Graceful Degradation
1. **Network Failure**: Show generic Firefox icon
2. **Invalid URL**: Show generic Firefox icon
3. **Timeout**: Cancel after 3 seconds, show generic icon
4. **Invalid Image**: Validate image data before caching

### Logging
```swift
// Add to Logger categories
extension Logger.LogCategory {
    static let faviconFetching = LogCategory(rawValue: "FaviconFetching")
}

// Usage
logger.info("Fetching favicon for: \(url.absoluteString)", category: .faviconFetching)
logger.warning("Favicon fetch timeout for: \(url.absoluteString)", category: .faviconFetching)
logger.error("Failed to cache favicon: \(error)", category: .faviconFetching)
```

## Future Enhancements

1. **Other Browsers**: Extend to Chrome, Safari, Arc
2. **Favicon Animation**: Support animated favicons (GIF/APNG)
3. **High-DPI Support**: Fetch @2x favicons for Retina displays
4. **Favicon Update Detection**: Monitor for favicon changes
5. **User Custom Icons**: Allow users to override favicons
6. **Cloud Sync**: Sync favicon cache across devices

## Security Considerations

1. **URL Validation**: Sanitize URLs before fetching
2. **HTTPS Preference**: Prefer HTTPS for favicon fetching
3. **Domain Allowlist**: Option to only fetch from trusted domains
4. **Rate Limiting**: Prevent abuse of Google favicon service
5. **Content-Type Validation**: Verify image MIME types

## Performance Targets

- **Initial Load**: < 100ms to show cached favicon
- **Network Fetch**: < 3s timeout per favicon
- **Memory Usage**: < 50MB for favicon cache (100 favicons)
- **Disk Usage**: < 500MB total cache size
- **UI Responsiveness**: No blocking of main thread

## Summary

This proposal outlines a comprehensive approach to adding favicon resolution for Firefox windows. The solution is:

- **Modular**: Separate concerns (fetching, caching, UI)
- **Performant**: Aggressive caching, async fetching, throttling
- **Robust**: Multiple fallback strategies, error handling
- **User-Friendly**: Graceful degradation, user preferences
- **Maintainable**: Well-tested, documented, extensible

The most challenging part will be extracting URLs from Firefox windows via the Accessibility API, which will require some reverse engineering of Firefox's accessibility tree structure.

Estimated total implementation time: **10-15 hours** for full implementation and testing.

