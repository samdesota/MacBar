//
//  ContentView.swift
//  Bar
//
//  Created by Samuel DeSota on 7/31/25.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var windowManager: WindowManager
    @StateObject private var keyboardSwitcher = KeyboardSwitcher.shared
    let spaceID: String // Add space ID parameter
    
    init(spaceID: String = "unknown") {
        self.spaceID = spaceID
    }
    
    // Helper function to convert space ID string to UInt64
    private func spaceIDToUInt64(_ spaceIDString: String) -> UInt64 {
        // Remove "space-" prefix and convert to UInt64
        let numericPart = spaceIDString.replacingOccurrences(of: "space-", with: "")
        return UInt64(numericPart) ?? 0
    }
    
    var body: some View {
        TaskbarView(windowManager: windowManager, keyboardSwitcher: keyboardSwitcher, spaceID: spaceID)
            .onAppear {
                // Connect KeyboardSwitcher to WindowManager
                keyboardSwitcher.connectWindowManager(windowManager)
            }
    }
}

struct TaskbarView: View {
    @ObservedObject var windowManager: WindowManager
    @ObservedObject var keyboardSwitcher: KeyboardSwitcher
    @StateObject private var logger = Logger.shared
    @State private var showLogControls = false
    @State private var showSettings = false
    let spaceID: String // Add space ID parameter
    
    // Get the current space ID for debug display
    private var currentSpaceID: String {
        spaceID // Use the passed space ID instead of the shared one
    }
    
    // Helper function to convert space ID string to UInt64
    private func spaceIDToUInt64(_ spaceIDString: String) -> UInt64 {
        // Remove "space-" prefix and convert to UInt64
        let numericPart = spaceIDString.replacingOccurrences(of: "space-", with: "")
        return UInt64(numericPart) ?? 0
    }
    
    var body: some View {
        ZStack {
            // Main taskbar
            HStack(spacing: 2) {
                // Window list
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(windowManager.getWindowsForSpace(self.spaceIDToUInt64(spaceID)), id: \.id) { window in
                            WindowButton(
                                windowID: window.id,
                                windowManager: windowManager,
                                keyboardSwitcher: keyboardSwitcher,
                                spaceID: spaceID
                            )
                        }
                    }
                    .padding(.horizontal, 4)
                }
                
                Spacer()
                
                // Logging control button
                Button(action: {
                    showLogControls.toggle()
                }) {
                    Image(systemName: "terminal")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(showLogControls ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .help("Toggle logging controls")
                
                // Settings button
                Button(action: {
                    showSettings.toggle()
                    openSettingsWindow()
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.clear)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .help("Open Settings")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 2)
            )
            .frame(height: 42)
            
            // Debug overlay
            VStack {
                // Debug info showing space ID and window count
                HStack {
                    Text("Taskbar: \(currentSpaceID)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                    
                    Text("Windows: \(windowManager.getWindowsForSpace(spaceIDToUInt64(spaceID)).count)/\(windowManager.spaceWindows.values.flatMap { $0 }.count)")
                        .font(.caption2)
                        .foregroundColor(.green)
                    
                    // Show window IDs for debugging
                    Text("App IDs: \(windowManager.getWindowsForSpace(spaceIDToUInt64(spaceID)).prefix(3).map { String($0.id) }.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundColor(.purple)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.1))
                .cornerRadius(4)
                
                Spacer()
                
                if !windowManager.hasAccessibilityPermission {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Accessibility permission required")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(4)
                }
            }
            
            // Logging controls overlay
            if showLogControls {
                VStack {
                    Spacer()
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Logging Controls")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        ForEach(Logger.LogCategory.allCases, id: \.self) { category in
                            HStack {
                                Button(action: {
                                    logger.toggleCategory(category)
                                }) {
                                    Image(systemName: logger.isEnabled(category) ? "checkmark.square.fill" : "square")
                                        .foregroundColor(logger.isEnabled(category) ? .green : .secondary)
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(PlainButtonStyle())
                                
                                Text(category.rawValue)
                                    .font(.caption2)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                            }
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.ultraThinMaterial)
                            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 50)
                }
            }
        }
    }
    
    private func openSettingsWindow() {
        // Post notification to AppDelegate to create settings window
        NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
    }
}

struct WindowButton: View {
    let windowID: CGWindowID
    @ObservedObject var windowManager: WindowManager
    @ObservedObject var keyboardSwitcher: KeyboardSwitcher
    let spaceID: String
    @State private var isHovered = false
    @StateObject private var logger = Logger.shared
    
    // Get the current window from windowManager (reactive to changes)
    private var window: WindowInfo? {
        // Look through all spaces to find the window
        for spaceWindows in windowManager.spaceWindows.values {
            if let window = spaceWindows.first(where: { $0.id == windowID }) {
                return window
            }
        }
        return nil
    }
    
    // Helper function to convert space ID string to UInt64
    private func spaceIDToUInt64(_ spaceIDString: String) -> UInt64 {
        // Remove "space-" prefix and convert to UInt64
        let numericPart = spaceIDString.replacingOccurrences(of: "space-", with: "")
        return UInt64(numericPart) ?? 0
    }
    
    var body: some View {
        guard let window = window else {
            return AnyView(EmptyView())
        }
        
        return AnyView(
            Button(action: {
                logger.info("Clicked window button for: \(window.displayName)", category: .taskbar)
                windowManager.activateWindow(window)
            }) {
            HStack(spacing: 4) {
                // App icon or assigned key letter
                if keyboardSwitcher.isSwitchingMode, let assignedKey = getAssignedKey() {
                    // Show assigned key letter when in switching mode
                    let backgroundColor = window.icon != nil ? extractAverageColor(from: window.icon!) : Color.accentColor
                    let textColor = contrastingTextColor(for: backgroundColor)
                    
                    Text(assignedKey.uppercased())
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(textColor)
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(backgroundColor)
                        )
                } else if let icon = window.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                
                // Window name
                Text(window.displayName)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: 200)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundColor(for: window))
            )
            .overlay(
                // Active window focus ring
                RoundedRectangle(cornerRadius: 4)
                    .stroke(window.isActive ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        } // Closes Button content
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button("Minimize") {
                windowManager.minimizeWindow(window)
            }
            Button("Close") {
                // Close window functionality
                print("Close \(window.displayName)")
            }
        }
        ) // Closes AnyView
    }
    
    /// Get the assigned key for this window from KeyboardSwitcher
    private func getAssignedKey() -> String? {
        let keyAssignments = keyboardSwitcher.getKeyAssignments()
        return keyAssignments[windowID]
    }
    
    /// Extract average color from an NSImage
    private func extractAverageColor(from image: NSImage) -> Color {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return Color.accentColor
        }
        
        // Create a small bitmap context to sample colors
        let width = 1
        let height = 1
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return Color.accentColor
        }
        
        // Draw the image scaled to 1x1 to get average color
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        
        guard let data = context.data else {
            return Color.accentColor
        }
        
        let pixelData = data.assumingMemoryBound(to: UInt8.self)
        let red = CGFloat(pixelData[0]) / 255.0
        let green = CGFloat(pixelData[1]) / 255.0
        let blue = CGFloat(pixelData[2]) / 255.0
        
        return Color(red: red, green: green, blue: blue)
    }
    
    /// Calculate contrasting text color based on background brightness
    private func contrastingTextColor(for backgroundColor: Color) -> Color {
        // Convert SwiftUI Color to UIColor to access RGB components
        let uiColor = NSColor(backgroundColor)
        
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        
        // Calculate luminance using standard formula
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        
        // Return white text for dark backgrounds, black text for light backgrounds
        return luminance > 0.5 ? Color.black : Color.white
    }
    
    private func backgroundColor(for window: WindowInfo) -> Color {
        if window.isActive {
            return Color.accentColor.opacity(0.3)
        } else if isHovered {
            return Color.primary.opacity(0.1)
        } else {
            return Color.clear
        }
    }
}

struct SettingsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("Settings")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Spacer()
            
            Text("Settings options will be added here")
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding(40)
    }
}

#Preview {
    ContentView()
        .environmentObject(WindowManager())
        .frame(width: 1200, height: 42)
        .background(Color.black.opacity(0.1))
}
