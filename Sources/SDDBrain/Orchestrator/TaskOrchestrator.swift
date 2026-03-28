import Foundation
import AppKit
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
/// Vision-first architecture:
///   1. Take a screenshot every step (via SlowBrain's routeWithVision)
///   2. Send screenshot + AX context + action history to LLM
///   3. LLM returns action with pixel coordinates
///   4. Execute via CGEvent click/type at those coordinates
///   5. Detect stuck loops (same action repeated 3+ times) and tell LLM to try differently
///   6. Repeat until "done" signal or maxSteps reached
public actor TaskOrchestrator {

    private let fastBrain: FastBrain
    private let slowBrain: SlowBrainRouter
    private let executor: AXActionExecutor
    private let worldModel: WorldModel
    private let translator = ActionPlanTranslator()
    private let vncClient: VNCClient?
    private let showUIClient: ShowUIClient?
    private let coordMapper: QuartzCoordinateMapper?

    /// Rolling action history — sent to LLM so it avoids repeating failed actions.
    private var actionHistory: [ActionPlan] = []

    /// Stuck detection threshold — if the same action signature repeats this many times,
    /// set the stuck flag in the LLM prompt.
    private let stuckThreshold = 3

    public init(
        fastBrain: FastBrain,
        slowBrain: SlowBrainRouter,
        executor: AXActionExecutor,
        worldModel: WorldModel,
        vncClient: VNCClient? = nil,
        showUIClient: ShowUIClient? = nil,
        coordMapper: QuartzCoordinateMapper? = nil
    ) {
        self.fastBrain = fastBrain
        self.slowBrain = slowBrain
        self.executor = executor
        self.worldModel = worldModel
        self.vncClient = vncClient
        self.showUIClient = showUIClient
        self.coordMapper = coordMapper
    }

    // MARK: - Feedback loop state

    private struct SDDRunState: Codable {
        var runID: String
        var goal: String
        var step: Int
        var maxSteps: Int
        var lastAction: LastAction?
        var elementCount: Int
        var stuck: Bool
        var status: String   // "running" | "abort" | "completed" | "failed"
        var updatedAt: Double

        struct LastAction: Codable {
            let action: String
            let elementSelector: String
            let x: Int?
            let y: Int?
        }
    }

    private let sddDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sdd")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Write current run state atomically to ~/.sdd/run-state.json.
    private func writeStatusFile(runID: String, goal: String, step: Int, maxSteps: Int,
                                  lastPlan: ActionPlan?, elementCount: Int, stuck: Bool, status: String) {
        let state = SDDRunState(
            runID: runID,
            goal: goal,
            step: step,
            maxSteps: maxSteps,
            lastAction: lastPlan.map {
                SDDRunState.LastAction(action: $0.action, elementSelector: $0.elementSelector, x: $0.x, y: $0.y)
            },
            elementCount: elementCount,
            stuck: stuck,
            status: status,
            updatedAt: Date().timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        let tmp = sddDir.appendingPathComponent("run-state.json.tmp")
        let dst = sddDir.appendingPathComponent("run-state.json")
        try? data.write(to: tmp, options: .atomic)
        try? FileManager.default.moveItem(at: tmp, to: dst)
    }

    /// Returns an override instruction if ~/.sdd/override.json exists and hasn't expired.
    /// Deletes the file after reading (consumed once).
    private func checkOverride() -> String? {
        let url = sddDir.appendingPathComponent("override.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let instruction = json["instruction"] as? String,
              let expiresAt = json["expires_at"] as? Double,
              Date().timeIntervalSince1970 < expiresAt
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        return instruction
    }

    /// Returns an intervene action plan if ~/.sdd/intervene.json exists.
    /// Deletes the file after reading (consumed once).
    private func checkIntervene() -> ActionPlan? {
        let url = sddDir.appendingPathComponent("intervene.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        let x = json["x"] as? Int
        let y = json["y"] as? Int
        let value = json["value"] as? String
        let selector = json["selector"] as? String ?? ""
        return ActionPlan(action: action, elementSelector: selector, value: value,
                          verifyCondition: nil, x: x, y: y)
    }

    /// Returns true if ~/.sdd/run-state.json has status == "abort".
    private func checkAbort() -> Bool {
        let url = sddDir.appendingPathComponent("run-state.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String
        else { return false }
        return status == "abort"
    }

    // MARK: - Main loop

    public func run(goal: String, maxSteps: Int = 30) async throws -> OrchestratorResult {
        let runID = UUID().uuidString
        var stepCount = 0
        var evalStuck = false
        var lastElementCount = 0

        fputs("[orchestrator] Starting — goal: \(goal)\n", stderr)

        while stepCount < maxSteps {
            // Check for abort signal from CLI/MCP
            if checkAbort() {
                fputs("[orchestrator] Abort signal received — stopping.\n", stderr)
                writeStatusFile(runID: runID, goal: goal, step: stepCount, maxSteps: maxSteps,
                                lastPlan: actionHistory.last, elementCount: worldModel.currentSnapshot.elements.count,
                                stuck: false, status: "abort")
                return OrchestratorResult(succeeded: false, stepsExecuted: stepCount, reason: "Aborted by user/MCP")
            }

            // Check for manual intervention action
            if let interventionPlan = checkIntervene() {
                fputs("[orchestrator] Intervention: \(interventionPlan.action) '\(interventionPlan.elementSelector)'\n", stderr)
                if let px = interventionPlan.x, let py = interventionPlan.y {
                    await executeVision(plan: interventionPlan, x: px, y: py)
                } else {
                    await executeDirect(plan: interventionPlan)
                }
                try await Task.sleep(nanoseconds: 500_000_000)
                await rescanFrontmostApp()
                continue
            }

            // Check for override instruction to inject into next LLM call
            let overrideInstruction = checkOverride()
            if let override = overrideInstruction {
                fputs("[orchestrator] Override injected: \(override.prefix(80))\n", stderr)
            }

            // Detect stuck state from action history and eval hash
            let stuck = isStuck() || evalStuck
            if stuck {
                fputs("[orchestrator] STUCK DETECTED — Teller LLM to try differently.\n", stderr)
            }
            lastElementCount = worldModel.currentSnapshot.elements.count

            // Ask SlowBrain for the next action — ALWAYS with screenshot (vision-first)
            // Retry on parsing failures (LLM sometimes returns non-JSON text)
            let plans: [ActionPlan]
            let historyCopy = actionHistory  // local copy for cross-isolation boundary
            let maxRetries = 2
            var lastError: Error?
            var parsedPlans: [ActionPlan]?

            for attempt in 0...maxRetries {
                do {
                    let effectiveGoal = overrideInstruction.map { "OVERRIDE INSTRUCTION (highest priority): \($0)\n\nOriginal goal: \(goal)" } ?? goal
                    parsedPlans = try await slowBrain.routeWithVision(
                        goal: effectiveGoal,
                        worldModel: worldModel,
                        actionHistory: historyCopy,
                        isStuck: stuck
                    )
                    break  // success
                } catch let error as SlowBrainError {
                    lastError = error
                    if case .parsingFailed = error, attempt < maxRetries {
                        fputs("[orchestrator] Parse error on attempt \(attempt + 1)/\(maxRetries + 1) — retrying...\n", stderr)
                        try await Task.sleep(nanoseconds: 500_000_000)
                        continue
                    }
                } catch {
                    // Network errors or other non-recoverable errors
                    fputs("[orchestrator] SlowBrain error: \(error) — aborting\n", stderr)
                    throw error
                }
            }

            guard let resolvedPlans = parsedPlans else {
                // All retries failed — skip this step and continue
                fputs("[orchestrator] All \(maxRetries + 1) attempts failed (\(lastError?.localizedDescription ?? "unknown")) — skipping step\n", stderr)
                stepCount += 1
                try await Task.sleep(nanoseconds: 1_000_000_000)  // wait 1s before next attempt
                await rescanFrontmostApp()
                continue
            }
            plans = resolvedPlans

            // Empty plan = goal complete
            if plans.isEmpty {
                writeStatusFile(runID: runID, goal: goal, step: stepCount, maxSteps: maxSteps,
                                lastPlan: actionHistory.last, elementCount: 0, stuck: false, status: "completed")
                return OrchestratorResult(
                    succeeded: true,
                    stepsExecuted: stepCount,
                    reason: "SlowBrain returned empty plan — goal complete"
                )
            }

            // Explicit "done" signal
            if let first = plans.first,
               first.action.lowercased() == "done" || first.action.lowercased() == "complete" {
                writeStatusFile(runID: runID, goal: goal, step: stepCount, maxSteps: maxSteps,
                                lastPlan: actionHistory.last, elementCount: 0, stuck: false, status: "completed")
                return OrchestratorResult(
                    succeeded: true,
                    stepsExecuted: stepCount,
                    reason: first.verifyCondition ?? "Goal completed"
                )
            }

            // Execute each step in the plan
            for plan in plans {
                guard stepCount < maxSteps else { break }

                let coords = plan.x.map { x in plan.y.map { y in "(\(x),\(y))" } ?? "" } ?? ""
                fputs("[orchestrator] step \(stepCount + 1): \(plan.action) '\(plan.elementSelector)' \(coords)"
                    + (plan.value.map { " value='\($0)'" } ?? "") + "\n", stderr)

                // Record in history for stuck detection + LLM context
                actionHistory.append(plan)

                // If the LLM returned explicit coordinates (vision path), use them directly
                if let px = plan.x, let py = plan.y, plan.action.lowercased() != "done" {
                    await executeVision(plan: plan, x: px, y: py)
                } else {
                    // Fallback: AX path via FastBrain (for plans without coordinates)
                    let snapshot = worldModel.makeFBSnapshot()
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
                }
                
                stepCount += 1

                // Pause for AX events + WorldModel to settle after the action
                try await Task.sleep(nanoseconds: 500_000_000)  // 500ms — web pages need time
                await rescanFrontmostApp()
                
                let currentElementCount = worldModel.currentSnapshot.elements.count
                if plan.action.lowercased() != "done" && plan.action.lowercased() != "wait" {
                    // Don't flag stuck on type/setValue — element count doesn't change when typing
                    let lastActionWasType = historyCopy.last.map {
                        ["type", "fill", "setvalue", "input"].contains($0.action.lowercased())
                    } ?? false
                    let evalStuckFromCount = !lastActionWasType && (currentElementCount == lastElementCount)
                    if evalStuckFromCount {
                        evalStuck = true
                    } else {
                        evalStuck = false
                        // Learning Extraction
                        if let px = plan.x, let py = plan.y, plan.action.lowercased() == "click" || plan.action.lowercased() == "type" {
                            let point = CGPoint(x: px, y: py)
                            if let hitElement = worldModel.currentSnapshot.elements.values.first(where: { 
                                point.x >= $0.frame.x && point.x <= $0.frame.x + $0.frame.width && 
                                point.y >= $0.frame.y && point.y <= $0.frame.y + $0.frame.height 
                            }) {
                                let bundleID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown" }
                                let lbl = hitElement.label ?? plan.elementSelector
                                let rule = LearnedRule(
                                    id: UUID(),
                                    createdAt: Date(),
                                    successCount: 1,
                                    targetBundleID: bundleID,
                                    elementRole: hitElement.role.rawValue,
                                    elementLabelPattern: lbl,
                                    labelMatchType: .caseInsensitive,
                                    intentType: plan.action.lowercased() == "type" ? .typeValue : .pressButton,
                                    resolvedAction: plan.action.lowercased() == "type" ? .setValue(targetRole: hitElement.role.rawValue, targetLabel: lbl, value: plan.value ?? "") : .press(targetRole: hitElement.role.rawValue, targetLabel: lbl)
                                )
                                LearnedRulesStore.shared.append(rule)
                                fputs("[orchestrator] Learnt FastBrain rule for '\(lbl)'\n", stderr)
                            }
                        }
                    }
                } else {
                    evalStuck = false
                }
                lastElementCount = worldModel.currentSnapshot.elements.count
            }

            writeStatusFile(runID: runID, goal: goal, step: stepCount, maxSteps: maxSteps,
                            lastPlan: plans.last, elementCount: worldModel.currentSnapshot.elements.count,
                            stuck: evalStuck, status: "running")
        }

        writeStatusFile(runID: runID, goal: goal, step: stepCount, maxSteps: maxSteps,
                        lastPlan: actionHistory.last, elementCount: 0, stuck: false, status: "failed")
        return OrchestratorResult(
            succeeded: false,
            stepsExecuted: stepCount,
            reason: "Max steps (\(maxSteps)) reached without completion signal"
        )
    }

    // MARK: - Stuck Detection

    /// Checks if the last N actions are identical (same action type + same coordinates).
    /// This catches the "click at (225,445) 100 times" failure mode.
    private func isStuck() -> Bool {
        guard actionHistory.count >= stuckThreshold else { return false }
        
        // 1. Check for basic repetition (e.g. A, A, A)
        let recent3 = actionHistory.suffix(stuckThreshold)
        let firstOf3 = recent3.first!
        let isTripleRepeat = recent3.allSatisfy { plan in
            plan.action.lowercased() == firstOf3.action.lowercased() &&
            plan.x == firstOf3.x &&
            plan.y == firstOf3.y &&
            plan.elementSelector == firstOf3.elementSelector
        }
        if isTripleRepeat { return true }
        
        // 2. Check for oscillating loops (e.g. A, B, A, B)
        if actionHistory.count >= 4 {
            let recent4 = Array(actionHistory.suffix(4))
            let a1 = recent4[0]
            let b1 = recent4[1]
            let a2 = recent4[2]
            let b2 = recent4[3]
            
            let isA1A2 = a1.action.lowercased() == a2.action.lowercased() && a1.x == a2.x && a1.y == a2.y && a1.elementSelector == a2.elementSelector
            let isB1B2 = b1.action.lowercased() == b2.action.lowercased() && b1.x == b2.x && b1.y == b2.y && b1.elementSelector == b2.elementSelector
            
            if isA1A2 && isB1B2 {
                return true
            }
        }
        
        return false
    }

    // MARK: - Rescan helper

    private func rescanFrontmostApp() async {
        if let frontPID = await MainActor.run(body: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }) {
            worldModel.scanApp(pid: frontPID)
            worldModel.drainScanQueue()
            worldModel.captureFocus()
        }
    }

    // MARK: - Execution helpers

    /// Execute a FastBrain-resolved action using coordinate clicking.
    /// Frame-based clicks are visible, work for web content, and survive liveRefs staleness.
    private func executeResolved(_ action: ResolvedAction, plan: ActionPlan) async {
        switch action {
        case .press(let el):
            await clickElement(label: el.label, fallbackPlan: plan)

        case .setValue(let el, let value):
            // Focus the field first via coordinate click, then type
            if let frame = worldModel.frameForElement(label: el.label) {
                let center = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
                fputs("[orchestrator]   coordinate click '\(el.label)' at (\(Int(center.x)), \(Int(center.y)))\n", stderr)
                executor.click(at: center)
                try? await Task.sleep(nanoseconds: 150_000_000)
                // Type via AX setValue (reliable for native fields) or keyboard
                if let axRef = worldModel.axElement(for: el.label, role: el.role) {
                    let axEl = AXElement(axElement: axRef, label: el.label)
                    _ = try? await executor.execute(.setValue(value), on: axEl)
                } else {
                    // Fallback: type via CGEvent keyboard (works everywhere)
                    await typeText(value)
                }
            } else {
                await executeDirect(plan: plan)
            }

        case .scroll(_, let direction, _):
            let key: CGKeyCode = direction == .down ? 125 : 126  // down/up arrow
            postKeyEvent(key)
        }
    }

    /// Direct execution from ActionPlan when FastBrain is uncertain.
    /// Uses coordinate clicking — visible cursor movement, works for web content.
    private func executeDirect(plan: ActionPlan) async {
        let selector = plan.elementSelector
        let action = plan.action.lowercased()

        switch action {
        case "click", "press", "tap":
            if selector.isEmpty {
                fputs("[orchestrator]   empty selector for click — skipping\n", stderr)
                return
            }
            await clickElement(label: selector, fallbackPlan: nil)

        case "type", "input", "fill", "enter":
            guard let value = plan.value, !value.isEmpty else { return }
            if !selector.isEmpty {
                // Click the field first
                await clickElement(label: selector, fallbackPlan: nil)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            // Try AX setValue first (native fields), fall back to keyboard typing
            if !selector.isEmpty, let axRef = worldModel.axElement(for: selector, role: "") {
                let axEl = AXElement(axElement: axRef, label: selector)
                if let _ = try? await executor.execute(.setValue(value), on: axEl) { return }
            }
            await typeText(value)

        case "scroll":
            let direction = plan.value?.lowercased() ?? "down"
            let key: CGKeyCode = direction == "up" ? 126 : 125  // up/down arrow
            fputs("[orchestrator]   scroll \(direction) via arrow key\n", stderr)
            for _ in 0..<5 { postKeyEvent(key) }  // 5 arrow key presses

        case "wait":
            fputs("[orchestrator]   wait 2 seconds...\n", stderr)
            try? await Task.sleep(nanoseconds: 2_000_000_000)

        case "key", "keyboardshortcut":
            let val = plan.value?.lowercased() ?? "return"
            fputs("[orchestrator]   key '\(val)'\n", stderr)
            var k: CGKeyCode = 36
            if val == "escape" || val == "esc" { k = 53 }
            else if val == "tab" { k = 48 }
            else if val == "space" { k = 49 }
            else if val == "delete" || val == "backspace" { k = 51 }
            postKeyEvent(k)

        default:
            fputs("[orchestrator]   unknown action '\(plan.action)' — skipping\n", stderr)
        }
    }

    /// Execute a vision-based action: LLM returned explicit screen coordinates.
    private func executeVision(plan: ActionPlan, x: Int, y: Int) async {
        let point = CGPoint(x: x, y: y)
        switch plan.action.lowercased() {
        case "click", "press", "tap":
            fputs("[orchestrator]   vision-click '\(plan.elementSelector)' at (\(x),\(y))\n", stderr)
            if let vnc = vncClient {
                // VNC PointerEvent — preferred, works at display framebuffer level
                let physical = coordMapper?.logicalToPhysical(point) ?? point
                await vnc.click(x: Int(physical.x), y: Int(physical.y))
            } else {
                executor.click(at: point)
            }

        case "type", "input", "fill":
            fputs("[orchestrator]   vision-click+type '\(plan.elementSelector)' at (\(x),\(y))\n", stderr)
            if let vnc = vncClient {
                let physical = coordMapper?.logicalToPhysical(point) ?? point
                await vnc.click(x: Int(physical.x), y: Int(physical.y))
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let value = plan.value, !value.isEmpty {
                    await vnc.typeText(value)
                    await vnc.pressKey(0xFF0D, down: true)   // RFB XK_Return keysym
                    await vnc.pressKey(0xFF0D, down: false)
                }
            } else {
                executor.click(at: point)
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let value = plan.value, !value.isEmpty {
                    await typeText(value)
                    postKeyEvent(36)
                }
            }

        case "scroll":
            let direction = plan.value?.lowercased() ?? "down"
            fputs("[orchestrator]   vision-scroll \(direction) at (\(x),\(y))\n", stderr)
            if let vnc = vncClient {
                let physical = coordMapper?.logicalToPhysical(point) ?? point
                let dir: ScrollDirection = direction == "up" ? .up : .down
                await vnc.scroll(x: Int(physical.x), y: Int(physical.y), direction: dir, amount: 5)
            } else {
                let key: CGKeyCode = direction == "up" ? 126 : 125
                executor.click(at: point)
                try? await Task.sleep(nanoseconds: 100_000_000)
                for _ in 0..<5 { postKeyEvent(key) }
            }

        case "wait":
            fputs("[orchestrator]   wait 2 seconds...\n", stderr)
            try? await Task.sleep(nanoseconds: 2_000_000_000)

        case "key", "keyboardshortcut":
            let val = plan.value?.lowercased() ?? "return"
            fputs("[orchestrator]   key '\(val)'\n", stderr)
            var k: CGKeyCode = 36
            if val == "escape" || val == "esc" { k = 53 }
            else if val == "tab" { k = 48 }
            else if val == "space" { k = 49 }
            else if val == "delete" || val == "backspace" { k = 51 }
            postKeyEvent(k)

        default:
            fputs("[orchestrator]   unknown vision action '\(plan.action)'\n", stderr)
        }
    }

    // MARK: - Low-level input helpers

    /// Find element by label, click at its frame center via CGEvent.
    private func clickElement(label: String, fallbackPlan: ActionPlan?) async {
        guard let frame = worldModel.frameForElement(label: label) else {
            fputs("[orchestrator]   no frame for '\(label)' — skipping\n", stderr)
            return
        }
        let center = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        fputs("[orchestrator]   click '\(label)' at (\(Int(center.x)), \(Int(center.y)))\n", stderr)
        executor.click(at: center)
    }

    /// Type text by posting CGEvent keyboard events for each character.
    private func typeText(_ text: String) async {
        fputs("[orchestrator]   typing \(text.count) chars via keyboard\n", stderr)
        let source = CGEventSource(stateID: .combinedSessionState)
        for scalar in text.unicodeScalars {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            var uniChar = UniChar(scalar.value & 0xFFFF)
            keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uniChar)
            keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uniChar)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    /// Post a single key down+up event by virtual key code.
    private func postKeyEvent(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
