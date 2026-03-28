import Foundation

/// Manages action logging with daily rotation
public actor ActionLogger {
    public static let shared = ActionLogger()
    
    private let baseDirectory: URL
    private let fileManager: FileManager
    private var currentLogFile: URL?
    private var currentDate: String?
    private var fileHandle: FileHandle?
    
    /// Maximum number of entries to keep in memory for tail command
    private var recentEntries: [ActionLog] = []
    private let maxRecentEntries = 100
    
    public init(baseDirectory: URL? = nil) {
        self.fileManager = FileManager.default
        
        if let baseDirectory = baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let home = fileManager.homeDirectoryForCurrentUser
            self.baseDirectory = home.appendingPathComponent(".sdd", isDirectory: true)
        }
    }
    
    /// Initialize the logger and create base directory if needed
    public func initialize() throws {
        try createBaseDirectory()
    }
    
    /// Log an action entry
    public func log(_ entry: ActionLog) throws {
        // Ensure we have the correct log file for today
        let today = currentDateString()
        
        if currentDate != today {
            try rotateLogFile(for: today)
        }
        
        guard let fileHandle = fileHandle else {
            throw ActionLoggerError.logFileNotOpen
        }
        
        // Serialize to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(entry)
        
        // Write as JSONL (one JSON object per line)
        var lineData = data
        lineData.append(contentsOf: [0x0A]) // newline
        
        fileHandle.write(lineData)
        
        // Update recent entries buffer
        recentEntries.append(entry)
        if recentEntries.count > maxRecentEntries {
            recentEntries.removeFirst(recentEntries.count - maxRecentEntries)
        }
    }
    
    /// Get recent log entries (for tail command)
    public func getRecentEntries(count: Int = 20) -> [ActionLog] {
        let startIndex = max(0, recentEntries.count - count)
        return Array(recentEntries[startIndex...])
    }
    
    /// Stream log entries from a specific log file
    public func streamEntries(from date: String? = nil) throws -> AsyncStream<ActionLog> {
        let logFile: URL
        
        if let date = date {
            logFile = logFilePath(for: date)
        } else {
            logFile = currentLogFile ?? logFilePath(for: currentDateString())
        }
        
        guard fileManager.fileExists(atPath: logFile.path) else {
            throw ActionLoggerError.logFileNotFound(logFile.path)
        }
        
        return AsyncStream { continuation in
            Task {
                do {
                    let data = try Data(contentsOf: logFile)
                    let lines = data.split(separator: 0x0A)
                    
                    for line in lines {
                        if let logEntry = try? JSONDecoder().decode(ActionLog.self, from: Data(line)) {
                            continuation.yield(logEntry)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
        }
    }
    
    /// Get the current log file path
    public func currentLogFilePath() -> URL {
        return currentLogFile ?? logFilePath(for: currentDateString())
    }
    
    /// List all available log files
    public func listLogFiles() throws -> [URL] {
        let contents = try fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil
        )
        return contents.filter { $0.lastPathComponent.hasPrefix("action-log-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    
    // MARK: - Private Methods
    
    private func createBaseDirectory() throws {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try fileManager.createDirectory(
                at: baseDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }
    
    private func rotateLogFile(for date: String) throws {
        // Close existing file handle
        fileHandle?.closeFile()
        fileHandle = nil
        
        // Update current date
        currentDate = date
        
        // Create new log file path
        let logFile = logFilePath(for: date)
        currentLogFile = logFile
        
        // Create file if it doesn't exist
        if !fileManager.fileExists(atPath: logFile.path) {
            fileManager.createFile(atPath: logFile.path, contents: nil, attributes: nil)
        }
        
        // Open file handle for appending
        fileHandle = try FileHandle(forWritingTo: logFile)
        fileHandle?.seekToEndOfFile()
    }
    
    private func logFilePath(for date: String) -> URL {
        return baseDirectory.appendingPathComponent("action-log-\(date).jsonl")
    }
    
    private func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date())
    }
}

public enum ActionLoggerError: Error, CustomStringConvertible {
    case logFileNotOpen
    case logFileNotFound(String)
    
    public var description: String {
        switch self {
        case .logFileNotOpen:
            return "Log file is not open"
        case .logFileNotFound(let path):
            return "Log file not found: \(path)"
        }
    }
}