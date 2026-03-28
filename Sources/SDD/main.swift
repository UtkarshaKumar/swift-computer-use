import Foundation
import AppKit
import SDDCore
import SDDBrain

// ─────────────────────────────────────────────────────────────────
// Semantic Display Daemon — bootstrap
//
// Pipeline:
//   AXObserverManager  ─→  WorldModel.apply(event:)
//                              ├─→ diffs logged to stderr (dev mode)
//                              └─→ FBSnapshot built for FastBrain
//
// FastBrain → if confident → (ActionExecutor via gRPC, wired in next phase)
//           → if uncertain → SlowBrainRouter → LLM → action plan
//
// TaskContext source: supplied by gRPC server / CLI (Phase 2).
// Until then, the daemon runs as a pure sensor: events in, diffs out.
// ─────────────────────────────────────────────────────────────────

// MARK: - Accessibility permission check


let axOptions = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
guard AXIsProcessTrustedWithOptions(axOptions) else {
    fputs("sdd: Accessibility permission required. Grant in System Settings → Privacy → Accessibility.\n", stderr)
    exit(1)
}

// MARK: - NSApplication (required for NSWorkspace + AXObserver run loop)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // background daemon — no Dock icon

// MARK: - Load learned rules

let learnedRules = LearnedRulesStore.shared.load()
fputs("sdd: Loaded \(learnedRules.count) learned rule(s) from ~/.sdd/learned-rules.json\n", stderr)

// MARK: - Build the pipeline

let worldModel = WorldModel()

let fastBrain = FastBrain(
    confidenceThreshold: 0.85,
    learnedRules: learnedRules
)

let slowBrain = SlowBrainRouter(config: .init(
    provider: .claude,
    apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
    localOnly: ProcessInfo.processInfo.environment["SDD_LOCAL_ONLY"] == "1"
))

// MARK: - Subscribe: log every diff to stderr (dev mode sensor output)

let logToken = worldModel.subscribe { diff in
    let ts = ISO8601DateFormatter().string(from: diff.triggeringEvent.timestamp)
    let notification = diff.triggeringEvent.notification.rawValue
    var parts: [String] = ["[\(ts)] \(notification)"]
    if !diff.added.isEmpty   { parts.append("+\(diff.added.count) added") }
    if !diff.updated.isEmpty { parts.append("~\(diff.updated.count) updated") }
    if !diff.removed.isEmpty { parts.append("-\(diff.removed.count) removed") }
    if let fid = diff.focusedElementID { parts.append("focus=\(fid.rawValue)") }
    fputs(parts.joined(separator: " | ") + "\n", stderr)
}

// MARK: - Subscribe: FastBrain evaluation (sensor + react mode)
//
// TaskContext is not yet sourced from gRPC/CLI, so the brain is armed
// but not dispatching actions. Replace the placeholder with a real
// TaskContext source when gRPC server is connected (Phase 2).

let brainToken = worldModel.subscribe { diff in
    // TODO(Phase 2): replace placeholder with TaskContext from gRPC stream
    // let snapshot = worldModel.makeFBSnapshot()
    // let task = TaskContext(intent: .pressButton(label: "Submit"))
    // let result = fastBrain.evaluate(snapshot: snapshot, task: task)
    // switch result {
    // case .action(let action, let confidence):
    //     fputs("sdd: fast-brain action (conf=\(confidence)): \(action)\n", stderr)
    // case .uncertain(let signal):
    //     fputs("sdd: slow-brain escalation: \(signal.reason)\n", stderr)
    //     Task { try? await slowBrain.route(worldModel: ...) }
    // }
    _ = diff   // suppress unused warning until Phase 2
}

// Keep tokens alive for daemon lifetime
withExtendedLifetime([logToken, brainToken]) {}

// MARK: - Wire: AXObserver → WorldModel

let manager = AXObserverManager()
manager.eventHandler = { event in
    worldModel.apply(event: event)
}

// MARK: - Start

manager.start()
fputs("sdd: daemon running (pid=\(ProcessInfo.processInfo.processIdentifier))\n", stderr)

RunLoop.main.run()
