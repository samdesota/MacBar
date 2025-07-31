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
    
    private let logger = Logger.shared
    private let permissionManager = KeyboardPermissionManager.shared
    
    // Event monitoring
    private var globalKeyDownMonitor: Any?
    private var globalKeyUpMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var localKeyUpMonitor: Any?
    
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
        
        // Enable keyboard switching logging for testing
        logger.enableCategory(.keyboardSwitching)
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
        let eventType = isKeyDown ? "DOWN" : "UP"
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
        
        DispatchQueue.main.async {
            self.isSwitchingMode = true
        }
        
        resetSwitchingModeTimer()
    }
    
    private func deactivateSwitchingMode() {
        guard isSwitchingMode else { return }
        
        logger.info("⏹️ DEACTIVATING SWITCHING MODE", category: .keyboardSwitching)
        
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
    
    // MARK: - Utilities
    
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

