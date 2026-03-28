import ArgumentParser
import AppKit
import ApplicationServices
import Foundation
import SDDCore
import SDDBrain

/// `sdd run "<goal>"` — self-contained computer-use driver.
///
/// Creates its own WorldModel + AXObserver + FastBrain + SlowBrain + TaskOrchestrator
/// and runs the step loop until the goal is complete or max-steps is reached.
///
/// Example:
///   sdd run "apply for this job on LinkedIn with my resume at ~/Documents/resume.pdf" \
///           --api-key sk-ant-... \
///           --max-steps 30
struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a computer-use goal against the current screen state"
    )

    @Argument(help: "High-level goal to accomplish (e.g. 'apply for job on LinkedIn')")
    var goal: String

    @Option(name: .long, help: "Anthropic API key (defaults to ANTHROPIC_API_KEY env var)")
    var apiKey: String?

    @Option(name: .long, help: "Maximum number of action steps before giving up (default: 30)")
    var maxSteps: Int = 30

    @Option(name: .long, help: "FastBrain confidence threshold 0.0–1.0 (default: 0.85)")
    var confidence: Double = 0.85

    func run() async throws {
        // 1. Accessibility permission check — never prompt from CLI
        let opts = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            print("Error: Accessibility permission required.")
            print("Grant it: System Settings -> Privacy & Security -> Accessibility -> add your terminal")
            throw ExitCode.failure
        }

        // 2. NSApplication run loop required for AXObserver callbacks
        await MainActor.run {
            NSApplication.shared.setActivationPolicy(.accessory)
        }

        // 3. Resolve API key
        let resolvedKey = apiKey ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        if resolvedKey == nil {
            print("Warning: No API key provided. Set ANTHROPIC_API_KEY or pass --api-key.")
        }

        // 4. Load learned rules
        let learnedRules = LearnedRulesStore.shared.load()
        print("Loaded \(learnedRules.count) learned rule(s).")

        // 5. Build pipeline
        let worldModel = WorldModel()
        let fastBrain = FastBrain(confidenceThreshold: confidence, learnedRules: learnedRules)
        let slowBrain = SlowBrainRouter(config: .init(
            provider: .claude,
            apiKey: resolvedKey
        ))
        let executor = AXActionExecutor()

        // 6. Wire AXObserver -> WorldModel
        let manager = AXObserverManager()
        manager.eventHandler = { event in
            worldModel.apply(event: event)
        }
        manager.start()

        // 7. Warm-up: let the AX tree populate
        print("Observing screen (2s warm-up)...")
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let snapshot = worldModel.makeFBSnapshot()
        print("Screen state: \(snapshot.elements.count) element(s) visible in '\(snapshot.appContext.bundleID)'")

        // 8. Run orchestrator
        print("Goal: \(goal)")
        print("Running (max \(maxSteps) steps, confidence threshold \(confidence))...")

        let orchestrator = TaskOrchestrator(
            fastBrain: fastBrain,
            slowBrain: slowBrain,
            executor: executor,
            worldModel: worldModel
        )

        let result = try await orchestrator.run(goal: goal, maxSteps: maxSteps)

        // 9. Report outcome
        if result.succeeded {
            print("Done: completed in \(result.stepsExecuted) step(s). \(result.reason)")
        } else {
            print("Failed: \(result.reason) (\(result.stepsExecuted) step(s) executed)")
            throw ExitCode.failure
        }
    }
}
