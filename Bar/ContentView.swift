//
//  ContentView.swift
//  Bar
//
//  Created by Samuel DeSota on 7/31/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var windowManager = WindowManager()
    
    var body: some View {
        TaskbarView(windowManager: windowManager)
    }
}

struct TaskbarView: View {
    @ObservedObject var windowManager: WindowManager
    @StateObject private var logger = Logger.shared
    @State private var showLogControls = false
    
    var body: some View {
        ZStack {
            // Main taskbar
            HStack(spacing: 2) {
                // Start button (like Windows)
                StartButton(windowManager: windowManager)
                
                // Separator
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 1, height: 30)
                    .padding(.horizontal, 8)
                
                // Window list
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(windowManager.openWindows) { window in
                            WindowButton(window: window, windowManager: windowManager)
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
                
                // System tray area (right side)
                SystemTrayArea()
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
                
                Spacer()
                
                HStack {
                    Text(windowManager.debugInfo)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
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
}

struct StartButton: View {
    @State private var isHovered = false
    @ObservedObject var windowManager: WindowManager
    
    var body: some View {
        Button(action: {
            // Check permissions and refresh window list
            windowManager.checkAccessibilityPermission()
            windowManager.updateWindowList()
        }) {
            Image(systemName: "applelogo")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.primary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.primary.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Click to refresh window list and check permissions")
    }
}

struct WindowButton: View {
    let window: WindowInfo
    @ObservedObject var windowManager: WindowManager
    @State private var isHovered = false
    
    var body: some View {
        Button(action: {
            windowManager.activateWindow(window)
        }) {
            HStack(spacing: 6) {
                // App icon
                if let icon = window.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "app")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                
                // Window name
                Text(window.displayName)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 200)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(window.isActive ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
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
    }
    
    private var backgroundColor: Color {
        if window.isActive {
            return Color.accentColor.opacity(0.2)
        } else if isHovered {
            return Color.primary.opacity(0.1)
        } else {
            return Color.clear
        }
    }
}

struct SystemTrayArea: View {
    var body: some View {
        HStack(spacing: 8) {
            // Clock
            Text(Date(), style: .time)
                .font(.system(size: 11))
                .foregroundColor(.primary)
            
            // Battery indicator
            Image(systemName: "battery.100")
                .font(.system(size: 12))
                .foregroundColor(.green)
            
            // WiFi indicator
            Image(systemName: "wifi")
                .font(.system(size: 12))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.clear)
        )
    }
}

#Preview {
    ContentView()
        .frame(width: 800, height: 42)
        .background(Color.black.opacity(0.1))
}
