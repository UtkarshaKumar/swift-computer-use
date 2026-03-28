import Foundation
import SDDCore

/// Errors that can occur during slow brain routing.
public enum SlowBrainError: Error {
    case localOnlyModeActive
    case serializationFailed
    case networkError(Error)
    case invalidResponse
    case parsingFailed(Error)
}

/// A router that serializes the world model and communicates with a slow brain LLM.
public struct SlowBrainRouter {
    public enum Provider: String, Codable {
        case claude = "claude"
        case openAI = "openai"
    }

    public let config: Config
    
    public struct Config {
        public var provider: Provider = .claude
        public var apiKey: String?
        public var endpoint: URL?
        public var localOnly: Bool = false
        
        public init(provider: Provider = .claude, apiKey: String? = nil, endpoint: URL? = nil, localOnly: Bool = false) {
            self.provider = provider
            self.apiKey = apiKey
            self.endpoint = endpoint
            self.localOnly = localOnly
        }
    }

    public init(config: Config) {
        self.config = config
    }

    /// Routes the current world model to the slow brain for an action plan.
    public func route(worldModel: WorldModel) async throws -> [ActionPlan] {
        guard !config.localOnly else {
            throw SlowBrainError.localOnlyModeActive
        }

        // 1. Context Serialization (Target: < 10ms)
        let startTime = Date()
        let context = try serializeContext(from: worldModel, expanded: false)
        let serializationDuration = Date().timeIntervalSince(startTime)
        
        // Logging for performance tracking (optional)
        // print("Serialization time: \(serializationDuration * 1000)ms")

        // 2. LLM Call
        do {
            let response = try await callLLM(with: context)
            
            // 3. Response Parsing
            return try parseActionPlan(from: response)
        } catch {
            // 4. Progressive Expansion on failure
            if case SlowBrainError.parsingFailed = error {
                let expandedContext = try serializeContext(from: worldModel, expanded: true)
                let response = try await callLLM(with: expandedContext)
                return try parseActionPlan(from: response)
            }
            throw error
        }
    }

    // MARK: - Internal Implementation

    /// Serializes a WorldModelSnapshot into a compact JSON context for the LLM.
    /// Uses WorldModelProtocol.currentSnapshot — no Gemini-era custom methods.
    internal func serializeContext(from snapshot: WorldModelSnapshot, expanded: Bool) throws -> Data {
        struct SerializedContext: Codable {
            let focused_element: FocusedElement?
            let interactive_elements: [CompactElement]

            struct FocusedElement: Codable {
                let role: String
                let label: String
                let value: String?
            }

            struct CompactElement: Codable {
                let r: String  // role
                let l: String  // label
                let v: String? // value (only in expanded mode)
            }
        }

        // Focused element
        var focusedData: SerializedContext.FocusedElement?
        if let fid = snapshot.focusedElementID, let el = snapshot.elements[fid] {
            focusedData = .init(
                role: el.role.rawValue,
                label: el.label ?? "",
                value: el.value
            )
        }

        // Interactive elements: buttons, text fields, links, checkboxes
        let interactiveRoles: Set<UIElementRole> = [
            .button, .textField, .checkBox, .link, .menuItem, .comboBox, .popUpButton
        ]
        let interactive = snapshot.elements.values
            .filter { interactiveRoles.contains($0.role) && $0.state.contains(.enabled) }
            .sorted { ($0.label ?? "") < ($1.label ?? "") }
        let compactElements = interactive.map {
            SerializedContext.CompactElement(
                r: $0.role.rawValue,
                l: $0.label ?? "",
                v: expanded ? $0.value : nil
            )
        }

        let context = SerializedContext(
            focused_element: focusedData,
            interactive_elements: compactElements
        )
        return try JSONEncoder().encode(context)
    }

    /// Overload accepting a live WorldModel — snapshots internally.
    internal func serializeContext(from worldModel: WorldModel, expanded: Bool) throws -> Data {
        try serializeContext(from: worldModel.currentSnapshot, expanded: expanded)
    }

    /// Communicates with the configured LLM endpoint.
    internal func callLLM(with contextData: Data) async throws -> Data {
        let endpoint = config.endpoint ?? URL(string: "https://api.anthropic.com/v1/messages")!
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let apiKey = config.apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        
        // Build payload based on provider
        let payload: [String: Any]
        if config.provider == .claude {
            let contextString = String(data: contextData, encoding: .utf8) ?? ""
            payload = [
                "model": "claude-3-opus-20240229",
                "max_tokens": 1024,
                "messages": [
                    ["role": "user", "content": "Analyze this screen state and provide an action plan in JSON format: \(contextString)"]
                ]
            ]
        } else {
            // Default/OpenAI implementation
            payload = [:]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw SlowBrainError.invalidResponse
        }
        
        return data
    }

    /// Parses the LLM response into a structured action plan.
    internal func parseActionPlan(from data: Data) throws -> [ActionPlan] {
        let decoder = JSONDecoder()
        
        // Helper to extract JSON from a string that might contain markdown blocks
        func extractJSON(from text: String) -> Data? {
            let pattern = "```(?:json)?\\s*([\\s\\S]*?)\\s*```"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) {
                let jsonRange = Range(match.range(at: 1), in: text)!
                return String(text[jsonRange]).data(using: .utf8)
            }
            return text.data(using: .utf8)
        }

        // First try to parse the entire response if it's directly the JSON array
        if let plan = try? decoder.decode([ActionPlan].self, from: data) {
            return plan
        }

        // Try extracting from raw data string if it's markdown-wrapped JSON
        if let text = String(data: data, encoding: .utf8),
           let contentData = extractJSON(from: text),
           let plan = try? decoder.decode([ActionPlan].self, from: contentData) {
            return plan
        }

        // Try extracting from a Claude/OpenAI style JSON response structure
        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            
            // Handle Claude response format
            if let contentArray = json?["content"] as? [[String: Any]],
               let text = contentArray.first?["text"] as? String {
                if let contentData = extractJSON(from: text) {
                    return try decoder.decode([ActionPlan].self, from: contentData)
                }
            }
            
            // Handle OpenAI response format
            if let choices = json?["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let text = message["content"] as? String {
                if let contentData = extractJSON(from: text) {
                    return try decoder.decode([ActionPlan].self, from: contentData)
                }
            }
        } catch {
            // Fall through to error
        }
        
        throw SlowBrainError.parsingFailed(NSError(domain: "SlowBrainRouter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find valid ActionPlan JSON in response"]))
    }
}
