import Foundation
import ApplicationServices
import SDDCore

// MARK: - OrchestratorResult

public struct OrchestratorResult: Sendable {
    public let succeeded: Bool
    public let stepsExecuted: Int
    public let reason: String

    public init(succeeded: Bool, stepsExecuted: Int, reason: String) {
        self.succeeded = succeeded
        self.stepsExecuted = stepsExecuted
        self.reason = reason
    }
}

// MARK: - TaskOrchestrator

/// Drives the step-by-step execution loop for a high-level user goal.
///
/// Loop per step:
///   1. Get current FBSnapshot from WorldModel
///   2. Ask SlowBrain: given goal + screen state, what is the NEXT action?
///   3. Translate ActionPlan → TaskContext
///   4. FastBrain.evaluate — if confident, use resolved action; else execute directly
///   5. Dispatch via AXActionExecutor
///   6. Wait 50ms for WorldModel to reflect the change
///   7. Repeat until "done" signal or maxSteps reached
public actor TaskOrchestrator {

    private let fastBrain: FastBrain
    private let slowBrain: SlowBrainRouter
    private let executor: AXActionExecutor
    private let worldModel: WorldModel
    private let translator = ActionPlanTranslator()

    public init(
        fastBrain: FastBrain,
        slowBrain: SlowBrainRouter,
        executor: AXActionExecutor,
        worldModel: WorldModel
    ) {
        self.fastBrain = fastBrain
        self.slowBrain = slowBrain
        self.executor = executor
        self.worldModel = worldModel
    }

    // MARK: - Main loop

    public func run(goal: String, maxSteps: Int = 30) async throws -> OrchestratorResult {
        var stepCount = 0

        fputs("[orchestrator] Starting — goal: \(goal)\n", stderr)

        while stepCount < maxSteps {
            let snapshot = worldModel.makeFBSnapshot()

            // Ask SlowBrain for the next action
            let plans: [ActionPlan]
            do {
                plans = try await slowBrain.route(goal: goal, worldModel: worldModel)
            } catch {
                fputs("[orchestrator] SlowBrain error: \(error) — aborting\n", stderr)
                throw error
            }

            // Empty plan = goal complete
            if plans.isEmpty {
                return OrchestratorResult(
                    succeeded: true,
                    stepsExecuted: stepCount,
                    reason: "SlowBrain returned empty plan — goal complete"
                )
            }

            // Explicit "done" signal
            if let first = plans.first,
               first.action.lowercased() == "done" || first.action.lowercased() == "complete" {
                return OrchestratorResult(
                    succeeded: true,
                    stepsExecuted: stepCount,
                    reason: first.verifyCondition ?? "Goal completed"
                )
            }

            // Execute each step in the plan
            for plan in plans {
                guard stepCount < maxSteps else { break }

                fputs("[orchestrator] step \(stepCount + 1): \(plan.action) '\(plan.elementSelector)'"
                    + (plan.value.map { " value='\($0)'" } ?? "") + "\n", stderr)

                let task = translator.toTaskContext(plan)
                let result = fastBrain.evaluate(snapshot: snapshot, task: task)

                switch result {
                case .action(let resolvedAction, let conf):
                    fputs("[orchestrator]   fast-brain (conf=\(String(format: "%.2f", conf)))\n", stderr)
                    await executeResolved(resolvedAction, plan: plan)

                case .uncertain(let signal):
                    fputs("[orchestrator]   slow-path direct (\(signal.reason))\n", stderr)
                    await executeDirect(plan: plan)
                }

                stepCount += 1

                // Brief pause for WorldModel to catch up with AX changes
                try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            }
        }

        return OrchestratorResult(
            succeeded: false,
            stepsExecuted: stepCount,
            reason: "Max steps (\(maxSteps)) reached without completion signal"
        )
    }

    // MARK: - Execution helpers

    /// Execute a FastBrain-resolved action. Falls back to executeDirect if the
    /// live AX element can't be found by label + role.
    private func executeResolved(_ action: ResolvedAction, plan: ActionPlan) async {
        switch action {
        case .press(let el):
            guard let axRef = worldModel.axElement(for: el.label, role: el.role) else {
                fputs("[orchestrator]   axElement not found for '\(el.label)' — falling back\n", stderr)
                await executeDirect(plan: plan)
                return
            }
            let axEl = AXElement(axElement: axRef, label: el.label)
            _ = try? await executor.execute(.press, on: axEl)

        case .setValue(let el, let value):
            guard let axRef = worldModel.axElement(for: el.label, role: el.role) else {
                await executeDirect(plan: plan)
                return
            }
            let axEl = AXElement(axElement: axRef, label: el.label)
            _ = try? await executor.execute(.setValue(value), on: axEl)

        case .scroll(let el, let direction, _):
            // Scroll via keyboard shortcut — Page Down / Page Up
            let char: String
            switch direction {
            case .down:  char = " "   // Space = page down in most apps
            case .up:    char = " "
            case .left:  char = " "
            case .right: char = " "
            }
            guard let axRef = worldModel.axElement(for: el.label, role: el.role) else {
                await executeDirect(plan: plan)
                return
            }
            let axEl = AXElement(axElement: axRef, label: el.label)
            _ = try? await executor.execute(.keyboardShortcut(characters: char, modifiers: []), on: axEl)
        }
    }

    /// Direct execution from ActionPlan when FastBrain is uncertain.
    /// Resolves the element by label using WorldModel's live ref store.
    private func executeDirect(plan: ActionPlan) async {
        let selector = plan.elementSelector
        guard !selector.isEmpty else { return }

        switch plan.action.lowercased() {
        case "click", "press", "tap":
            guard let axRef = worldModel.axElement(for: selector, role: "") else {
                fputs("[orchestrator]   element not found: '\(selector)' — skipping step\n", stderr)
                return
            }
            let axEl = AXElement(axElement: axRef, label: selector)
            _ = try? await executor.execute(.press, on: axEl)

        case "type", "input", "fill", "enter":
            guard let value = plan.value, !value.isEmpty else { return }
            guard let axRef = worldModel.axElement(for: selector, role: "") else {
                fputs("[orchestrator]   text field not found: '\(selector)' — skipping step\n", stderr)
                return
            }
            let axEl = AXElement(axElement: axRef, label: selector)
            _ = try? await executor.execute(.setValue(value), on: axEl)

        case "scroll":
            // Use first available scrollable element
            let snapshot = worldModel.makeFBSnapshot()
            let scrollRoles = ["AXScrollArea", "AXWebArea", "AXList", "AXTable"]
            let scrollEl = snapshot.elements.first { scrollRoles.contains($0.role) }
            let scrollLabel = scrollEl?.label ?? ""
            let role = scrollEl?.role ?? ""
            guard let axRef = worldModel.axElement(for: scrollLabel, role: role) else { return }
            let axEl = AXElement(axElement: axRef, label: scrollLabel)
            _ = try? await executor.execute(.keyboardShortcut(characters: " ", modifiers: []), on: axEl)

        default:
            fputs("[orchestrator]   unknown action '\(plan.action)' — skipping\n", stderr)
        }
    }
}
