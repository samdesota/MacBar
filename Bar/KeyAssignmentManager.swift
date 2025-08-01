//
//  KeyAssignmentManager.swift
//  Bar
//
//  Created by Samuel DeSota on 1/7/25.
//

import Foundation
import AppKit

/// Manages intelligent key assignment for window switching
class KeyAssignmentManager: ObservableObject {
    static let shared = KeyAssignmentManager()
    
    @Published var keyAssignments: [CGWindowID: String] = [:]
    @Published var assignedKeys: Set<String> = []
    
    private let logger = Logger.shared
    private let userDefaults = UserDefaults.standard
    private let storageKey = "WindowKeyAssignments"
    
    // Available keys for assignment (prioritized order)
    private let availableKeys: [String] = {
        // Alphanumeric keys in preference order
        let letters = "abcdefghijklmnopqrstuvwxyz".map { String($0) }
        let numbers = "1234567890".map { String($0) }
        return letters + numbers
    }()
    
    private init() {
        logger.info("KeyAssignmentManager initialized", category: .keyboardSwitching)
        loadPersistedAssignments()
    }
    
    // MARK: - Public API
    
    /// Assign keys to all windows using intelligent algorithm
    func assignKeys(to windows: [WindowInfo]) {
        logger.info("Starting key assignment for \(windows.count) windows", category: .keyboardSwitching)
        
        // Clean up assignments for windows that no longer exist
        let currentWindowIDs = Set(windows.map { $0.id })
        let previousAssignmentCount = keyAssignments.count
        keyAssignments = keyAssignments.filter { currentWindowIDs.contains($0.key) }
        
        // Update assignedKeys to match current assignments
        assignedKeys = Set(keyAssignments.values)
        
        let cleanedCount = previousAssignmentCount - keyAssignments.count
        if cleanedCount > 0 {
            logger.info("Cleaned up \(cleanedCount) assignments for closed windows", category: .keyboardSwitching)
        }
        
        // Only assign keys to windows that don't already have assignments
        let windowsNeedingAssignment = windows.filter { keyAssignments[$0.id] == nil }
        logger.info("\(keyAssignments.count) windows have existing assignments, \(windowsNeedingAssignment.count) need new assignments", category: .keyboardSwitching)
        
        // Sort new windows by preference (active first, then alphabetically by display name)
        let sortedNewWindows = sortWindowsByPriority(windowsNeedingAssignment)
        
        for window in sortedNewWindows {
            if let assignedKey = assignKey(for: window) {
                keyAssignments[window.id] = assignedKey
                assignedKeys.insert(assignedKey)
                
                logger.debug("Assigned key '\(assignedKey)' to new window '\(window.displayName)' (\(window.owner))", category: .keyboardSwitching)
            } else {
                logger.warning("Failed to assign key to window '\(window.displayName)' (\(window.owner)) - no available keys", category: .keyboardSwitching)
            }
        }
        
        // Log preserved assignments for debugging
        let preservedWindows = windows.filter { window in
            keyAssignments[window.id] != nil && !windowsNeedingAssignment.contains(where: { $0.id == window.id })
        }
        for window in preservedWindows {
            if let key = keyAssignments[window.id] {
                logger.debug("Preserved key '\(key)' for existing window '\(window.displayName)' (\(window.owner))", category: .keyboardSwitching)
            }
        }
        
        logger.info("Key assignment completed: \(keyAssignments.count) windows assigned, \(assignedKeys.count) keys used", category: .keyboardSwitching)
        persistAssignments()
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
        persistAssignments()
    }
    
    // MARK: - Private Implementation
    
    /// Sort windows by assignment priority
    private func sortWindowsByPriority(_ windows: [WindowInfo]) -> [WindowInfo] {
        return windows.sorted { window1, window2 in
            // Active windows first
            if window1.isActive != window2.isActive {
                return window1.isActive
            }
            
            // Then sort alphabetically by display name
            return window1.displayName.localizedCaseInsensitiveCompare(window2.displayName) == .orderedAscending
        }
    }
    
    /// Assign a key to a specific window using intelligent algorithm
    private func assignKey(for window: WindowInfo) -> String? {
        logger.debug("Assigning key for window: '\(window.displayName)' (owner: '\(window.owner)')", category: .keyboardSwitching)
        
        // Strategy 1: Try first letter of app name (owner)
        if let key = tryFirstLetterStrategy(for: window.owner) {
            logger.debug("Strategy 1 success: first letter of app name '\(window.owner)' → '\(key)'", category: .keyboardSwitching)
            return key
        }
        
        // Strategy 2: Try subsequent letters of app name
        if let key = trySubsequentLettersStrategy(for: window.owner) {
            logger.debug("Strategy 2 success: subsequent letter of app name '\(window.owner)' → '\(key)'", category: .keyboardSwitching)
            return key
        }
        
        // Strategy 3: Try first letter of window name (if different from app name)
        if !window.name.isEmpty && window.name != window.owner {
            if let key = tryFirstLetterStrategy(for: window.name) {
                logger.debug("Strategy 3 success: first letter of window name '\(window.name)' → '\(key)'", category: .keyboardSwitching)
                return key
            }
            
            // Strategy 4: Try subsequent letters of window name
            if let key = trySubsequentLettersStrategy(for: window.name) {
                logger.debug("Strategy 4 success: subsequent letter of window name '\(window.name)' → '\(key)'", category: .keyboardSwitching)
                return key
            }
        }
        
        // Strategy 5: Fall back to any available key
        if let key = findNextAvailableKey() {
            logger.debug("Strategy 5 fallback: assigned available key '\(key)'", category: .keyboardSwitching)
            return key
        }
        
        logger.warning("No key could be assigned for window '\(window.displayName)'", category: .keyboardSwitching)
        return nil
    }
    
    /// Try to assign the first letter of a name
    private func tryFirstLetterStrategy(for name: String) -> String? {
        guard let firstChar = name.lowercased().first,
              firstChar.isLetter else {
            return nil
        }
        
        let key = String(firstChar)
        return assignedKeys.contains(key) ? nil : key
    }
    
    /// Try to assign subsequent letters of a name
    private func trySubsequentLettersStrategy(for name: String) -> String? {
        let cleanName = name.lowercased().filter { $0.isLetter }
        
        for char in cleanName.dropFirst() {
            let key = String(char)
            if !assignedKeys.contains(key) {
                return key
            }
        }
        
        return nil
    }
    
    /// Find the next available key from the prioritized list
    private func findNextAvailableKey() -> String? {
        return availableKeys.first { !assignedKeys.contains($0) }
    }
    
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
        forceShowTitle: Bool = false
    ) -> WindowInfo {
        return WindowInfo(
            id: id,
            name: name,
            owner: owner,
            icon: nil,
            isActive: isActive,
            forceShowTitle: forceShowTitle
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
            
            // More apps to test sfllback to numbers
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