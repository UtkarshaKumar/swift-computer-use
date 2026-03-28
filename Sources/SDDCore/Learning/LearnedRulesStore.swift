import Foundation
import SQLite3

// MARK: - LearnedRulesStore

/// Persists learned rules to `~/.sdd/learned-rules.db` using SQLite.
/// Includes O(1) compound indexes for FastBrain scaling to millions of rules.
public final class LearnedRulesStore: @unchecked Sendable {

    public static let shared = LearnedRulesStore()

    private let queue = DispatchQueue(label: "com.sdd.learned-rules", qos: .utility)
    private var db: OpaquePointer?

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".sdd", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        let path = dir.appendingPathComponent("learned-rules.db").path
        if sqlite3_open(path, &db) != SQLITE_OK {
            fputs("[LearnedRulesStore] Failed to open db at \(path)\n", stderr)
            db = nil
        } else {
            setupSchema()
        }
    }
    
    deinit {
        if let db = db { sqlite3_close(db) }
    }

    private func setupSchema() {
        let query = """
        CREATE TABLE IF NOT EXISTS learned_rules (
            id TEXT PRIMARY KEY,
            targetBundleID TEXT,
            elementRole TEXT,
            elementLabelPattern TEXT,
            intentType TEXT,
            successCount INTEGER,
            lastUsedAt REAL,
            json_data TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_eval ON learned_rules(targetBundleID, intentType);
        CREATE INDEX IF NOT EXISTS idx_gc ON learned_rules(lastUsedAt, successCount);
        """
        if sqlite3_exec(db, query, nil, nil, nil) != SQLITE_OK {
            fputs("[LearnedRulesStore] Failed to create JSON schema\n", stderr)
        }
    }

    // MARK: - Load

    /// Loads all rules from the DB. 
    public func load() -> [LearnedRule] {
        var rules = [LearnedRule]()
        queue.sync {
            let query = "SELECT json_data FROM learned_rules"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let cString = sqlite3_column_text(stmt, 0) {
                        let jsonString = String(cString: cString)
                        if let data = jsonString.data(using: .utf8),
                           let rule = try? JSONDecoder().decode(LearnedRule.self, from: data) {
                            rules.append(rule)
                        }
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
        return rules
    }

    /// Appends a new rule, or increments successCount if it perfectly matches an existing UI context.
    public func append(_ rule: LearnedRule) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            
            // Deduplicate: same app + role + label pattern + intent
            let checkQuery = "SELECT id, json_data, successCount FROM learned_rules WHERE targetBundleID = ? AND elementRole = ? AND elementLabelPattern = ? AND intentType = ?"
            var checkStmt: OpaquePointer?
            var existingId: String? = nil
            var existingRule: LearnedRule? = nil
            
            if sqlite3_prepare_v2(db, checkQuery, -1, &checkStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(checkStmt, 1, (rule.targetBundleID as NSString).utf8String, -1, nil)
                sqlite3_bind_text(checkStmt, 2, (rule.elementRole as NSString).utf8String, -1, nil)
                sqlite3_bind_text(checkStmt, 3, (rule.elementLabelPattern as NSString).utf8String, -1, nil)
                sqlite3_bind_text(checkStmt, 4, (rule.intentType.rawValue as NSString).utf8String, -1, nil)
                
                if sqlite3_step(checkStmt) == SQLITE_ROW {
                    if let cId = sqlite3_column_text(checkStmt, 0) { existingId = String(cString: cId) }
                    if let cJson = sqlite3_column_text(checkStmt, 1) {
                        let jsonData = String(cString: cJson).data(using: .utf8)!
                        existingRule = try? JSONDecoder().decode(LearnedRule.self, from: jsonData)
                    }
                }
            }
            sqlite3_finalize(checkStmt)
            
            if let eId = existingId, var modified = existingRule {
                // Update existing
                modified.successCount += 1
                modified.lastUsedAt = .now
                self.updateRule(id: eId, rule: modified)
            } else {
                // Insert new
                self.insertRule(rule: rule)
            }
        }
    }

    public func incrementSuccess(id: UUID) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            
            let query = "SELECT json_data FROM learned_rules WHERE id = ?"
            var stmt: OpaquePointer?
            var existingRule: LearnedRule? = nil
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let cJson = sqlite3_column_text(stmt, 0) {
                        let jsonData = String(cString: cJson).data(using: .utf8)!
                        existingRule = try? JSONDecoder().decode(LearnedRule.self, from: jsonData)
                    }
                }
            }
            sqlite3_finalize(stmt)
            
            if var modified = existingRule {
                modified.successCount += 1
                modified.lastUsedAt = .now
                self.updateRule(id: id.uuidString, rule: modified)
            }
        }
    }

    private func insertRule(rule: LearnedRule) {
        guard let data = try? JSONEncoder().encode(rule),
              let jsonString = String(data: data, encoding: .utf8) else { return }
              
        let query = "INSERT INTO learned_rules (id, targetBundleID, elementRole, elementLabelPattern, intentType, successCount, lastUsedAt, json_data) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (rule.id.uuidString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (rule.targetBundleID as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (rule.elementRole as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (rule.elementLabelPattern as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (rule.intentType.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 6, Int32(rule.successCount))
            sqlite3_bind_double(stmt, 7, rule.lastUsedAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 8, (jsonString as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func updateRule(id: String, rule: LearnedRule) {
        guard let data = try? JSONEncoder().encode(rule),
              let jsonString = String(data: data, encoding: .utf8) else { return }
              
        let query = "UPDATE learned_rules SET successCount = ?, lastUsedAt = ?, json_data = ? WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(rule.successCount))
            sqlite3_bind_double(stmt, 2, rule.lastUsedAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, (jsonString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
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
