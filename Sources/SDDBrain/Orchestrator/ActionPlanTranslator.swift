import Foundation

/// Translates a single ActionPlan step (from SlowBrain) into a TaskContext
/// that FastBrain can evaluate against the current FBSnapshot.
///
/// This is stateless and synchronous — no AX calls, no async.
public struct ActionPlanTranslator {

    public init() {}

    /// Convert one ActionPlan into a TaskContext.
    public func toTaskContext(_ plan: ActionPlan) -> TaskContext {
        TaskContext(intent: intent(for: plan))
    }

    // MARK: - Private

    private func intent(for plan: ActionPlan) -> TaskIntent {
        switch plan.action.lowercased() {
        case "click", "press", "tap":
            return .pressButton(label: plan.elementSelector)

        case "type", "input", "fill", "enter":
            let label: String? = plan.elementSelector.isEmpty ? nil : plan.elementSelector
            return .typeValue(targetLabel: label, value: plan.value ?? "")

        case "scroll":
            return .scroll(targetLabel: nil, direction: parseDirection(plan.value ?? "down"))

        default:
            return .custom(description: "\(plan.action) on '\(plan.elementSelector)'")
        }
    }

    private func parseDirection(_ raw: String) -> ScrollDirection {
        switch raw.lowercased() {
        case "up":    return .up
        case "left":  return .left
        case "right": return .right
        default:      return .down
        }
    }
}
