//
//  KeyboardSwitcher.swift
//  Bar
//
//  Created by Samuel DeSota on 1/7/25.
//

import Foundation
import AppKit
import Carbon

class KeyboardSwitcher: ObservableObject {
    static let shared = KeyboardSwitcher()
    
    @Published var isActive: Bool = false
    @Published var isSwitchingMode: Bool = false
    @Published var availableWindows: [WindowInfo] = []
    @Published var lastError: String?
    
    private let logger = Logger.shared
    private let permissionManager = KeyboardPermissionManager.shared
    private let keyAssignmentManager = KeyAssignmentManager.shared
    
    // Window management integration
    private weak var windowManager: WindowManager?
    
    // Event monitoring
    private var globalKeyDownMonitor: Any?
    private var globalKeyUpMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var localKeyUpMonitor: Any?
    
    // Switching mode keystroke monitoring
    private var switchingModeKeyMonitor: Any?
    
    // Event tap for capturing keystrokes during switching mode
    private var eventTap: CFMachPort?
    
    // Command key tracking
    private var commandKeyDownTime: Date?
    private var isCommandKeyDown: Bool = false
    private var isModifierCombination: Bool = false
    
    // Switching mode
    private var switchingModeTimer: Timer?
    
    // Constants
    private let maxCommandKeyTapDuration: TimeInterval = 0.2 // 200ms
    private let switchingModeTimeout: TimeInterval = 3.0 // 3 seconds
    
    private init() {
        logger.info("KeyboardSwitcher initialized", category: .keyboardSwitching)
    }
    
    /// Connect to WindowManager for real window data and activation
    func connectWindowManager(_ windowManager: WindowManager) {
        self.windowManager = windowManager
        logger.info("WindowManager connected to KeyboardSwitcher", category: .keyboardSwitching)
    }
    
    deinit {
        stop()
    }
    
    /// Start keyboard monitoring
    func start() {
        guard !isActive else {
            logger.warning("KeyboardSwitcher already active", category: .keyboardSwitching)
            return
        }
        
        guard permissionManager.hasAllRequiredPermissions else {
            logger.error("Missing required permissions for keyboard switching", category: .keyboardSwitching)
            return
        }
        
        logger.info("Starting KeyboardSwitcher", category: .keyboardSwitching)
        
        startGlobalKeyMonitoring()
        startLocalKeyMonitoring()
        
        isActive = true
        logger.info("KeyboardSwitcher started successfully", category: .keyboardSwitching)
    }
    
    /// Stop keyboard monitoring
    func stop() {
        guard isActive else {
            logger.debug("KeyboardSwitcher already inactive", category: .keyboardSwitching)
            return
        }
        
        logger.info("Stopping KeyboardSwitcher", category: .keyboardSwitching)
        
        stopGlobalKeyMonitoring()
        stopLocalKeyMonitoring()
        stopSwitchingModeKeyMonitoring()
        destroyEventTap()
        deactivateSwitchingMode()
        
        isActive = false
        logger.info("KeyboardSwitcher stopped", category: .keyboardSwitching)
    }
    
    // MARK: - Global Key Monitoring
    
    private func startGlobalKeyMonitoring() {
        logger.debug("Setting up global key monitoring", category: .keyboardSwitching)
        
        // Monitor key down events globally
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleGlobalKeyEvent(event, isKeyDown: true)
        }
        
        // Monitor key up events globally  
        globalKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp, .flagsChanged]) { [weak self] event in
            self?.handleGlobalKeyEvent(event, isKeyDown: false)
        }
        
        if globalKeyDownMonitor != nil && globalKeyUpMonitor != nil {
            logger.info("Global key monitoring established", category: .keyboardSwitching)
        } else {
            logger.error("Failed to establish global key monitoring", category: .keyboardSwitching)
        }
    }
    
    private func stopGlobalKeyMonitoring() {
        if let monitor = globalKeyDownMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyDownMonitor = nil
            logger.debug("Removed global key down monitor", category: .keyboardSwitching)
        }
        
        if let monitor = globalKeyUpMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyUpMonitor = nil
            logger.debug("Removed global key up monitor", category: .keyboardSwitching)
        }
    }
    
    // MARK: - Local Key Monitoring
    
    private func startLocalKeyMonitoring() {
        logger.debug("Setting up local key monitoring", category: .keyboardSwitching)
        
        // Monitor local key events to catch command combinations
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleLocalKeyEvent(event, isKeyDown: true)
            return event // Pass through the event
        }
        
        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .flagsChanged]) { [weak self] event in
            self?.handleLocalKeyEvent(event, isKeyDown: false)
            return event // Pass through the event
        }
        
        logger.info("Local key monitoring established", category: .keyboardSwitching)
    }
    
    private func stopLocalKeyMonitoring() {
        if let monitor = localKeyDownMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyDownMonitor = nil
            logger.debug("Removed local key down monitor", category: .keyboardSwitching)
        }
        
        if let monitor = localKeyUpMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyUpMonitor = nil
            logger.debug("Removed local key up monitor", category: .keyboardSwitching)
        }
    }
    
    // MARK: - Event Handling
    
    private func handleGlobalKeyEvent(_ event: NSEvent, isKeyDown: Bool) {
        handleKeyEvent(event, isKeyDown: isKeyDown, isGlobal: true)
    }
    
    private func handleLocalKeyEvent(_ event: NSEvent, isKeyDown: Bool) {
        handleKeyEvent(event, isKeyDown: isKeyDown, isGlobal: false)
    }
    
    private func handleKeyEvent(_ event: NSEvent, isKeyDown: Bool, isGlobal: Bool) {
        let scope = isGlobal ? "GLOBAL" : "LOCAL"
        
        if event.type == .flagsChanged {
            handleModifierKeyEvent(event, scope: scope)
        } else if event.type == .keyDown || event.type == .keyUp {
            handleRegularKeyEvent(event, isKeyDown: isKeyDown, scope: scope)
        }
    }
    
    private func handleModifierKeyEvent(_ event: NSEvent, scope: String) {
        let flags = event.modifierFlags
        let isCommandPressed = flags.contains(.command)
        
        // Check for command key state change
        if isCommandPressed != isCommandKeyDown {
            if isCommandPressed {
                handleCommandKeyDown(scope: scope)
            } else {
                handleCommandKeyUp(scope: scope)
            }
        }
    }
    
    private func handleRegularKeyEvent(_ event: NSEvent, isKeyDown: Bool, scope: String) {
        if isKeyDown && isCommandKeyDown {
            // Command key is down and another key was pressed - this is a combination
            let keyCode = event.keyCode
            let keyName = keyCodeToString(keyCode)
            
            logger.debug("Command combination detected: Cmd+\(keyName) [\(scope)]", category: .keyboardSwitching)
            isModifierCombination = true
        }
    }
    
    // MARK: - Command Key Handling
    
    private func handleCommandKeyDown(scope: String) {
        guard !isCommandKeyDown else { return }
        
        logger.debug("Command key DOWN [\(scope)]", category: .keyboardSwitching)
        
        isCommandKeyDown = true
        isModifierCombination = false
        commandKeyDownTime = Date()
        
        logger.debug("Command key press started at \(commandKeyDownTime!)", category: .keyboardSwitching)
    }
    
    private func handleCommandKeyUp(scope: String) {
        guard isCommandKeyDown else { return }
        
        logger.debug("Command key UP [\(scope)]", category: .keyboardSwitching)
        
        isCommandKeyDown = false
        
        guard let downTime = commandKeyDownTime else {
            logger.warning("Command key up without recorded down time", category: .keyboardSwitching)
            return
        }
        
        let pressDuration = Date().timeIntervalSince(downTime)
        commandKeyDownTime = nil
        
        logger.debug("Command key press duration: \(String(format: "%.3f", pressDuration * 1000))ms", category: .keyboardSwitching)
        
        // Check if this was a short tap without other keys
        if !isModifierCombination && pressDuration <= maxCommandKeyTapDuration {
            logger.info("Command key tap detected! Duration: \(String(format: "%.3f", pressDuration * 1000))ms", category: .keyboardSwitching)
            activateSwitchingMode()
        } else if isModifierCombination {
            logger.debug("Ignoring command key release - was part of combination", category: .keyboardSwitching)
        } else {
            logger.debug("Command key press too long (\(String(format: "%.3f", pressDuration * 1000))ms) - ignoring", category: .keyboardSwitching)
        }
        
        isModifierCombination = false
    }
    
    // MARK: - Switching Mode
    
    private func activateSwitchingMode() {
        guard !isSwitchingMode else {
            logger.debug("Switching mode already active - extending timeout", category: .keyboardSwitching)
            resetSwitchingModeTimer()
            return
        }
        
        logger.info("🎯 ACTIVATING SWITCHING MODE", category: .keyboardSwitching)
        
        // Update window list and assign keys
        updateWindowListAndAssignKeys()
        
        // Start monitoring keystrokes during switching mode
        createEventTap()
        startSwitchingModeKeyMonitoring()
        
        DispatchQueue.main.async {
            self.isSwitchingMode = true
            self.lastError = nil
        }
        
        resetSwitchingModeTimer()
    }
    
    private func deactivateSwitchingMode() {
        guard isSwitchingMode else { return }
        
        logger.info("⏹️ DEACTIVATING SWITCHING MODE", category: .keyboardSwitching)
        
        // Stop keystroke monitoring and destroy event tap
        stopSwitchingModeKeyMonitoring()
        destroyEventTap()
        
        DispatchQueue.main.async {
            self.isSwitchingMode = false
        }
        
        switchingModeTimer?.invalidate()
        switchingModeTimer = nil
    }
    
    private func resetSwitchingModeTimer() {
        switchingModeTimer?.invalidate()
        
        switchingModeTimer = Timer.scheduledTimer(withTimeInterval: switchingModeTimeout, repeats: false) { [weak self] _ in
            self?.logger.info("⏰ Switching mode timeout reached", category: .keyboardSwitching)
            self?.deactivateSwitchingMode()
        }
        
        logger.debug("Switching mode timer set for \(switchingModeTimeout) seconds", category: .keyboardSwitching)
    }
    
    // MARK: - Window Management
    
    /// Update window list and assign keys
    private func updateWindowListAndAssignKeys() {
        let windows: [WindowInfo]
        
        // Use real window data if WindowManager is connected, otherwise use mock data for testing
        if let windowManager = windowManager {
            windows = windowManager.getWindowsForCurrentSpace()
            logger.info("Using real window data: \(windows.count) windows", category: .keyboardSwitching)
        } else {
            windows = KeyAssignmentManager.generateMockWindows()
            logger.info("Using mock window data: \(windows.count) windows", category: .keyboardSwitching)
        }
        
        DispatchQueue.main.async {
            self.availableWindows = windows
        }
        
        // Assign keys to windows
        keyAssignmentManager.assignKeys(to: windows)
        
        // Log the assignments
        logger.info("Key assignments for \(windows.count) windows:", category: .keyboardSwitching)
        
        for window in windows {
            if let key = keyAssignmentManager.getKey(for: window.id) {
                logger.info("  '\(key)' → \(window.displayName) (\(window.owner))", category: .keyboardSwitching)
            }
        }
    }
    
    /// Get window for a pressed key
    func getWindow(for key: String) -> WindowInfo? {
        guard let windowID = keyAssignmentManager.getWindowID(for: key) else {
            return nil
        }
        
        return availableWindows.first { $0.id == windowID }
    }
    
    /// Get all current key assignments
    func getKeyAssignments() -> [CGWindowID: String] {
        return keyAssignmentManager.getAllAssignments()
    }
    
    // MARK: - Testing Support
    
    /// Generate test windows for development/debugging
    func generateTestWindows() -> [WindowInfo] {
        return KeyAssignmentManager.generateMockWindows()
    }
    
    // MARK: - Switching Mode Key Monitoring
    
    /// Create CGEvent tap to capture input system-wide
    private func createEventTap() {
        // Create the event tap - capture all keyboard events to prevent them from reaching other apps during switching mode
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                       (1 << CGEventType.keyUp.rawValue) |
                       (1 << CGEventType.flagsChanged.rawValue)
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                // Get the KeyboardSwitcher instance from refcon
                let keyboardSwitcher = Unmanaged<KeyboardSwitcher>.fromOpaque(refcon!).takeUnretainedValue()
                return keyboardSwitcher.handleEventTapCallback(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let eventTap = eventTap else {
            logger.error("Failed to create CGEvent tap - accessibility permissions may be required", category: .keyboardSwitching)
            return
        }
        
        // Enable the event tap
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        // Add to run loop
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        logger.info("CGEvent tap created and activated for input capture", category: .keyboardSwitching)
    }
    
    /// Destroy the CGEvent tap
    private func destroyEventTap() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            logger.debug("CGEvent tap destroyed", category: .keyboardSwitching)
        }
    }
    
    /// Handle CGEvent tap callback for keystroke processing
    private func handleEventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Only process if we're in switching mode
        guard isSwitchingMode else {
            return Unmanaged.passUnretained(event) // Pass through
        }
        
        // During switching mode, consume ALL keyboard events to prevent other apps from receiving them
        switch type {
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            
            // Convert to NSEvent for compatibility with existing handling
            let nsEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: NSPoint.zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: UInt16(keyCode)
            )
            
            if let nsEvent = nsEvent {
                handleSwitchingModeKeystroke(nsEvent)
            }
            
        case .keyUp:
            // Log keyUp events but don't process them for switching logic
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            logger.debug("Consuming keyUp event during switching mode: keyCode \(keyCode)", category: .keyboardSwitching)
            
        case .flagsChanged:
            // Log modifier changes but don't process them for switching logic
            let flags = event.flags
            logger.debug("Consuming flagsChanged event during switching mode: flags \(flags)", category: .keyboardSwitching)
            
        default:
            logger.debug("Consuming other keyboard event during switching mode: type \(type)", category: .keyboardSwitching)
        }
        
        // Consume ALL keyboard events (return nil) to prevent them from reaching other applications
        return nil
    }
    
    /// Start monitoring keystrokes during switching mode
    private func startSwitchingModeKeyMonitoring() {
        logger.debug("Starting switching mode keystroke monitoring", category: .keyboardSwitching)
        
        // Note: We now rely primarily on the input capture window for key events
        // This global monitor serves as a backup and for logging
        switchingModeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // Global monitor - this won't consume events but helps with logging
            self?.logger.debug("Global monitor detected key during switching mode: \(event.keyCode)", category: .keyboardSwitching)
        }
        
        if switchingModeKeyMonitor != nil {
            logger.info("Switching mode global monitoring active", category: .keyboardSwitching)
        } else {
            logger.warning("Failed to start global keystroke monitoring", category: .keyboardSwitching)
        }
    }
    
    /// Stop monitoring keystrokes during switching mode
    private func stopSwitchingModeKeyMonitoring() {
        if let monitor = switchingModeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            switchingModeKeyMonitor = nil
            logger.debug("Stopped switching mode keystroke monitoring", category: .keyboardSwitching)
        }
    }
    
    /// Handle keystroke during switching mode
    private func handleSwitchingModeKeystroke(_ event: NSEvent) {
        let keyString = keyCodeToCharacter(event.keyCode)
        let modifierFlags = event.modifierFlags
        
        logger.debug("Switching mode keystroke: '\(keyString)' (keyCode: \(event.keyCode))", category: .keyboardSwitching)
        
        // Filter out system shortcuts and modifiers
        if shouldIgnoreKeystroke(keyString: keyString, modifierFlags: modifierFlags, keyCode: event.keyCode) {
            logger.debug("Ignoring keystroke: '\(keyString)' (system shortcut or modifier)", category: .keyboardSwitching)
            deactivateSwitchingMode()
            return
        }
        
        // Try to activate window for this key
        if let window = getWindow(for: keyString.lowercased()) {
            logger.info("🎯 Activating window for key '\(keyString)': \(window.displayName) (\(window.owner))", category: .keyboardSwitching)
            activateWindow(window)
            deactivateSwitchingMode()
        } else {
            logger.debug("No window mapped to key '\(keyString)'", category: .keyboardSwitching)
            // Don't deactivate immediately - user might press another key
            // The timer will handle deactivation if no valid key is pressed
        }
    }
    
    /// Determine if a keystroke should be ignored during switching mode
    private func shouldIgnoreKeystroke(keyString: String, modifierFlags: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool {
        // Ignore if any significant modifier keys are pressed (except Shift for capital letters)
        let significantModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        if !modifierFlags.intersection(significantModifiers).isEmpty {
            logger.debug("Ignoring keystroke with modifiers: \(modifierFlags)", category: .keyboardSwitching)
            return true
        }
        
        // Ignore function keys and special keys
        if keyCode >= 122 && keyCode <= 135 { // F1-F12 and other function keys
            logger.debug("Ignoring function key: \(keyCode)", category: .keyboardSwitching)
            return true
        }
        
        // Ignore arrow keys, delete, escape, etc.
        let systemKeyCodes: Set<UInt16> = [
            51,  // Delete
            53,  // Escape
            123, 124, 125, 126, // Arrow keys
            115, 116, 117, 119, 121, // Home, Page Up, Delete, End, Page Down
            71,  // Clear
            76,  // Enter (numeric keypad)
            36,  // Return
            48,  // Tab
        ]
        
        if systemKeyCodes.contains(keyCode) {
            logger.debug("Ignoring system key: \(keyCode)", category: .keyboardSwitching)
            return true
        }
        
        return false
    }
    
    /// Activate a window through WindowManager or fallback method
    private func activateWindow(_ window: WindowInfo) {
        if let windowManager = windowManager {
            // Use connected WindowManager for activation
            logger.info("Activating window via WindowManager: \(window.displayName)", category: .keyboardSwitching)
            windowManager.activateWindow(window)
        } else {
            // Fallback activation method for testing
            logger.info("Activating window via fallback method: \(window.displayName)", category: .keyboardSwitching)
            activateWindowFallback(window)
        }
    }
    
    /// Fallback window activation method
    private func activateWindowFallback(_ window: WindowInfo) {
        // Try to find and activate the application
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == window.owner }) {
            app.activate()
            logger.info("Successfully activated app via fallback: \(window.owner)", category: .keyboardSwitching)
        } else {
            logger.warning("Could not find app for fallback activation: \(window.owner)", category: .keyboardSwitching)
            DispatchQueue.main.async {
                self.lastError = "Could not activate window: \(window.displayName)"
            }
        }
    }
    
    // MARK: - Utilities
    
    /// Convert key code to character for switching mode
    private func keyCodeToCharacter(_ keyCode: UInt16) -> String {
        // Convert to lowercase for consistent matching
        return keyCodeToString(keyCode).lowercased()
    }
    
    private func keyCodeToString(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "RETURN"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "TAB"
        case 49: return "SPACE"
        case 50: return "`"
        case 51: return "DELETE"
        case 53: return "ESCAPE"
        default: return "KEY_\(keyCode)"
        }
    }
}

