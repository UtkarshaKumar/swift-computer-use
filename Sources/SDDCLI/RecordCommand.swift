import ArgumentParser
import AppKit
import ApplicationServices
import Foundation
import SDDCore

/// `sdd record "<task>"`
/// Activates the DemonstrationRecorder to listen to physical user interactions
/// and log them as LearnedRules natively into SQLite.
struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Start a global recording session to physically demonstrate a task"
    )

    @Argument(help: "Logical name of the task you are demonstrating (e.g. 'Apply on LinkedIn')")
    var taskName: String

    func run() async throws {
        // 1. Accessibility permission check — required to monitor global events
        let opts = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            print("Error: Global User Recording requires Accessibility permissions.")
            print("Please grant it: System Settings -> Privacy & Security -> Accessibility -> Add Terminal")
            throw ExitCode.failure
        }

        print("\n[SDD Recorder] Starting demonstration session for: '\(taskName)'")
        print("[SDD Recorder] ----------------------------------------------------")
        print("  - Perform your task normally on the screen.")
        print("  - SDD will silently intercept your clicks & typing and convert them into SQLite FastBrain rules.")
        print("  - Press Ctrl+C in this terminal when finished.")
        print("----------------------------------------------------\n")

        // 2. Start the recorder on the MainActor
        await MainActor.run {
            NSApplication.shared.setActivationPolicy(.accessory)
            
            let recorder = DemonstrationRecorder()
            var extractedCount = 0
            
            recorder.onRuleExtracted = { rule in
                extractedCount += 1
                print("[\(extractedCount)] Captured: \(rule.intentType) on '\(rule.elementLabelPattern)'")
                LearnedRulesStore.shared.append(rule)
            }
            
            recorder.startRecording(taskGoal: self.taskName)
        }

        // Keep the runloop alive manually until Ctrl+C
        // NSApplication.shared.run() would block, but we are inside an async context.
        // We'll just loop and wait.
        while true {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                break
            }
        }
    }
}
