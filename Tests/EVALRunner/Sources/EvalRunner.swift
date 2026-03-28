import Foundation

struct EvalRunner {
    let cases: [EvalCase]

    init(cases: [EvalCase]) {
        self.cases = cases
    }

    func run() -> [EvalResult] {
        var results: [EvalResult] = []

        for evalCase in cases {
            print("Running \(evalCase.id): \(evalCase.name)...")
            let result = evalCase.run()
            results.append(result)

            let status = result.success ? "PASS" : "FAIL"
            print("  -> \(status) (latency: \(result.latency_ms)ms, path: \(result.metadata?["brain_path"] ?? "unknown"))")
            if let error = result.error {
                print("  -> Error: \(error)")
            }
        }

        saveResults(results)
        promoteLearnedRules(from: results)
        return results
    }

    // MARK: - Rule promotion

    /// After every eval run, promote passing slow-brain results to learned rules.
    /// A result is promotable when:
    ///   - success == true
    ///   - metadata["brain_path"] == "slow"
    ///   - metadata keys "element_role", "element_label", "intent_type", "action_type" are present
    private func promoteLearnedRules(from results: [EvalResult]) {
        let promotable = results.filter {
            $0.success &&
            $0.metadata?["brain_path"] == "slow" &&
            $0.metadata?["element_role"] != nil
        }

        guard !promotable.isEmpty else { return }

        let store = LearnedRulesStore()

        for result in promotable {
            guard
                let role      = result.metadata?["element_role"],
                let label     = result.metadata?["element_label"],
                let intentRaw = result.metadata?["intent_type"],
                let actionRaw = result.metadata?["action_type"]
            else { continue }

            let intentType: TaskIntentType
            switch intentRaw {
            case "pressButton": intentType = .pressButton
            case "typeValue":   intentType = .typeValue
            case "scroll":      intentType = .scroll
            default:
                print("  [promote] Skipping \(result.eval_id): unknown intent_type '\(intentRaw)'")
                continue
            }

            let resolvedAction: LearnedAction
            switch actionRaw {
            case "press":
                resolvedAction = .press(targetRole: role, targetLabel: label)
            case "setValue":
                let value = result.metadata?["action_value"] ?? ""
                resolvedAction = .setValue(targetRole: role, targetLabel: label, value: value)
            case "scroll":
                let dir = result.metadata?["scroll_direction"] ?? "down"
                resolvedAction = .scroll(targetRole: role, targetLabel: label, direction: dir, amount: 3)
            default:
                print("  [promote] Skipping \(result.eval_id): unknown action_type '\(actionRaw)'")
                continue
            }

            let rule = LearnedRule(
                targetBundleID: result.metadata?["bundle_id"] ?? "",
                elementRole: role,
                elementLabelPattern: label,
                labelMatchType: .caseInsensitive,
                intentType: intentType,
                resolvedAction: resolvedAction,
                confidence: 0.90
            )

            store.append(rule)
            print("  [promote] \(result.eval_id) → learned rule: \(role)/\"\(label)\" (\(intentRaw))")
        }

        if !promotable.isEmpty {
            print("\n[\(promotable.count)] slow-brain pass(es) promoted to learned rules → ~/.sdd/learned-rules.json")
        }
    }

    // MARK: - Save results

    private func saveResults(_ results: [EvalResult]) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())

        let evalDir = URL(fileURLWithPath: "eval-results")

        if !FileManager.default.fileExists(atPath: evalDir.path) {
            try? FileManager.default.createDirectory(at: evalDir, withIntermediateDirectories: true)
        }

        let filePath = evalDir.appendingPathComponent("\(dateString).json")

        var existingResults: [EvalResult] = []

        if FileManager.default.fileExists(atPath: filePath.path) {
            do {
                let data = try Data(contentsOf: filePath)
                existingResults = try JSONDecoder().decode([EvalResult].self, from: data)
            } catch {
                print("Warning: Could not read existing results file: \(error)")
            }
        }

        let allResults = existingResults + results

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(allResults)
            try data.write(to: filePath)
            print("\nResults saved to \(filePath.path)")
        } catch {
            print("Error saving results: \(error)")
        }
    }
}

func printSummary(_ results: [EvalResult]) {
    let total  = results.count
    let passed = results.filter { $0.success }.count
    let failed = total - passed

    print("\n" + String(repeating: "=", count: 50))
    print("EVAL SUMMARY")
    print(String(repeating: "=", count: 50))
    print("Total:  \(total)")
    print("Passed: \(passed)")
    print("Failed: \(failed)")
    print(String(repeating: "=", count: 50))
}
