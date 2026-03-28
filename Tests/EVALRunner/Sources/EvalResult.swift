import Foundation

struct EvalResult: Codable {
    let eval_id: String
    let timestamp: String
    let latency_ms: Int
    let success: Bool
    let error: String?
    let metadata: [String: String]?

    init(eval_id: String, latency_ms: Int, success: Bool, error: String? = nil, metadata: [String: String]? = nil) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        self.timestamp = formatter.string(from: Date())
        self.eval_id = eval_id
        self.latency_ms = latency_ms
        self.success = success
        self.error = error
        self.metadata = metadata
    }
}