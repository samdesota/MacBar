//
//  MockWindowInfoTests.swift
//  BarTests
//
//  Created by Samuel DeSota on 1/7/25.
//

import Testing
import Foundation
import CoreGraphics
@testable import Bar

/// Test suite for mock WindowInfo creation and handling
struct MockWindowInfoTests {
    
    @Test("Mock window creation")
    func mockWindowCreation() async throws {
        let window = KeyAssignmentManager.createMockWindowInfo(
            id: 1001,
            name: "Test Window",
            owner: "Test App",
            isActive: true,
            forceShowTitle: false
        )
        
        #expect(window.id == 1001)
        #expect(window.name == "Test Window")
        #expect(window.owner == "Test App")
        #expect(window.isActive == true)
        #expect(window.forceShowTitle == false)
        #expect(window.icon == nil)
    }
    
    @Test("Display name calculation")
    func displayNameCalculation() async throws {
        // Test normal display name (should show owner)
        let normalWindow = KeyAssignmentManager.createMockWindowInfo(
            name: "Document.txt",
            owner: "TextEdit",
            forceShowTitle: false
        )
        #expect(normalWindow.displayName == "TextEdit")
        
        // Test forced title display
        let forcedTitleWindow = KeyAssignmentManager.createMockWindowInfo(
            name: "Important Document.txt",
            owner: "TextEdit",
            forceShowTitle: true
        )
        #expect(forcedTitleWindow.displayName == "Important Document.txt")
        
        // Test empty window name with forced title
        let emptyNameWindow = KeyAssignmentManager.createMockWindowInfo(
            name: "",
            owner: "TextEdit",
            forceShowTitle: true
        )
        #expect(emptyNameWindow.displayName == "TextEdit")
    }
    
    @Test("Generate mock windows")
    func generateMockWindows() async throws {
        let windows = KeyAssignmentManager.generateMockWindows()
        
        // Should generate a reasonable number of test windows
        #expect(windows.count >= 15)
        #expect(windows.count <= 25)
        
        // All windows should have valid IDs
        #expect(windows.allSatisfy { $0.id > 0 })
        
        // Should have variety in window types
        let hasActiveWindow = windows.contains { $0.isActive }
        let hasForcedTitle = windows.contains { $0.forceShowTitle }
        let hasEmptyName = windows.contains { $0.name.isEmpty }
        
        #expect(hasActiveWindow)
        #expect(hasForcedTitle)
        #expect(hasEmptyName)
        
        // Should have diverse app names for testing conflicts
        let uniqueOwners = Set(windows.map { $0.owner })
        #expect(uniqueOwners.count >= 10) // At least 10 different "apps"
    }
    
    @Test("Window equality")
    func windowEquality() async throws {
        let window1 = KeyAssignmentManager.createMockWindowInfo(
            id: 1001,
            name: "Test",
            owner: "App"
        )
        
        let window2 = KeyAssignmentManager.createMockWindowInfo(
            id: 1001,
            name: "Test",
            owner: "App"
        )
        
        let window3 = KeyAssignmentManager.createMockWindowInfo(
            id: 1002,
            name: "Test",
            owner: "App"
        )
        
        // Same ID, name, and owner should be equal
        #expect(window1 == window2)
        
        // Different ID should not be equal
        #expect(window1 != window3)
    }
}