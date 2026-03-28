import ArgumentParser
import Foundation

/// `sdd status` — reads ~/.sdd/run-state.json and prints the current run state.
struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the status of the currently running sdd run"
    )

    func run() throws {
        let sddDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sdd")
        let stateURL = sddDir.appendingPathComponent("run-state.json")

        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            print("No active run.")
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: stateURL)
        } catch {
            print("Error reading run-state.json: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("Error: run-state.json is not valid JSON.")
            throw ExitCode.failure
        }

        // Pull out fields with sensible fallbacks
        let step       = json["step"]        as? Int    ?? 0
        let maxSteps   = json["max_steps"]   as? Int    ?? 0
        let action     = json["action"]      as? String ?? "—"
        let elements   = json["elements"]    as? Int    ?? 0
        let stuck      = (json["stuck"]      as? Bool   ?? false) ? "yes" : "no"
        let status     = json["status"]      as? String ?? "unknown"
        let goal       = json["goal"]        as? String

        // Print one-line summary
        var line = "Step \(step)/\(maxSteps) | action: \(action) | elements: \(elements) | stuck: \(stuck) | status: \(status)"

        // Append coordinates if present
        if let x = json["x"] as? Int, let y = json["y"] as? Int {
            // Replace bare action string with action + coords (format used by TaskOrchestrator)
            line = "Step \(step)/\(maxSteps) | action: \(action) (\(x),\(y)) | elements: \(elements) | stuck: \(stuck) | status: \(status)"
        }

        print(line)

        if let goal = goal {
            print("Goal: \(goal)")
        }
    }
}
