import Foundation

/// Persists learned rules to `~/.sdd/learned-rules.json`.
/// Thread-safe: all mutations are serialized on an internal queue.
/// Writes are atomic (write-to-tmp then rename).
public final class LearnedRulesStore: Sendable {

    public static let shared = LearnedRulesStore()

    private let storeURL: URL
    private let queue = DispatchQueue(label: "com.sdd.learned-rules", qos: .utility)

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".sdd", isDirectory: true)
        self.storeURL = dir.appendingPathComponent("learned-rules.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Load

    /// Load all persisted rules. Called once at daemon startup.
    /// Returns empty array if the file doesn't exist or is malformed.
    public func load() -> [LearnedRule] {
        guard FileManager.default.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL)
        else { return [] }

        do {
            return try JSONDecoder().decode([LearnedRule].self, from: data)
        } catch {
            fputs("[LearnedRulesStore] Failed to decode rules: \(error)\n", stderr)
            return []
        }
    }

    // MARK: - Append

    /// Append a new rule and persist atomically.
    /// If a rule with the same bundleID + role + labelPattern already exists,
    /// increments its successCount instead of adding a duplicate.
    public func append(_ rule: LearnedRule) {
        queue.async { [weak self] in
            guard let self else { return }
            var rules = self.load()

            // Dedup: same app + role + label pattern + intent
            if let idx = rules.firstIndex(where: {
                $0.targetBundleID == rule.targetBundleID &&
                $0.elementRole == rule.elementRole &&
                $0.elementLabelPattern == rule.elementLabelPattern &&
                $0.intentType == rule.intentType
            }) {
                rules[idx].successCount += 1
                rules[idx].lastUsedAt = .now
            } else {
                rules.append(rule)
            }

            self.persist(rules)
        }
    }

    // MARK: - Increment success

    /// Increment the successCount for a rule that fired successfully in production.
    public func incrementSuccess(id: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            var rules = self.load()
            if let idx = rules.firstIndex(where: { $0.id == id }) {
                rules[idx].successCount += 1
                rules[idx].lastUsedAt = .now
                self.persist(rules)
            }
        }
    }

    // MARK: - Persist (atomic write)

    private func persist(_ rules: [LearnedRule]) {
        do {
            var encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(rules)

            // Atomic: write to .tmp, then rename
            let tmpURL = storeURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmpURL)
        } catch {
            fputs("[LearnedRulesStore] Failed to persist rules: \(error)\n", stderr)
        }
    }
}

// MARK: - stderr helper

private nonisolated(unsafe) var stderr = FileHandle.standardError
extension FileHandle {
    @discardableResult
    func write(string: String) -> Bool {
        guard let data = string.data(using: .utf8) else { return false }
        self.write(data)
        return true
    }
}

private func fputs(_ string: String, _ handle: FileHandle) {
    handle.write(string: string)
}
