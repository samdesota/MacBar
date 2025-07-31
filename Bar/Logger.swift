//
//  Logger.swift
//  Bar
//
//  Created by Samuel DeSota on 7/31/25.
//

import Foundation
import os.log

class Logger: ObservableObject {
    static let shared = Logger()
    
    enum LogCategory: String, CaseIterable {
        case windowManager = "WindowManager"
        case windowPositioning = "WindowPositioning"
        case accessibility = "Accessibility"
        case taskbar = "Taskbar"
        case general = "General"
        case debug = "Debug"
    }
    
    @Published var enabledCategories: Set<LogCategory> = []
    
    private let osLog = OSLog(subsystem: "com.bar.app", category: "Bar")
    
    private init() {
        // Enable accessibility and window positioning logging by default for debugging
        enabledCategories = []
    }
    
    func enableCategory(_ category: LogCategory) {
        enabledCategories.insert(category)
    }
    
    func disableCategory(_ category: LogCategory) {
        enabledCategories.remove(category)
    }
    
    func toggleCategory(_ category: LogCategory) {
        if enabledCategories.contains(category) {
            disableCategory(category)
        } else {
            enableCategory(category)
        }
    }
    
    func isEnabled(_ category: LogCategory) -> Bool {
        return enabledCategories.contains(category)
    }
    
    func log(_ message: String, category: LogCategory, level: OSLogType = .default) {
        guard isEnabled(category) else { return }
        
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] [\(category.rawValue)] \(message)"
        
        os_log("%{public}@", log: osLog, type: level, logMessage)
        print(logMessage)
    }
    
    func debug(_ message: String, category: LogCategory) {
        log(message, category: category, level: .debug)
    }
    
    func info(_ message: String, category: LogCategory) {
        log(message, category: category, level: .info)
    }
    
    func error(_ message: String, category: LogCategory) {
        log(message, category: category, level: .error)
    }
    
    func warning(_ message: String, category: LogCategory) {
        log(message, category: category, level: .fault)
    }
}

extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
} 