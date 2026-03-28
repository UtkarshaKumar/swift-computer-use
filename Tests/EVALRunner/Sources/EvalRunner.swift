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
            print("  -> \(status) (latency: \(result.latency_ms)ms)")
            if let error = result.error {
                print("  -> Error: \(error)")
            }
        }

        saveResults(results)
        return results
    }

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
                let decoder = JSONDecoder()
                existingResults = try decoder.decode([EvalResult].self, from: data)
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
    let total = results.count
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