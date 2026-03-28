import ArgumentParser
import Foundation
import SDDCore

struct LogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "Manage action logs",
        subcommands: [TailCommand.self, ListCommand.self, ShowCommand.self],
        defaultSubcommand: nil
    )
}

struct TailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tail",
        abstract: "Stream the last N log entries"
    )
    
    @Option(name: .shortAndLong, help: "Number of entries to show")
    var count: Int = 20
    
    @Option(name: .shortAndLong, help: "Date to show logs for (YYYY-MM-DD)")
    var date: String?
    
    @Flag(name: .shortAndLong, help: "Follow mode - continuously show new entries")
    var follow: Bool = false
    
    func run() async throws {
        let logger = ActionLogger.shared
        
        // Initialize logger
        try await logger.initialize()
        
        if follow {
            try await runFollowMode()
        } else {
            try await runStaticMode()
        }
    }
    
    private func runStaticMode() async throws {
        let logger = ActionLogger.shared
        
        if let date = date {
            // Show entries from specific date
            var entries: [ActionLog] = []
            for await entry in try await logger.streamEntries(from: date) {
                entries.append(entry)
            }
            
            // Show last N entries
            let startIndex = max(0, entries.count - count)
            for entry in entries[startIndex...] {
                print(formatLogEntry(entry))
            }
        } else {
            // Show recent entries from memory
            let entries = await logger.getRecentEntries(count: count)
            for entry in entries {
                print(formatLogEntry(entry))
            }
        }
    }
    
    private func runFollowMode() async throws {
        let logger = ActionLogger.shared
        
        // Show initial entries
        let initialEntries = await logger.getRecentEntries(count: count)
        for entry in initialEntries {
            print(formatLogEntry(entry))
        }
        
        // In a real implementation, this would subscribe to new log entries
        // For now, we poll the recent entries
        var lastCount = initialEntries.count
        
        while follow {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            let entries = await logger.getRecentEntries(count: count)
            if entries.count > lastCount {
                for i in lastCount..<entries.count {
                    print(formatLogEntry(entries[i]))
                }
                lastCount = entries.count
            }
        }
    }
    
    private func formatLogEntry(_ entry: ActionLog) -> String {
        let status = entry.success ? "✓" : "✗"
        let coords = entry.usedCoordinates ? " [COORDS]" : ""
        let error = entry.error != nil ? " ERROR: \(entry.error!)" : ""
        let element = entry.elementLabel ?? entry.elementId ?? "unknown"
        
        return "[\(entry.timestamp)] \(status) \(entry.actionType) on '\(element)' (\(entry.latencyMs)ms)\(coords)\(error)"
    }
}

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List available log files"
    )
    
    func run() async throws {
        let logger = ActionLogger.shared
        try await logger.initialize()
        
        let files = try await logger.listLogFiles()
        
        if files.isEmpty {
            print("No log files found")
            return
        }
        
        print("Available log files:")
        for file in files {
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let size = attributes?[.size] as? Int64 ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            print("  \(file.lastPathComponent) (\(sizeStr))")
        }
    }
}

struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show log file contents"
    )
    
    @Argument(help: "Date to show logs for (YYYY-MM-DD)")
    var date: String
    
    func run() async throws {
        let logger = ActionLogger.shared
        try await logger.initialize()
        
        var entries: [ActionLog] = []
        for await entry in try await logger.streamEntries(from: date) {
            entries.append(entry)
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        for entry in entries {
            if let data = try? encoder.encode(entry),
               let json = String(data: data, encoding: .utf8) {
                print(json)
                print("---")
            }
        }
    }
}