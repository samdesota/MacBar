//
//  KeyAssignmentManager.swift
//  Bar
//
//  Created by Samuel DeSota on 1/7/25.
//

import Foundation
import AppKit

/// Manages positional key assignment for window switching
/// Keys are assigned based on window position in taskbar: 1-9, 0, then QWERTY layout
class KeyAssignmentManager: ObservableObject {
    static let shared = KeyAssignmentManager()
    
    @Published var keyAssignments: [CGWindowID: String] = [:]
    @Published var assignedKeys: Set<String> = []
    
    private let logger = Logger.shared
    private let userDefaults = UserDefaults.standard
    private let storageKey = "WindowKeyAssignments"
    
    // Available keys for assignment (prioritized order)
    private let availableKeys: [String] = {
        // Numbers 1-9, then 0 (for 10th window), then QWERTY layout
        let numbers = "1234567890".map { String($0) }
        let qwertyRow1 = "qwertyuiop".map { String($0) }
        let qwertyRow2 = "asdfghjkl".map { String($0) }
        let qwertyRow3 = "zxcvbnm".map { String($0) }
        return numbers + qwertyRow1 + qwertyRow2 + qwertyRow3
    }()
    
    private init() {
        logger.info("KeyAssignmentManager initialized", category: .keyboardSwitching)
        // Note: No need to load persisted assignments for positional key assignment system
    }
    
    // MARK: - Public API
    
    /// Assign keys to all windows based on their position in the taskbar
    func assignKeys(to windows: [WindowInfo]) {
        logger.info("Starting positional key assignment for \(windows.count) windows", category: .keyboardSwitching)
        
        // Clear all existing assignments to reassign based on current positions
        keyAssignments.removeAll()
        assignedKeys.removeAll()
        
        // Assign keys based on window position in the array
        for (index, window) in windows.enumerated() {
            guard index < availableKeys.count else {
                logger.warning("Not enough keys available for window at position \(index + 1): '\(window.displayName)' (\(window.owner))", category: .keyboardSwitching)
                break
            }
            
            let assignedKey = availableKeys[index]
            keyAssignments[window.id] = assignedKey
            assignedKeys.insert(assignedKey)
            
            logger.debug("Assigned key '\(assignedKey)' to window at position \(index + 1): '\(window.displayName)' (\(window.owner))", category: .keyboardSwitching)
        }
        
        logger.info("Positional key assignment completed: \(keyAssignments.count) windows assigned", category: .keyboardSwitching)
        // Note: No persistence needed for positional assignments - they are recalculated each time
    }
    
    /// Get the assigned key for a specific window
    func getKey(for windowID: CGWindowID) -> String? {
        return keyAssignments[windowID]
    }
    
    /// Get the window ID for a specific key
    func getWindowID(for key: String) -> CGWindowID? {
        return keyAssignments.first(where: { $0.value == key })?.key
    }
    
    /// Get all current key assignments
    func getAllAssignments() -> [CGWindowID: String] {
        return keyAssignments
    }
    
    /// Clear all assignments
    func clearAssignments() {
        logger.info("Clearing all key assignments", category: .keyboardSwitching)
        keyAssignments.removeAll()
        assignedKeys.removeAll()
        // Note: No persistence needed for positional assignments
    }
    
    // MARK: - Private Implementation
    
    // MARK: - Persistence
    
    /// Load persisted key assignments from UserDefaults
    private func loadPersistedAssignments() {
        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            logger.debug("No persisted key assignments found", category: .keyboardSwitching)
            return
        }
        
        // Convert String keys back to CGWindowID
        for (windowIDString, key) in decoded {
            if let windowID = CGWindowID(windowIDString) {
                keyAssignments[windowID] = key
                assignedKeys.insert(key)
            }
        }
        
        logger.info("Loaded \(keyAssignments.count) persisted key assignments", category: .keyboardSwitching)
    }
    
    /// Persist current key assignments to UserDefaults
    private func persistAssignments() {
        // Convert CGWindowID keys to String for JSON serialization
        let stringKeysDict = Dictionary(uniqueKeysWithValues: 
            keyAssignments.map { (String($0.key), $0.value) }
        )
        
        if let encoded = try? JSONEncoder().encode(stringKeysDict) {
            userDefaults.set(encoded, forKey: storageKey)
            logger.debug("Persisted \(keyAssignments.count) key assignments", category: .keyboardSwitching)
        } else {
            logger.error("Failed to persist key assignments", category: .keyboardSwitching)
        }
    }
}

// MARK: - Testing Support

extension KeyAssignmentManager {
    /// Create mock WindowInfo for testing
    static func createMockWindowInfo(
        id: CGWindowID = CGWindowID.random(in: 1000...9999),
        name: String,
        owner: String,
        isActive: Bool = false,
        forceShowTitle: Bool = false,
        spaceID: UInt64 = 1
    ) -> WindowInfo {
        return WindowInfo(
            id: id,
            name: name,
            owner: owner,
            icon: nil,
            isActive: isActive,
            forceShowTitle: forceShowTitle,
            spaceID: spaceID
        )
    }
    
    /// Generate mock windows for testing various scenarios
    static func generateMockWindows() -> [WindowInfo] {
        return [
            // Basic apps - should get first letters
            createMockWindowInfo(name: "Safari", owner: "Safari"),
            createMockWindowInfo(name: "Chrome", owner: "Google Chrome"),
            createMockWindowInfo(name: "Xcode", owner: "Xcode"),
            
            // Conflict scenario - both start with 'S'
            createMockWindowInfo(name: "Slack", owner: "Slack"),
            createMockWindowInfo(name: "Spotify", owner: "Spotify"),
            
            // Multiple windows from same app
            createMockWindowInfo(name: "Document.txt", owner: "TextEdit", forceShowTitle: true),
            createMockWindowInfo(name: "Notes.txt", owner: "TextEdit", forceShowTitle: true),
            
            // Edge cases
            createMockWindowInfo(name: "", owner: "App with Empty Title"),
            createMockWindowInfo(name: "123 Special@#$", owner: "Special Characters"),
            createMockWindowInfo(name: "Terminal", owner: "Terminal", isActive: true),
            
            // Long names
            createMockWindowInfo(name: "Very Long Window Title That Should Be Truncated", owner: "Long App Name"),
            
            // Identical names (rare but possible)
            createMockWindowInfo(name: "Untitled", owner: "App One"),
            createMockWindowInfo(name: "Untitled", owner: "App Two"),
            
            // Numbers in names
            createMockWindowInfo(name: "Photoshop 2024", owner: "Adobe Photoshop 2024"),
            createMockWindowInfo(name: "Excel", owner: "Microsoft Excel"),
            
            // More apps to test fallback to QWERTY keys
            createMockWindowInfo(name: "Finder", owner: "Finder"),
            createMockWindowInfo(name: "Mail", owner: "Mail"),
            createMockWindowInfo(name: "Calendar", owner: "Calendar"),
            createMockWindowInfo(name: "Notes", owner: "Notes"),
            createMockWindowInfo(name: "Reminders", owner: "Reminders"),
            createMockWindowInfo(name: "Preview", owner: "Preview"),
            createMockWindowInfo(name: "Activity Monitor", owner: "Activity Monitor")
        ]
    }
}