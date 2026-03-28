import ArgumentParser
import Foundation

/// `sdd override "<instruction>"` — injects a guidance instruction into the running sdd run.
///
/// The instruction is written to ~/.sdd/override.json with a 60-second TTL.
/// TaskOrchestrator reads this file at the start of each step, prepends it to the LLM
/// prompt as HIGHEST PRIORITY guidance, then deletes the file.
struct OverrideCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "override",
        abstract: "Inject a guidance instruction into the currently running sdd run"
    )

    @Argument(help: "Instruction to inject (e.g. 'scroll down and look for the Easy Apply button')")
    var instruction: String

    func run() throws {
        let sddDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sdd")

        // Create the ~/.sdd directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: sddDir.path) {
            do {
                try FileManager.default.createDirectory(
                    at: sddDir,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                print("Error: could not create ~/.sdd directory: \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }

        let expiresAt = Date().timeIntervalSince1970 + 60.0

        let payload: [String: Any] = [
            "instruction": instruction,
            "expires_at": expiresAt
        ]

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        } catch {
            print("Error serializing override JSON: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        let overrideURL = sddDir.appendingPathComponent("override.json")
        let tmpURL      = sddDir.appendingPathComponent("override.json.tmp")

        do {
            try data.write(to: tmpURL, options: .atomic)
            // Atomic rename (POSIX rename semantics)
            if FileManager.default.fileExists(atPath: overrideURL.path) {
                _ = try? FileManager.default.removeItem(at: overrideURL)
            }
            try FileManager.default.moveItem(at: tmpURL, to: overrideURL)
        } catch {
            print("Error writing override.json: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        print("Override injected. Will apply on the next step.")
    }
}
