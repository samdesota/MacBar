# Firefox Favicon Resolution Proposal

## Overview

This proposal outlines the implementation of favicon resolution for Firefox windows in the Bar taskbar application. The feature will extract favicons from Firefox browser tabs and display them alongside window titles, providing better visual identification of browser windows.

## Current Architecture Analysis

### Existing Window Management Flow

1. **Window Discovery**: `NativeDesktopBridge` uses Core Graphics `CGWindowListCopyWindowInfo` to enumerate windows
2. **Window Information**: `NativeWindowInfo` struct contains basic window metadata (ID, name, owner, bounds, layer, space)
3. **Enhanced Metadata**: Additional information retrieved via Accessibility API:
   - Window titles via `getWindowTitle(windowID:)` using `kAXTitleAttribute`
   - App icons via `getAppIcon(for:)` from `NSWorkspace`
4. **Display**: `WindowInfo` struct used in SwiftUI with icon and display name

### Integration Points

- **Data Structure**: Extend `WindowInfo` to include favicon information
- **Retrieval Logic**: Add favicon resolution to `NativeDesktopBridge`
- **Caching**: Implement favicon caching system for performance
- **UI Updates**: Modify `WindowButton` to display favicons with loading states

## Technical Implementation

### 1. Data Structure Extensions

#### Enhanced WindowInfo Structure
```swift
struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let name: String
    let owner: String
    let icon: NSImage?
    let favicon: FaviconInfo?  // NEW: Browser-specific favicon
    let isActive: Bool
    let forceShowTitle: Bool
    let spaceID: UInt64
    
    // ... existing properties
}

struct FaviconInfo: Equatable {
    let image: NSImage?
    let state: FaviconState
    let url: URL?
    let lastUpdated: Date
}

enum FaviconState: Equatable {
    case loading
    case loaded(NSImage)
    case failed
    case notApplicable  // Non-browser windows
}
```

#### Extended NativeWindowInfo
```swift
extension NativeDesktopBridge.NativeWindowInfo {
    var pageURL: URL? // NEW: Extracted page URL for browser windows
    var isBrowserWindow: Bool { 
        ["Firefox", "Safari", "Google Chrome", "Microsoft Edge"].contains(owner)
    }
}
```

### 2. Browser URL Extraction via Accessibility API

#### Firefox-Specific Implementation
```swift
extension NativeDesktopBridge {
    
    /// Extract page URL from Firefox window using Accessibility API
    func getFirefoxPageURL(windowID: CGWindowID) -> URL? {
        guard hasAccessibilityPermission,
              let axWindow = getAXWindowElement(for: windowID) else { return nil }
        
        // Find AXWebArea element in window hierarchy
        if let webArea = findWebAreaElement(in: axWindow) {
            // Try kAXURLAttribute first (standard)
            if let url = getURLAttribute(from: webArea, attribute: kAXURLAttribute) {
                return url
            }
            // Fallback to kAXDocumentAttribute (Firefox-specific)
            if let url = getURLAttribute(from: webArea, attribute: kAXDocumentAttribute) {
                return url
            }
        }
        
        return nil
    }
    
    private func findWebAreaElement(in element: AXUIElement) -> AXUIElement? {
        // Recursive traversal to find AXWebArea role
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let childElements = children as? [AXUIElement] else {
            return nil
        }
        
        for child in childElements {
            // Check if this element has AXWebArea role
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success,
               let roleString = role as? String,
               roleString == kAXWebAreaRole as String {
                return child
            }
            
            // Recursively search children
            if let webArea = findWebAreaElement(in: child) {
                return webArea
            }
        }
        
        return nil
    }
    
    private func getURLAttribute(from element: AXUIElement, attribute: CFString) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        
        if let urlString = value as? String {
            return URL(string: urlString)
        } else if let url = value as? URL {
            return url
        }
        
        return nil
    }
}
```

### 3. Favicon Resolution System

#### FaviconResolver Class
```swift
class FaviconResolver: ObservableObject {
    private let logger = Logger.shared
    private let cache = FaviconCache()
    private let urlSession = URLSession.shared
    
    /// Resolve favicon for a given page URL
    func resolveFavicon(for pageURL: URL, completion: @escaping (FaviconResult?) -> Void) {
        // Check cache first
        if let cached = cache.getFavicon(for: pageURL.host ?? "") {
            if !cached.isExpired {
                completion(cached.result)
                return
            }
        }
        
        // Fetch HTML and parse favicon links
        urlSession.dataTask(with: pageURL) { [weak self] data, response, error in
            guard let self = self,
                  let data = data,
                  let html = String(data: data, encoding: .utf8) else {
                self?.fetchFallbackFavicon(for: pageURL, completion: completion)
                return
            }
            
            if let iconURL = self.parseIconHref(from: html, baseURL: pageURL) {
                self.fetchFavicon(from: iconURL) { result in
                    if let result = result {
                        self.cache.storeFavicon(result, for: pageURL.host ?? "")
                        completion(result)
                    } else {
                        self.fetchFallbackFavicon(for: pageURL, completion: completion)
                    }
                }
            } else {
                self.fetchFallbackFavicon(for: pageURL, completion: completion)
            }
        }.resume()
    }
    
    private func parseIconHref(from html: String, baseURL: URL) -> URL? {
        // Parse <link rel="icon">, <link rel="shortcut icon">, etc.
        // Prefer largest size available (32x32, 64x64)
        let patterns = [
            #"<link[^>]*rel=["\'](?:shortcut )?icon["\'][^>]*href=["\']([^"\']*)["\']"#,
            #"<link[^>]*href=["\']([^"\']*)["\'][^>]*rel=["\'](?:shortcut )?icon["\']"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
               let hrefRange = Range(match.range(at: 1), in: html) {
                let href = String(html[hrefRange])
                return URL(string: href, relativeTo: baseURL)?.absoluteURL
            }
        }
        
        return nil
    }
    
    private func fetchFallbackFavicon(for pageURL: URL, completion: @escaping (FaviconResult?) -> Void) {
        guard let host = pageURL.host else {
            completion(nil)
            return
        }
        
        let faviconURL = URL(string: "https://\(host)/favicon.ico")!
        fetchFavicon(from: faviconURL, completion: completion)
    }
    
    private func fetchFavicon(from url: URL, completion: @escaping (FaviconResult?) -> Void) {
        urlSession.dataTask(with: url) { data, response, error in
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let data = data,
                  let image = NSImage(data: data) else {
                completion(nil)
                return
            }
            
            completion(FaviconResult(url: url, image: image))
        }.resume()
    }
}

struct FaviconResult {
    let url: URL
    let image: NSImage
}
```

#### Favicon Caching System
```swift
class FaviconCache {
    private struct CachedFavicon {
        let result: FaviconResult?
        let timestamp: Date
        let expiration: TimeInterval = 3600 // 1 hour
        
        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > expiration
        }
    }
    
    private var cache: [String: CachedFavicon] = [:]
    private let queue = DispatchQueue(label: "favicon.cache", attributes: .concurrent)
    
    func getFavicon(for host: String) -> CachedFavicon? {
        return queue.sync { cache[host] }
    }
    
    func storeFavicon(_ result: FaviconResult?, for host: String) {
        queue.async(flags: .barrier) {
            self.cache[host] = CachedFavicon(result: result, timestamp: Date())
        }
    }
    
    func clearExpiredEntries() {
        queue.async(flags: .barrier) {
            self.cache = self.cache.filter { !$0.value.isExpired }
        }
    }
}
```

### 4. Integration with Window Management

#### Enhanced Window Discovery
```swift
extension NativeDesktopBridge {
    
    func getVisibleApplicationWindows() -> [NativeWindowInfo] {
        let windows = getAllWindows()
        return windows.compactMap { window in
            // Enhanced window info with page URL for browsers
            var enhancedWindow = window
            
            if window.isBrowserWindow && window.owner == "Firefox" {
                enhancedWindow.pageURL = getFirefoxPageURL(windowID: window.windowID)
            }
            
            return enhancedWindow
        }
    }
}
```

#### WindowManager Integration
```swift
extension WindowManager {
    private let faviconResolver = FaviconResolver()
    
    private func createWindowInfo(from nativeWindow: NativeDesktopBridge.NativeWindowInfo) -> WindowInfo {
        let appIcon = nativeBridge.getAppIcon(for: nativeWindow.owner)
        let betterWindowName = nativeBridge.getWindowTitle(windowID: nativeWindow.windowID) ?? nativeWindow.name
        
        // Initialize favicon info
        var faviconInfo: FaviconInfo?
        if nativeWindow.isBrowserWindow, let pageURL = nativeWindow.pageURL {
            faviconInfo = FaviconInfo(image: nil, state: .loading, url: pageURL, lastUpdated: Date())
            
            // Asynchronously resolve favicon
            faviconResolver.resolveFavicon(for: pageURL) { [weak self] result in
                DispatchQueue.main.async {
                    self?.updateWindowFavicon(windowID: nativeWindow.windowID, result: result)
                }
            }
        } else {
            faviconInfo = FaviconInfo(image: nil, state: .notApplicable, url: nil, lastUpdated: Date())
        }
        
        return WindowInfo(
            id: nativeWindow.windowID,
            name: betterWindowName.isEmpty ? nativeWindow.name : betterWindowName,
            owner: nativeWindow.owner,
            icon: appIcon,
            favicon: faviconInfo,
            isActive: isWindowActive(nativeWindow.windowID),
            spaceID: nativeWindow.spaceID
        )
    }
    
    private func updateWindowFavicon(windowID: CGWindowID, result: FaviconResult?) {
        // Update the favicon in the existing WindowInfo
        for spaceID in spaceWindows.keys {
            if let windowIndex = spaceWindows[spaceID]?.firstIndex(where: { $0.id == windowID }) {
                var updatedWindow = spaceWindows[spaceID]![windowIndex]
                
                let newState: FaviconState = result != nil ? .loaded(result!.image) : .failed
                updatedWindow = WindowInfo(
                    id: updatedWindow.id,
                    name: updatedWindow.name,
                    owner: updatedWindow.owner,
                    icon: updatedWindow.icon,
                    favicon: FaviconInfo(
                        image: result?.image,
                        state: newState,
                        url: updatedWindow.favicon?.url,
                        lastUpdated: Date()
                    ),
                    isActive: updatedWindow.isActive,
                    forceShowTitle: updatedWindow.forceShowTitle,
                    spaceID: updatedWindow.spaceID
                )
                
                spaceWindows[spaceID]![windowIndex] = updatedWindow
                break
            }
        }
    }
}
```

## User Experience Specifications

### 1. Visual States

#### Loading State
- **Display**: Animated spinner overlay on Firefox icon
- **Duration**: Show spinner while favicon is being resolved
- **Animation**: Subtle rotation animation using SwiftUI
- **Color**: Match system accent color

#### Loaded State
- **Display**: Favicon replaces or supplements Firefox icon
- **Size**: 16x16 or 20x20 pixels (consistent with app icons)
- **Fallback**: If favicon is too small/low quality, show alongside Firefox icon
- **Cache**: Persist for 1 hour to avoid repeated requests

#### Failed State
- **Display**: Standard Firefox icon (no change from current behavior)
- **Retry**: Attempt to refetch on next window focus or URL change
- **Logging**: Log failure for debugging purposes

### 2. WindowButton UI Updates

#### Enhanced WindowButton Implementation
```swift
struct WindowButton: View {
    let window: WindowInfo
    // ... existing properties
    
    var body: some View {
        HStack(spacing: 4) {
            // Enhanced icon display logic
            iconView
            
            // Window name
            Text(window.displayName)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // ... existing styling
    }
    
    @ViewBuilder
    private var iconView: some View {
        if keyboardSwitcher.isSwitchingMode, let assignedKey = getAssignedKey() {
            // Show assigned key (existing behavior)
            keyAssignmentView
        } else if window.owner == "Firefox" {
            firefoxIconView
        } else if let icon = window.icon {
            // Standard app icon
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
        } else {
            // Fallback icon
            Image(systemName: "app")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
        }
    }
    
    @ViewBuilder
    private var firefoxIconView: some View {
        ZStack {
            // Base Firefox icon
            if let firefoxIcon = window.icon {
                Image(nsImage: firefoxIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
            }
            
            // Favicon overlay/replacement
            switch window.favicon?.state {
            case .loading:
                // Loading spinner
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 8, height: 8)
                    .offset(x: 6, y: -6) // Top-right corner
            
            case .loaded(let faviconImage):
                // Show favicon in bottom-right corner
                Image(nsImage: faviconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 12, height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.primary.opacity(0.2), lineWidth: 0.5)
                    )
                    .offset(x: 6, y: 6) // Bottom-right corner
            
            case .failed, .notApplicable, .none:
                // Show only Firefox icon
                EmptyView()
            }
        }
    }
}
```

### 3. Performance Considerations

#### Optimization Strategies
1. **Lazy Loading**: Only resolve favicons for visible windows
2. **Request Throttling**: Limit concurrent favicon requests (max 3)
3. **Cache Management**: Periodic cleanup of expired cache entries
4. **Network Timeouts**: 5-second timeout for favicon requests
5. **Memory Management**: Compress favicon images if larger than 32x32

#### Resource Usage
- **Memory**: Estimated 50-100KB per cached favicon
- **Network**: Minimal impact with proper caching
- **CPU**: Negligible overhead with async processing

## Implementation Timeline

### Phase 1: Core Infrastructure (Week 1)
- [ ] Extend data structures (`WindowInfo`, `FaviconInfo`)
- [ ] Implement basic AX API URL extraction for Firefox
- [ ] Create `FaviconResolver` class with basic functionality
- [ ] Add favicon caching system

### Phase 2: Integration (Week 2)
- [ ] Integrate favicon resolution into `WindowManager`
- [ ] Update window discovery pipeline
- [ ] Implement loading states in UI
- [ ] Add error handling and fallback logic

### Phase 3: Polish & Optimization (Week 3)
- [ ] Implement UI animations and loading indicators
- [ ] Add performance optimizations
- [ ] Comprehensive testing with various websites
- [ ] Documentation and code cleanup

## Testing Strategy

### Test Cases
1. **Basic Functionality**
   - Firefox windows with standard favicons
   - Sites with multiple icon sizes
   - Sites with no favicon (fallback to /favicon.ico)

2. **Edge Cases**
   - Very slow-loading pages
   - Network timeouts
   - Invalid favicon URLs
   - Non-standard favicon formats

3. **Performance Testing**
   - Multiple Firefox windows simultaneously
   - Rapid window switching
   - Memory usage over extended periods
   - Cache effectiveness

4. **Accessibility**
   - Ensure AX API permissions work correctly
   - Graceful degradation without permissions
   - No impact on existing accessibility features

## Future Enhancements

### Multi-Browser Support
- Extend to Safari, Chrome, and Edge
- Browser-specific URL extraction methods
- Unified favicon resolution pipeline

### Advanced Features
- Favicon animation for loading pages
- Site-specific icon preferences
- Integration with bookmark favicons
- Favicon-based window grouping

### Performance Improvements
- Preemptive favicon caching
- Background refresh of expired favicons
- CDN-based favicon services integration

## Conclusion

This proposal provides a comprehensive approach to adding favicon resolution for Firefox windows in the Bar taskbar application. The implementation leverages macOS Accessibility APIs to extract page URLs and implements a robust caching system for optimal performance. The UX design ensures smooth loading states and appropriate fallbacks while maintaining the existing user experience for non-browser applications.

The modular design allows for future expansion to other browsers and provides a solid foundation for enhanced browser window identification in the taskbar.

