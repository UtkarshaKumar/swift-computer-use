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

    @Option(name: .long, help: "LLM model name (default: claude-haiku-4-5-20251001 for Claude, gpt-4o-mini for OpenAI)")
    var model: String?

    @Option(name: .long, help: "LLM provider: claude (default) or openai")
    var provider: String = "claude"

    @Option(name: .long, help: "Custom LLM endpoint URL (for opencode, Ollama, or any OpenAI-compatible API)")
    var endpoint: String?

    @Option(name: .long, help: "Maximum number of action steps before giving up (default: 30)")
    var maxSteps: Int = 30

    @Option(name: .long, help: "FastBrain confidence threshold 0.0–1.0 (default: 0.85)")
    var confidence: Double = 0.85

    @Option(name: .long, help: "Bundle ID of the app to focus on (e.g. com.google.Chrome). Activates the app before scanning.")
    var focusApp: String?

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

        let isOpenAI = provider.lowercased() == "openai"
        let envKey = isOpenAI ? "OPENAI_API_KEY" : "ANTHROPIC_API_KEY"
        let resolvedKey = apiKey ?? ProcessInfo.processInfo.environment[envKey]
        
        guard let resolvedKey else {
            print("Error: No \(isOpenAI ? "OpenAI" : "Anthropic") API key found.")
            print("Set \(envKey) in your environment or pass --api-key <key>")
            throw ExitCode.failure
        }

        // 4. Load learned rules
        let learnedRules = LearnedRulesStore.shared.load()
        print("Loaded \(learnedRules.count) learned rule(s).")

        // 5. Build pipeline
        let worldModel = WorldModel()
        let fastBrain = FastBrain(confidenceThreshold: confidence, learnedRules: learnedRules)

        let llmProvider: SlowBrainRouter.Provider = provider == "openai" ? .openAI : .claude
        let llmEndpoint: URL? = endpoint.flatMap { URL(string: $0) }
        let slowBrain = SlowBrainRouter(config: .init(
            provider: llmProvider,
            apiKey: resolvedKey as String,
            endpoint: llmEndpoint,
            model: model
        ))
        print("LLM: \(slowBrain.config.resolvedModel) via \(slowBrain.config.resolvedEndpoint.host ?? "?")")
        let executor = AXActionExecutor()

        // 6. Wire AXObserver -> WorldModel (MainActor: NSWorkspace + NSApplication need main thread)
        let (manager, runningPIDs) = await MainActor.run { () -> (AXObserverManager, [pid_t]) in
            let m = AXObserverManager()
            m.eventHandler = { event in
                worldModel.apply(event: event)
            }
            m.start()
            let pids = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { $0.processIdentifier }
            return (m, pids)
        }

        // 7a. If --focus-app is specified, activate that app before scanning so the AX
        //     focus and captureFocus() point at the right app (not the terminal).
        if let bundleID = focusApp {
            let activated = await MainActor.run { () -> Bool in
                guard let app = NSWorkspace.shared.runningApplications
                    .first(where: { $0.bundleIdentifier == bundleID }) else {
                    return false
                }
                return app.activate(options: [])
            }
            if activated {
                print("Activated \(bundleID) — waiting for focus...")
                try await Task.sleep(nanoseconds: 1_000_000_000)  // 1s for window to come forward
            } else {
                print("Warning: could not activate \(bundleID) — is it running?")
            }
        }

        // 7. Proactive AX scan — AX events only fire on changes. Running apps already have
        //    windows open; without a scan the WorldModel starts empty and stays empty.
        print("Scanning \(runningPIDs.count) running app(s)...")
        for pid in runningPIDs {
            worldModel.scanApp(pid: pid)
        }
        // drainScanQueue blocks until all scanApp dispatches finish
        worldModel.drainScanQueue()
        // Capture the globally focused element (which app/window is frontmost)
        worldModel.captureFocus()

        let snapshot = worldModel.makeFBSnapshot()
        print("Screen state: \(snapshot.elements.count) element(s) visible in '\(snapshot.appContext.bundleID)'")

        guard !snapshot.elements.isEmpty else {
            print("Error: Accessibility API returned 0 elements.")
            print("Make sure:")
            print("  1. The target app is open and visible on screen")
            print("  2. Terminal has Accessibility permission (System Settings → Privacy → Accessibility)")
            throw ExitCode.failure
        }

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
