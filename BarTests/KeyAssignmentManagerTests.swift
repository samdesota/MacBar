//
//  KeyAssignmentManagerTests.swift
//  BarTests
//
//  Created by Samuel DeSota on 1/7/25.
//

import Testing
import Foundation
import CoreGraphics
@testable import Bar

/// Test suite for KeyAssignmentManager using Swift Testing framework
struct KeyAssignmentManagerTests {
    
    // MARK: - Helper Methods
    
    /// Create a fresh KeyAssignmentManager for each test
    private func createKeyManager() -> KeyAssignmentManager {
        let manager = KeyAssignmentManager.shared
        manager.clearAssignments()
        return manager
    }
    
    // MARK: - Basic Functionality Tests
    
    @Test("Basic first letter assignment")
    func basicFirstLetterAssignment() async throws {
        let keyManager = createKeyManager()
        
        let windows = [
            KeyAssignmentManager.createMockWindowInfo(id: 1001, name: "Safari", owner: "Safari"),
            KeyAssignmentManager.createMockWindowInfo(id: 1002, name: "Chrome", owner: "Google Chrome"),
            KeyAssignmentManager.createMockWindowInfo(id: 1003, name: "Xcode", owner: "Xcode")
        ]
        
        keyManager.assignKeys(to: windows)
        
        // Verify expected assignments
        #expect(keyManager.getKey(for: 1001) == "s")
        #expect(keyManager.getKey(for: 1002) == "g")
        #expect(keyManager.getKey(for: 1003) == "x")
        #expect(keyManager.getAllAssignments().count == 3)
    }
    
    @Test("Conflict resolution with same first letter")
    func conflictResolution() async throws {
        let keyManager = createKeyManager()
        
        let windows = [
            KeyAssignmentManager.createMockWindowInfo(id: 2001, name: "Safari", owner: "Safari"),
            KeyAssignmentManager.createMockWindowInfo(id: 2002, name: "Slack", owner: "Slack"),
            KeyAssignmentManager.createMockWindowInfo(id: 2003, name: "Spotify", owner: "Spotify")
        ]
        
        keyManager.assignKeys(to: windows)
        
        let assignments = keyManager.getAllAssignments()
        let assignedKeys = Set(assignments.values)
        
        // Should have 3 unique keys
        #expect(assignedKeys.count == 3)
        
        // One should get 's', others should get different letters
        #expect(assignedKeys.contains("s"))
        
        // All assignments should be single characters
        #expect(assignedKeys.allSatisfy { $0.count == 1 })
    }
    
    @Test("Subsequent letters strategy")
    func subsequentLettersStrategy() async throws {
        let keyManager = createKeyManager()
        
        // Force conflict by using apps that all start with 'A'
        let windows = [
            KeyAssignmentManager.createMockWindowInfo(id: 3001, name: "App1", owner: "Alpha"),
            KeyAssignmentManager.createMockWindowInfo(id: 3002, name: "App2", owner: "Apex"),
            KeyAssignmentManager.createMockWindowInfo(id: 3003, name: "App3", owner: "Arena")
        ]
        
        keyManager.assignKeys(to: windows)
        
        let assignments = keyManager.getAllAssignments()
        let assignedKeys = Set(assignments.values)
        
        // Should have 3 unique keys
        #expect(assignedKeys.count == 3)
        
        // First should get 'a', others should use subsequent letters
        #expect(assignedKeys.contains("a"))
        #expect(assignedKeys.allSatisfy { $0.count == 1 })
    }
    
    @Test("Multiple windows from same app")
    func multipleWindowsSameApp() async throws {
        let keyManager = createKeyManager()
        
        let windows = [
            KeyAssignmentManager.createMockWindowInfo(id: 4001, name: "Document1.txt", owner: "TextEdit"),
            KeyAssignmentManager.createMockWindowInfo(id: 4002, name: "Document2.txt", owner: "TextEdit"),
            KeyAssignmentManager.createMockWindowInfo(id: 4003, name: "Notes.txt", owner: "TextEdit")
        ]
        
        keyManager.assignKeys(to: windows)
        
        let assignments = keyManager.getAllAssignments()
        let assignedKeys = Set(assignments.values)
        
        // Should assign unique keys to each window
        #expect(assignedKeys.count == 3)
        #expect(assignments.count == 3)
    }
    
    @Test("Active window priority")
    func activeWindowPriority() async throws {
        let keyManager = createKeyManager()
        
        let windows = [
            KeyAssignmentManager.createMockWindowInfo(id: 5001, name: "Background", owner: "Background App", isActive: false),
            KeyAssignmentManager.createMockWindowInfo(id: 5002, name: "Active", owner: "Active App", isActive: true),
            KeyAssignmentManager.createMockWindowInfo(id: 5003, name: "Another", owner: "Another App", isActive: false)
        ]
        
        keyManager.assignKeys(to: windows)
        
        // The active window should get a preferential key
        let activeWindowKey = keyManager.getKey(for: 5002)
        #expect(activeWindowKey == "a") // Should get 'a' for "Active App"
    }
    
    // MARK: - Edge Cases
    
    @Test("Empty and special character names")
    func emptyAndSpecialCharacters() async throws {
        let keyManager = createKeyManager()
        
        let windows = [
            KeyAssignmentManager.createMockWindowInfo(id: 6001, name: "", owner: ""),
            KeyAssignmentManager.createMockWindowInfo(id: 6002, name: "   ", owner: "   "),
            KeyAssignmentManager.createMockWindowInfo(id: 6003, name: "123!@#", owner: "123!@#"),
            KeyAssignmentManager.createMockWindowInfo(id: 6004, name: "Valid", owner: "Valid App")
        ]
        
        keyManager.assignKeys(to: windows)
        
        let assignments = keyManager.getAllAssignments()
        
        // Should handle gracefully without crashing
        // Valid app should definitely get a key
        #expect(assignments.values.contains("v"))
    }
    
    @Test("Key uniqueness with many windows")
    func keyUniqueness() async throws {
        let keyManager = createKeyManager()
        
        let windows = KeyAssignmentManager.generateMockWindows()
        keyManager.assignKeys(to: windows)
        
        let assignments = keyManager.getAllAssignments()
        let assignedKeys = Array(assignments.values)
        let uniqueKeys = Set(assignedKeys)
        
        // All assigned keys should be unique
        #expect(assignedKeys.count == uniqueKeys.count)
    }
    
    @Test("Number fallback when letters exhausted")
    func numberFallback() async throws {
        let keyManager = createKeyManager()
        
        // Create more than 26 windows to force number fallback
        var windows: [WindowInfo] = []
        
        for i in 0..<30 {
            let letter = String(Character(UnicodeScalar(97 + (i % 26))!)) // a-z cycling
            windows.append(KeyAssignmentManager.createMockWindowInfo(
                id: CGWindowID(7000 + i),
                name: "App\(i)",
                owner: "\(letter.uppercased())pp\(i)"
            ))
        }
        
        keyManager.assignKeys(to: windows)
        
        let assignments = keyManager.getAllAssignments()
        let assignedKeys = Set(assignments.values)
        
        // Should assign keys to all or most windows
        #expect(assignments.count >= 26)
        
        // Some should be numbers
        let hasNumbers = assignedKeys.contains { $0.first?.isNumber == true }
        #expect(hasNumbers)
    }
    
    // MARK: - Performance Tests
    
    @Test("Performance with many windows")
    func performanceWithManyWindows() async throws {
        let keyManager = createKeyManager()
        let windows = KeyAssignmentManager.generateMockWindows()
        
        let startTime = Date()
        keyManager.assignKeys(to: windows)
        let duration = Date().timeIntervalSince(startTime)
        
        let assignments = keyManager.getAllAssignments()
        
        // Should complete quickly (under 100ms for ~20 windows)
        #expect(duration < 0.1, "Performance test failed: took \(duration)s for \(windows.count) windows")
        
        // Should assign keys to most windows (at least 80%)
        let expectedMinimum = Int(Double(windows.count) * 0.8)
        #expect(assignments.count >= expectedMinimum)
    }
    
    // MARK: - API Tests
    
    @Test("Key lookup operations")
    func keyLookupOperations() async throws {
        let keyManager = createKeyManager()
        
        let window = KeyAssignmentManager.createMockWindowInfo(id: 8001, name: "Test", owner: "Test App")
        keyManager.assignKeys(to: [window])
        
        // Test forward lookup (window ID → key)
        let assignedKey = keyManager.getKey(for: 8001)
        #expect(assignedKey != nil)
        
        // Test reverse lookup (key → window ID)
        if let key = assignedKey {
            let foundWindowID = keyManager.getWindowID(for: key)
            #expect(foundWindowID == 8001)
        }
    }
    
    @Test("Clear assignments")
    func clearAssignments() async throws {
        let keyManager = createKeyManager()
        
        let windows = [
            KeyAssignmentManager.createMockWindowInfo(id: 9001, name: "Test1", owner: "App1"),
            KeyAssignmentManager.createMockWindowInfo(id: 9002, name: "Test2", owner: "App2")
        ]
        
        keyManager.assignKeys(to: windows)
        #expect(keyManager.getAllAssignments().count == 2)
        
        keyManager.clearAssignments()
        #expect(keyManager.getAllAssignments().isEmpty)
    }
}
