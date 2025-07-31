//
//  KeyboardPermissionManager.swift
//  Bar
//
//  Created by Samuel DeSota on 1/7/25.
//

import Foundation
import AppKit
import Carbon

class KeyboardPermissionManager: ObservableObject {
    static let shared = KeyboardPermissionManager()
    
    @Published var hasInputMonitoringPermission: Bool = false
    @Published var hasAccessibilityPermission: Bool = false
    
    private let logger = Logger.shared
    
    private init() {
        logger.info("KeyboardPermissionManager initialized", category: .accessibility)
        checkPermissions()
    }
    
    /// Check both accessibility and input monitoring permissions
    func checkPermissions() {
        checkAccessibilityPermission()
        checkInputMonitoringPermission()
        
        logger.info("Permission status - Accessibility: \(hasAccessibilityPermission), Input Monitoring: \(hasInputMonitoringPermission)", category: .accessibility)
    }
    
    /// Check accessibility permission (required for window management)
    private func checkAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let hasPermission = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        DispatchQueue.main.async {
            self.hasAccessibilityPermission = hasPermission
            self.logger.info("Accessibility permission check: \(hasPermission)", category: .accessibility)
        }
    }
    
    /// Check input monitoring permission (required for global keyboard events)
    private func checkInputMonitoringPermission() {
        // Try to create a global event monitor to test permission
        let testMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { _ in
            // This block will only execute if we have permission
        }
        
        let hasPermission = testMonitor != nil
        
        if let monitor = testMonitor {
            NSEvent.removeMonitor(monitor)
            logger.info("Input monitoring permission test: SUCCESS", category: .accessibility)
        } else {
            logger.warning("Input monitoring permission test: FAILED", category: .accessibility)
        }
        
        DispatchQueue.main.async {
            self.hasInputMonitoringPermission = hasPermission
        }
    }
    
    /// Request accessibility permission with prompt
    func requestAccessibilityPermission() {
        logger.info("Requesting accessibility permission with prompt", category: .accessibility)
        
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let hasPermission = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        DispatchQueue.main.async {
            self.hasAccessibilityPermission = hasPermission
            self.logger.info("Accessibility permission after prompt: \(hasPermission)", category: .accessibility)
        }
    }
    
    /// Request input monitoring permission (this will open System Preferences)
    func requestInputMonitoringPermission() {
        logger.info("Opening System Preferences for Input Monitoring permission", category: .accessibility)
        
        // Open System Preferences to Privacy & Security > Input Monitoring
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
    
    /// Check if we have all required permissions for keyboard switching
    var hasAllRequiredPermissions: Bool {
        return hasAccessibilityPermission && hasInputMonitoringPermission
    }
    
    /// Start monitoring permission changes
    func startPermissionMonitoring() {
        logger.info("Starting permission monitoring", category: .accessibility)
        
        // Check permissions every 2 seconds
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkPermissions()
        }
    }
}