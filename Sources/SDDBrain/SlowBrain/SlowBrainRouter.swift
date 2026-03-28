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
public struct SlowBrainRouter: Sendable {
    public enum Provider: String, Codable, Sendable {
        case claude = "claude"
        case openAI = "openai"
    }

    public let config: Config
    
    public struct Config: Sendable {
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

    /// Routes the current world model + goal to the slow brain for the next action step.
    /// - Parameters:
    ///   - goal: The high-level user goal (e.g. "apply for this job with my resume at ~/resume.pdf")
    ///   - worldModel: Live world model; serialized to compact JSON context
    public func route(goal: String, worldModel: WorldModel) async throws -> [ActionPlan] {
        guard !config.localOnly else {
            throw SlowBrainError.localOnlyModeActive
        }

        // 1. Context Serialization (Target: < 10ms)
        let context = try serializeContext(from: worldModel, expanded: false)

        // 2. LLM Call
        do {
            let response = try await callLLM(with: context, goal: goal)
            return try parseActionPlan(from: response)
        } catch {
            // 3. Progressive Expansion on parse failure — include element values
            if case SlowBrainError.parsingFailed = error {
                let expandedContext = try serializeContext(from: worldModel, expanded: true)
                let response = try await callLLM(with: expandedContext, goal: goal)
                return try parseActionPlan(from: response)
            }
            throw error
        }
    }

    /// Legacy overload — routes without an explicit goal (used by tests and EVAL harness).
    public func route(worldModel: WorldModel) async throws -> [ActionPlan] {
        try await route(goal: "", worldModel: worldModel)
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
    internal func callLLM(with contextData: Data, goal: String = "") async throws -> Data {
        let endpoint = config.endpoint ?? URL(string: "https://api.anthropic.com/v1/messages")!

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = config.apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        let contextString = String(data: contextData, encoding: .utf8) ?? ""

        let prompt: String
        if goal.isEmpty {
            prompt = """
            Analyze this screen state and return the next action as a JSON array.
            Screen state: \(contextString)

            Return ONLY a JSON array like:
            [{"action":"click","element_selector":"Button Label","value":null,"verify_condition":null}]

            Actions: "click", "type", "scroll", "done"
            For scroll, set value to "up" or "down".
            If the goal appears complete, return [{"action":"done","element_selector":"","value":null,"verify_condition":"goal complete"}]
            """
        } else {
            prompt = """
            You are a macOS computer-use agent. Your goal is:
            GOAL: \(goal)

            Current screen state (JSON):
            \(contextString)

            What is the SINGLE NEXT ACTION to take toward completing the goal?
            Return ONLY a JSON array with one action object:
            [{"action":"click","element_selector":"Exact Button Label","value":null,"verify_condition":null}]

            Rules:
            - "action" must be one of: "click", "type", "scroll", "done"
            - "element_selector" must exactly match a label from the screen state
            - For "type", set "value" to the text to enter
            - For "scroll", set "value" to "up" or "down"
            - If the goal is already complete, return [{"action":"done","element_selector":"","value":null,"verify_condition":"goal complete"}]
            - Return ONLY the JSON array, no markdown, no explanation
            """
        }

        let payload: [String: Any]
        if config.provider == .claude {
            payload = [
                "model": "claude-sonnet-4-6",
                "max_tokens": 512,
                "messages": [
                    ["role": "user", "content": prompt]
                ]
            ]
        } else {
            // OpenAI-compatible
            payload = [
                "model": "gpt-4o",
                "max_tokens": 512,
                "messages": [
                    ["role": "user", "content": prompt]
                ]
            ]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
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
