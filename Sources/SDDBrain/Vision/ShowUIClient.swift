import Foundation

/// Client for the local ShowUI-2B inference server.
/// ShowUI is responsible for "where is X on screen?" grounding — not planning.
/// If the server is unavailable, all methods return nil and the caller falls
/// back to the existing Claude vision path.
public struct ShowUIClient: Sendable {

    public let endpoint: URL

    public init(endpoint: URL = URL(string: "http://127.0.0.1:7080")!) {
        self.endpoint = endpoint
    }

    // MARK: - Health check

    /// Returns true if the inference server is reachable (GET /health).
    public func isAvailable() async -> Bool {
        let healthURL = endpoint.appendingPathComponent("health")
        var request = URLRequest(url: healthURL, timeoutInterval: 5)
        request.httpMethod = "GET"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200..<300).contains(http.statusCode)
            }
            return false
        } catch {
            fputs("[ShowUIClient] Health check failed: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    // MARK: - Grounding

    /// Ground a natural language query against a JPEG screenshot.
    /// Returns normalized coordinates (0–1) and confidence, or nil if unavailable/failed.
    public func ground(query: String, imageJpeg: Data) async -> ShowUIResult? {
        let base64 = imageJpeg.base64EncodedString()
        return await ground(query: query, imageBase64: base64)
    }

    /// Convenience: ground against a base64-encoded JPEG.
    public func ground(query: String, imageBase64: String) async -> ShowUIResult? {
        let groundURL = endpoint.appendingPathComponent("ground")

        var request = URLRequest(url: groundURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "image_base64": imageBase64,
            "query": query
        ]

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            fputs("[ShowUIClient] Failed to encode request body: \(error.localizedDescription)\n", stderr)
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                fputs("[ShowUIClient] Non-HTTP response for query '\(query)'\n", stderr)
                return nil
            }

            guard (200..<300).contains(http.statusCode) else {
                fputs("[ShowUIClient] Server returned HTTP \(http.statusCode) for query '\(query)'\n", stderr)
                return nil
            }

            let result = try JSONDecoder().decode(ShowUIResult.self, from: data)
            return result
        } catch {
            fputs("[ShowUIClient] Ground request failed for query '\(query)': \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    // MARK: - Result type

    public struct ShowUIResult: Sendable, Codable {
        /// Normalized horizontal coordinate (0–1, left to right).
        public let x: Double
        /// Normalized vertical coordinate (0–1, top to bottom).
        public let y: Double
        /// Model confidence in the prediction (0–1).
        public let confidence: Double
        /// The query echoed back by the server, useful for debugging.
        public let query: String?
    }
}
