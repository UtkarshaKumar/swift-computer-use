import Foundation
import CoreGraphics

// MARK: - RuleMatch

/// Intermediate result from a single rule evaluation.
struct RuleMatch {
    let action: ResolvedAction
    let confidence: Double
}

// MARK: - FastBrainRule protocol

/// A single pattern-match rule. Rules are stateless value types evaluated in priority order.
/// Returning nil means "this rule does not apply"; the engine moves to the next rule.
protocol FastBrainRule {
    func evaluate(snapshot: WorldModelSnapshot, task: TaskContext) -> RuleMatch?
}

// MARK: - Rule 1: FocusedFieldRule

/// Matches when a text input element is focused and the intent is typeValue.
/// This is the highest-confidence rule — if the OS says a text field is focused,
/// AXSetValue will succeed deterministically.
struct FocusedFieldRule: FastBrainRule {
    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXSecureTextField"
    ]

    @inline(__always)
    func evaluate(snapshot: WorldModelSnapshot, task: TaskContext) -> RuleMatch? {
        guard case .typeValue(let targetLabel, let value) = task.intent else { return nil }

        // If targetLabel is specified, prefer a focused field with that label;
        // fall back to any focused text role if label is nil.
        let candidate: UIElement?

        if let label = targetLabel {
            // Try focused element with matching label first (most precise)
            candidate = snapshot.appContext.focusedElement.flatMap { el in
                FocusedFieldRule.textRoles.contains(el.role) && el.label == label ? el : nil
            } ?? snapshot.elements.first { el in
                FocusedFieldRule.textRoles.contains(el.role) && el.label == label && el.isFocused
            }
        } else {
            // Use whatever text field currently holds focus
            candidate = snapshot.appContext.focusedElement.flatMap { el in
                FocusedFieldRule.textRoles.contains(el.role) ? el : nil
            } ?? snapshot.elements.first { el in
                FocusedFieldRule.textRoles.contains(el.role) && el.isFocused
            }
        }

        guard let el = candidate, el.isEnabled else { return nil }
        return RuleMatch(action: .setValue(element: el, value: value), confidence: 0.97)
    }
}

// MARK: - Rule 2: ButtonMatchRule

/// Matches a pressButton intent against visible, enabled button-like elements.
/// Confidence is graded by label match quality; ambiguity (multiple equal-quality
/// matches) drops confidence to 0.60 to force slow brain review.
struct ButtonMatchRule: FastBrainRule {
    private static let pressableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXLink", "AXMenuItem"
    ]

    @inline(__always)
    func evaluate(snapshot: WorldModelSnapshot, task: TaskContext) -> RuleMatch? {
        guard case .pressButton(let label) = task.intent else { return nil }

        struct Candidate {
            let element: UIElement
            let confidence: Double
        }

        var candidates: [Candidate] = []

        for el in snapshot.elements {
            guard ButtonMatchRule.pressableRoles.contains(el.role),
                  el.isEnabled,
                  el.isVisible
            else { continue }

            let conf = labelConfidence(elementLabel: el.label, targetLabel: label)
            if conf > 0 {
                candidates.append(Candidate(element: el, confidence: conf))
            }
        }

        guard !candidates.isEmpty else { return nil }

        // Sort by descending confidence, then check for ambiguity at the top score
        let sorted = candidates.sorted { $0.confidence > $1.confidence }
        let best = sorted[0]

        // If more than one candidate shares the top confidence, the match is ambiguous
        let topCount = sorted.filter { $0.confidence == best.confidence }.count
        let finalConf = topCount > 1 ? 0.60 : best.confidence

        return RuleMatch(action: .press(element: best.element), confidence: finalConf)
    }

    /// Returns match confidence based on label comparison quality.
    /// 0.97  — exact match
    /// 0.93  — case-insensitive exact match
    /// 0.88  — element label contains the target (substring)
    /// 0.0   — no match
    @inline(__always)
    private func labelConfidence(elementLabel: String, targetLabel: String) -> Double {
        if elementLabel == targetLabel { return 0.97 }
        if elementLabel.lowercased() == targetLabel.lowercased() { return 0.93 }
        if elementLabel.lowercased().contains(targetLabel.lowercased()) { return 0.88 }
        if targetLabel.lowercased().contains(elementLabel.lowercased()) { return 0.88 }
        return 0.0
    }
}

// MARK: - Rule 3: ScrollRule

/// Matches scroll intents and fold-detection cases.
/// Triggers on:
///   a) explicit `.scroll` intent
///   b) a `.pressButton` or `.typeValue` targeting an element that is below the fold
struct ScrollRule: FastBrainRule {
    @inline(__always)
    func evaluate(snapshot: WorldModelSnapshot, task: TaskContext) -> RuleMatch? {
        let viewport = snapshot.appContext.viewportFrame

        switch task.intent {
        case .scroll(let targetLabel, let direction):
            // Find a scrollable container. Prefer one matching targetLabel; fall back to
            // the first visible scrollable element, or any element in the window.
            let scrollTarget = resolveScrollTarget(
                label: targetLabel,
                elements: snapshot.elements,
                viewport: viewport
            )
            guard let target = scrollTarget else { return nil }
            return RuleMatch(
                action: .scroll(element: target, direction: direction, amount: 3),
                confidence: 0.95
            )

        case .pressButton(let label):
            // Detect if the target button is below the fold
            guard let el = snapshot.elements.first(where: {
                $0.label.lowercased() == label.lowercased() && !$0.isVisible
            }),
            el.frame.maxY > viewport.maxY
            else { return nil }

            // Need to scroll down to bring the element into view
            let scrollContainer = resolveScrollTarget(
                label: nil,
                elements: snapshot.elements,
                viewport: viewport
            ) ?? el
            return RuleMatch(
                action: .scroll(element: scrollContainer, direction: .down, amount: 3),
                confidence: 0.95
            )

        case .typeValue(let targetLabel, _):
            guard let label = targetLabel,
                  let el = snapshot.elements.first(where: {
                      $0.label.lowercased() == label.lowercased() && !$0.isVisible
                  }),
                  el.frame.maxY > viewport.maxY
            else { return nil }

            let scrollContainer = resolveScrollTarget(
                label: nil,
                elements: snapshot.elements,
                viewport: viewport
            ) ?? el
            return RuleMatch(
                action: .scroll(element: scrollContainer, direction: .down, amount: 3),
                confidence: 0.95
            )

        case .custom:
            return nil
        }
    }

    private func resolveScrollTarget(
        label: String?,
        elements: [UIElement],
        viewport: CGRect
    ) -> UIElement? {
        let scrollableRoles: Set<String> = ["AXScrollArea", "AXWebArea", "AXList", "AXTable"]

        if let label = label {
            return elements.first {
                scrollableRoles.contains($0.role) && $0.label.lowercased() == label.lowercased()
            }
        }
        // Return first visible scrollable area, or first element as last resort
        return elements.first { scrollableRoles.contains($0.role) && $0.isVisible }
            ?? elements.first
    }
}

// MARK: - Rule 4: NoMatchRule (sentinel)

/// Safety net — always fires with confidence 0.0, ensuring FastBrain never returns nil.
struct NoMatchRule: FastBrainRule {
    func evaluate(snapshot: WorldModelSnapshot, task: TaskContext) -> RuleMatch? {
        // Returns nil — FastBrain handles this case directly to produce UncertaintySignal
        return nil
    }
}

// MARK: - FastBrain

/// The fast-path rule engine. Evaluates rules in priority order on a WorldModelSnapshot
/// and returns either a resolved action or an UncertaintySignal for slow brain escalation.
///
/// Performance contract: `evaluate` is pure in-memory with no AX API calls.
/// Typical latency on an M-series Mac: <1ms for up to 500 elements.
/// The 50ms budget is dominated by AX action dispatch in ActionExecutor, not here.
public struct FastBrain {
    /// Confidence below this value triggers escalation to slow brain.
    /// Default: 0.85. Configurable per deployment.
    public let confidenceThreshold: Double

    private let rules: [any FastBrainRule]

    public init(confidenceThreshold: Double = 0.85) {
        self.confidenceThreshold = confidenceThreshold
        // Rules run in fixed priority order — see ADR-007
        self.rules = [
            FocusedFieldRule(),
            ButtonMatchRule(),
            ScrollRule(),
            NoMatchRule(),
        ]
    }

    /// Evaluate the current world model snapshot against the agent's task.
    /// Returns `.action` if a rule matches with confidence ≥ threshold,
    /// otherwise `.uncertain` to trigger slow brain routing.
    public func evaluate(
        snapshot: WorldModelSnapshot,
        task: TaskContext
    ) -> FastBrainResult {
        var bestConfidence = 0.0
        var bestMatch: RuleMatch?

        for rule in rules {
            if let match = rule.evaluate(snapshot: snapshot, task: task) {
                if match.confidence > bestConfidence {
                    bestConfidence = match.confidence
                    bestMatch = match
                }
                // Stop at first rule that produces a match (priority-ordered)
                break
            }
        }

        if let match = bestMatch, match.confidence >= confidenceThreshold {
            return .action(match.action, confidence: match.confidence)
        }

        let reason = buildEscalationReason(
            task: task,
            snapshot: snapshot,
            bestConfidence: bestConfidence
        )
        return .uncertain(UncertaintySignal(
            snapshot: snapshot,
            task: task,
            confidence: bestConfidence,
            reason: reason
        ))
    }

    // MARK: - Private helpers

    private func buildEscalationReason(
        task: TaskContext,
        snapshot: WorldModelSnapshot,
        bestConfidence: Double
    ) -> String {
        if bestConfidence == 0.0 {
            return "No rule matched task intent \(intentDescription(task.intent)) in snapshot with \(snapshot.elements.count) elements"
        }
        return "Best confidence \(String(format: "%.2f", bestConfidence)) is below threshold \(confidenceThreshold) for intent \(intentDescription(task.intent))"
    }

    private func intentDescription(_ intent: TaskIntent) -> String {
        switch intent {
        case .typeValue(let label, let value):
            return "typeValue(label: \(label ?? "nil"), value: \"\(value)\")"
        case .pressButton(let label):
            return "pressButton(\"\(label)\")"
        case .scroll(let label, let dir):
            return "scroll(label: \(label ?? "nil"), direction: \(dir))"
        case .custom(let desc):
            return "custom(\"\(desc)\")"
        }
    }
}
