//
//  ContentView.swift
//  Bar
//
//  Created by Samuel DeSota on 7/31/25.
//

import SwiftUI
import AppKit

// Preference key for capturing window button sizes
struct WindowSizePreferenceKey: PreferenceKey {
    static var defaultValue: [CGWindowID: CGFloat] = [:]
    
    static func reduce(value: inout [CGWindowID: CGFloat], nextValue: () -> [CGWindowID: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

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
    @State private var draggedWindowID: CGWindowID?
    @State private var dragOffset: CGSize = .zero
    @State private var draggedWindowIndex: Int?
    @State private var targetIndex: Int?
    @State private var windowWidths: [CGWindowID: CGFloat] = [:]
    @State private var isApplyingReorder = false
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
    
    // Get windows for this space
    private var windows: [WindowInfo] {
        return windowManager.getWindowsForSpace(self.spaceIDToUInt64(spaceID))
    }
    
    // Calculate offset for window at given index during drag
    private func offsetForWindow(at index: Int) -> CGFloat {
        // During reorder application, maintain the visual state to prevent jumping
        if isApplyingReorder {
            return 0
        }
        
        guard let draggedIndex = draggedWindowIndex,
              let targetIdx = targetIndex,
              draggedIndex != targetIdx else {
            
            // If this is the dragged window, apply drag offset
            if let draggedID = draggedWindowID,
               windows.indices.contains(index),
               windows[index].id == draggedID {
                return dragOffset.width
            }
            return 0
        }
        
        // Window being dragged
        if index == draggedIndex {
            return dragOffset.width
        }
        
        // Get the width of the dragged window for shifting calculations
        let draggedWindowID = windows.indices.contains(draggedIndex) ? windows[draggedIndex].id : 0
        let draggedWindowWidth = windowWidths[draggedWindowID] ?? 200
        let spacing: CGFloat = 8
        let shiftDistance = draggedWindowWidth + spacing
        
        // Windows that need to shift to make space
        if draggedIndex < targetIdx {
            // Dragging right: shift left the windows between draggedIndex and targetIdx
            if index > draggedIndex && index <= targetIdx {
                return -shiftDistance
            }
        } else {
            // Dragging left: shift right the windows between targetIdx and draggedIndex
            if index >= targetIdx && index < draggedIndex {
                return shiftDistance
            }
        }
        
        return 0
    }
    
    // Create drag gesture for a specific window
    private func dragGesture(for window: WindowInfo, at index: Int) -> some Gesture {
        DragGesture()
            .onChanged { value in
                handleDragChanged(window: window, index: index, value: value)
            }
            .onEnded { value in
                handleDragEnded(window: window, value: value)
            }
    }
    
    // Handle drag changed
    private func handleDragChanged(window: WindowInfo, index: Int, value: DragGesture.Value) {
        if draggedWindowID != window.id {
            // Start dragging
            draggedWindowID = window.id
            draggedWindowIndex = index
        }
        
        dragOffset = value.translation
        
        // Calculate which window we're hovering over using actual widths
        let dragDistance = value.translation.width
        var cumulativeWidth: CGFloat = 0
        var newIndex = index
        
        if dragDistance > 0 {
            // Dragging right
            for i in (index + 1)..<windows.count {
                let windowID = windows[i].id
                let windowWidth = windowWidths[windowID] ?? 200
                let spacing: CGFloat = 8
                cumulativeWidth += windowWidth + spacing
                
                if dragDistance > cumulativeWidth - (windowWidth + spacing) / 2 {
                    newIndex = i
                } else {
                    break
                }
            }
        } else if dragDistance < 0 {
            // Dragging left
            for i in (0..<index).reversed() {
                let windowID = windows[i].id
                let windowWidth = windowWidths[windowID] ?? 200
                let spacing: CGFloat = 8
                cumulativeWidth -= windowWidth + spacing
                
                if dragDistance < cumulativeWidth + (windowWidth + spacing) / 2 {
                    newIndex = i
                } else {
                    break
                }
            }
        }
        
        let clampedIndex = max(0, min(windows.count - 1, newIndex))
        if targetIndex != clampedIndex {
            targetIndex = clampedIndex
        }
    }
    
    // Handle drag ended
    private func handleDragEnded(window: WindowInfo, value: DragGesture.Value) {
        // Apply the reorder
        if let fromIndex = draggedWindowIndex,
           let toIndex = targetIndex,
           fromIndex != toIndex {
            
            isApplyingReorder = true
            let spaceIDUInt64 = spaceIDToUInt64(spaceID)
            
            // Apply reorder to WindowManager
            windowManager.reorderWindow(
                windowID: window.id,
                fromIndex: fromIndex,
                toIndex: toIndex,
                spaceID: spaceIDUInt64
            )
            
            // Delay the state reset to allow WindowManager update to propagate
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                resetDragState()
            }
        } else {
            // No reorder needed, reset immediately
            resetDragState()
        }
    }
    
    // Reset all drag-related state
    private func resetDragState() {
        draggedWindowID = nil
        dragOffset = .zero
        draggedWindowIndex = nil
        targetIndex = nil
        isApplyingReorder = false
    }
    
    var body: some View {
        ZStack {
            // Main taskbar
            HStack(spacing: 2) {
                // Window list
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                            WindowButton(
                                windowID: window.id,
                                windowManager: windowManager,
                                keyboardSwitcher: keyboardSwitcher,
                                spaceID: spaceID,
                                window: window
                            )
                            .background(
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: WindowSizePreferenceKey.self,
                                        value: [window.id: geometry.size.width]
                                    )
                                }
                            )
                            .offset(x: offsetForWindow(at: index), y: 0)
                            .scaleEffect(draggedWindowID == window.id ? 1.05 : 1.0)
                            .opacity(draggedWindowID == window.id ? 0.8 : 1.0)
                            .animation(
                                isApplyingReorder ? .easeInOut(duration: 0.3) : .interactiveSpring(),
                                value: offsetForWindow(at: index)
                            )
                            .animation(.easeInOut(duration: 0.15), value: draggedWindowID == window.id)
                            .gesture(dragGesture(for: window, at: index))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: windows.map { $0.id })
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
        .onPreferenceChange(WindowSizePreferenceKey.self) { sizes in
            windowWidths = sizes
        }
    }
    
    private func openSettingsWindow() {
        // Post notification to AppDelegate to create settings window
        NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
    }
    
    private func moveWindow(from source: IndexSet, to destination: Int) {
        let spaceIDUInt64 = spaceIDToUInt64(spaceID)
        
        // Get the current windows for this space
        var windows = windowManager.getWindowsForSpace(spaceIDUInt64)
        
        // Perform the move operation on our local copy
        windows.move(fromOffsets: source, toOffset: destination)
        
        // Extract the window IDs in the new order (for future use if needed)
        _ = windows.map { $0.id }
        
        // Update the window manager with the new order
        if let sourceIndex = source.first {
            windowManager.reorderWindow(
                windowID: windows[destination > sourceIndex ? destination - 1 : destination].id,
                fromIndex: sourceIndex,
                toIndex: destination > sourceIndex ? destination - 1 : destination,
                spaceID: spaceIDUInt64
            )
        }
        
        logger.info("Moved window from \(source) to \(destination)", category: .taskbar)
    }
}

struct WindowButton: View {
    let windowID: CGWindowID
    @ObservedObject var windowManager: WindowManager
    @ObservedObject var keyboardSwitcher: KeyboardSwitcher
    let spaceID: String
    let window: WindowInfo
    @State private var isHovered = false
    @StateObject private var logger = Logger.shared
    
    var body: some View {
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
            .onTapGesture {
                logger.info("Clicked window button for: \(window.displayName)", category: .taskbar)
                windowManager.activateWindow(window)
            }
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
