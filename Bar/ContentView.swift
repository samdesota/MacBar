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
    @State private var showSettings = false
    
    var body: some View {
        ZStack {
            // Main taskbar
            HStack(spacing: 2) {
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
    let window: WindowInfo
    @ObservedObject var windowManager: WindowManager
    @State private var isHovered = false
    @StateObject private var logger = Logger.shared
    
    var body: some View {
        Button(action: {
            logger.info("Clicked window button for: \(window.displayName)", category: .taskbar)
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
        .frame(width: 1200, height: 42)
        .background(Color.black.opacity(0.1))
}
