//
//  PermissionGateView.swift
//  Bar
//
//  Created by Samuel DeSota on 7/31/25.
//

import SwiftUI
import AppKit

struct PermissionGateView: View {
    @StateObject private var logger = Logger.shared
    @State private var hasPermission = false
    
    var body: some View {
        VStack(spacing: 20) {
            // App icon/logo
            Image(systemName: "rectangle.bottomthird.inset.filled")
                .font(.system(size: 80))
                .foregroundColor(.accentColor)
            
            // Title
            Text("Bar Taskbar")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            // Subtitle
            Text("A Windows-style taskbar for macOS")
                .font(.title2)
                .foregroundColor(.secondary)
            
            Spacer()
            
            // Permission section
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: hasPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(hasPermission ? .green : .orange)
                        .font(.title2)
                    
                    Text(hasPermission ? "Accessibility Permission Granted" : "Accessibility Permission Required")
                        .font(.headline)
                        .foregroundColor(hasPermission ? .green : .orange)
                }
                
                if !hasPermission {
                    Text("Bar needs accessibility permissions to detect and manage windows on your system.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 40)
                    
                    Button(action: openSystemPreferences) {
                        HStack {
                            Image(systemName: "gear")
                            Text("Open System Preferences")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.accentColor)
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Text("1. Click 'Open System Preferences' above\n2. Go to 'Privacy & Security' → 'Accessibility'\n3. Click the lock icon and enter your password\n4. Check the box next to 'Bar' (should appear automatically)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
            .padding(30)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
            )
            
            Spacer()
            
            // Footer
            Text("After granting permissions, restart the app")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(40)
        .frame(maxWidth: 500, maxHeight: 600)
        .onAppear {
            checkPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermission()
        }
    }
    
    private func checkPermission() {
        // Use prompt option to automatically add app to accessibility permissions
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let permission = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        DispatchQueue.main.async {
            self.hasPermission = permission
            self.logger.info("Permission check result: \(permission)", category: .accessibility)
        }
    }
    
    private func openSystemPreferences() {
        // Open System Preferences to the Accessibility section
        let script = """
        tell application "System Preferences"
            activate
            set current pane to pane id "com.apple.preference.security"
        end tell
        tell application "System Events"
            tell process "System Preferences"
                click button "Privacy & Security" of tab group 1 of window 1
                delay 1
                click button "Accessibility" of row 8 of table 1 of scroll area 1 of tab group 1 of window 1
            end tell
        end tell
        """
        
        if let scriptObject = NSAppleScript(source: script) {
            var error: NSDictionary?
            scriptObject.executeAndReturnError(&error)
            
            if let error = error {
                logger.error("Failed to open System Preferences: \(error)", category: .accessibility)
                // Fallback: just open System Preferences
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }
}

#Preview {
    PermissionGateView()
} 