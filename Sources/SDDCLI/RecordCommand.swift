import ArgumentParser
import AppKit
import ApplicationServices
import Foundation
import SDDCore

/// `sdd record "<task>"`
/// Activates the DemonstrationRecorder to listen to physical user interactions
/// and logs them as LearnedRules natively into SQLite.
///
/// The recorder is kept alive as a static reference so it is not deallocated
/// when the MainActor.run block returns. NSRunLoop.main is pumped in a loop
/// so that NSEvent global monitors receive events (Swift async Task.sleep does
/// NOT pump NSRunLoop — monitors silently never fire without this).
struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Start a global recording session to physically demonstrate a task"
    )

    @Argument(help: "Logical name of the task you are demonstrating (e.g. 'Apply on LinkedIn')")
    var taskName: String

    /// Kept alive for the duration of the recording session.
    /// Must be nonisolated(unsafe) static so the MainActor.run closure can
    /// store a strong reference that outlives the block.
    nonisolated(unsafe) static var activeRecorder: DemonstrationRecorder?

    /// Helper: Extract action type and value from a LearnedRule.
    private func extractActionTypeAndValue(_ rule: LearnedRule) -> (String, String) {
        switch rule.resolvedAction {
        case .press:
            return ("press", "")
        case .setValue(_, _, let value):
            return ("setValue", value)
        case .scroll(_, _, let direction, let amount):
            return ("scroll", "\(direction):\(amount)")
        }
    }

    func run() async throws {
        // 1. Accessibility permission check — required to monitor global events
        let opts = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            print("Error: Global User Recording requires Accessibility permissions.")
            print("Grant it: System Settings -> Privacy & Security -> Accessibility -> add your terminal")
            throw ExitCode.failure
        }

        print("\n[SDD Recorder] Starting demonstration session for: '\(taskName)'")
        print("[SDD Recorder] ------------------------------------------------")
        print("  Perform your task normally on screen.")
        print("  SDD watches clicks & typing and converts them into FastBrain rules.")
        print("  Press Ctrl+C when finished.")
        print("------------------------------------------------\n")

        // 2. Configure NSApplication so the process can receive global NSEvents.
        //    setActivationPolicy must run on MainActor.
        await MainActor.run {
            NSApplication.shared.setActivationPolicy(.accessory)
        }

        // 3. Build the recorder, wire the callback, and start it.
        //    Store it in the static so it is not deallocated after this scope.
        var extractedCount = 0
        let extractedRulesQueue = DispatchQueue(label: "com.sdd.extracted-rules")
        nonisolated(unsafe) var extractedRules = [LearnedRule]()

        let recorder = await MainActor.run { () -> DemonstrationRecorder in
            let r = DemonstrationRecorder()
            r.onRuleExtracted = { rule in
                extractedCount += 1
                print("[\(extractedCount)] Captured \(rule.intentType.rawValue) on '\(rule.elementLabelPattern)'")
                extractedRulesQueue.sync {
                    extractedRules.append(rule)
                }
                LearnedRulesStore.shared.append(rule)
            }
            r.startRecording(taskGoal: self.taskName)
            return r
        }
        RecordCommand.activeRecorder = recorder

        // 4. Pump NSRunLoop.main so that NSEvent global monitors receive events.
        //    Swift Task.sleep operates on the cooperative thread pool and does NOT
        //    service NSRunLoop — monitors will silently drop all events without this loop.
        //    RunLoop.main.run(until:) returns control every second, letting us check
        //    for Task cancellation (Ctrl+C triggers a CancellationError).
        while !Task.isCancelled {
            await MainActor.run {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
            }
        }

        // 5. Graceful shutdown
        await MainActor.run {
            recorder.stopRecording()
        }
        RecordCommand.activeRecorder = nil

        // 6. Convert extracted rules to workflow steps and save as a LearnedWorkflow
        let workflowSteps = extractedRulesQueue.sync {
            extractedRules.enumerated().map { (index, rule) -> LearnedWorkflowStep in
                let (actionType, actionValue) = extractActionTypeAndValue(rule)
                return LearnedWorkflowStep(
                    stepIndex: index,
                    elementRole: rule.elementRole,
                    elementLabel: rule.elementLabelPattern,
                    action: actionType,
                    value: actionValue,
                    bundleID: rule.targetBundleID
                )
            }
        }

        if !workflowSteps.isEmpty {
            let workflow = LearnedWorkflow(
                name: self.taskName,
                goal: self.taskName,
                steps: workflowSteps,
                createdAt: Date(),
                successCount: 1
            )
            try? LearnedRulesStore.shared.saveWorkflow(workflow)
            print("[SDD Recorder] Workflow '\(self.taskName)' saved with \(workflowSteps.count) steps")
        }

        print("\n[SDD Recorder] Session ended. Rules saved to ~/.sdd/learned-rules.db")
    }
}
