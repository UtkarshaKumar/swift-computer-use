import ArgumentParser
import Foundation

/// `sdd stop` — signals the running sdd run to abort gracefully.
struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the currently running sdd run"
    )

    func run() throws {
        let sddDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sdd")
        let stateURL = sddDir.appendingPathComponent("run-state.json")

        // Read existing run-state.json
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            print("No active run to stop.")
            return
        }

        let existingData: Data
        do {
            existingData = try Data(contentsOf: stateURL)
        } catch {
            print("Error reading run-state.json: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        guard var json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            print("Error: run-state.json is not valid JSON.")
            throw ExitCode.failure
        }

        let currentStatus = json["status"] as? String ?? ""
        guard currentStatus == "running" else {
            print("No active run to stop.")
            return
        }

        // Merge abort signal into the existing JSON
        json["status"] = "abort"

        let updatedData: Data
        do {
            updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        } catch {
            print("Error serializing updated run-state.json: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        let tmpURL = sddDir.appendingPathComponent("run-state.json.tmp")

        do {
            try updatedData.write(to: tmpURL, options: .atomic)
            // Atomic rename (POSIX rename semantics)
            if FileManager.default.fileExists(atPath: stateURL.path) {
                _ = try? FileManager.default.removeItem(at: stateURL)
            }
            try FileManager.default.moveItem(at: tmpURL, to: stateURL)
        } catch {
            print("Error writing run-state.json: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        print("Stop signal sent. Run will abort at the next step.")
    }
}
