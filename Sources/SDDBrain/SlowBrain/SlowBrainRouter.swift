import Foundation
import CoreGraphics
import SDDCore

/// Errors that can occur during slow brain routing.
public enum SlowBrainError: Error {
    case localOnlyModeActive
    case serializationFailed
    case networkError(Error)
    case invalidResponse(statusCode: Int, body: String)
    case parsingFailed(Error)
}

/// A router that serializes the world model and communicates with a slow brain LLM.
/// Uses hybrid AX+Vision routing per ADR-008:
///   1. Serialize AX context from WorldModel snapshot
///   2. Measure AX coverage (interactive element count)
///   3. If coverage is sufficient (≥ minAXElements), use text-only AX context
///   4. If coverage is poor, fall back to vision (screenshot + AX context combined)
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
        public var model: String?          // nil = use provider default
        public var maxElementsInContext: Int = 50   // cap to avoid rate limits
        public var localOnly: Bool = false
        /// Minimum interactive elements in AX tree before falling back to vision.
        /// Below this threshold, the AX tree is considered too sparse to be useful alone.
        public var minAXElements: Int = 3

        /// Default model per provider.
        public var resolvedModel: String {
            if let m = model { return m }
            switch provider {
            case .claude:  return "claude-haiku-4-5-20251001"   // high rate limits, fast
            case .openAI:  return "gpt-4o-mini"
            }
        }

        /// Default endpoint per provider.
        public var resolvedEndpoint: URL {
            if let e = endpoint { return e }
            switch provider {
            case .claude:  return URL(string: "https://api.anthropic.com/v1/messages")!
            case .openAI:  return URL(string: "https://api.openai.com/v1/chat/completions")!
            }
        }

        public init(
            provider: Provider = .claude,
            apiKey: String? = nil,
            endpoint: URL? = nil,
            model: String? = nil,
            maxElementsInContext: Int = 50,
            localOnly: Bool = false,
            minAXElements: Int = 3
        ) {
            self.provider = provider
            self.apiKey = apiKey
            self.endpoint = endpoint
            self.model = model
            self.maxElementsInContext = maxElementsInContext
            self.localOnly = localOnly
            self.minAXElements = minAXElements
        }
    }

    public init(config: Config) {
        self.config = config
    }

    // MARK: - Public Routing (Hybrid AX + Vision per ADR-008)

    /// Routes the current screen state to the LLM for the next action step.
    ///
    /// Hybrid strategy:
    ///   1. Serialize AX context from the world model
    ///   2. Count interactive elements — if ≥ minAXElements, use AX-only path (fast, cheap)
    ///   3. If AX coverage is poor (< minAXElements), use vision path with screenshot + AX context
    public func route(goal: String, worldModel: WorldModel) async throws -> [ActionPlan] {
        guard !config.localOnly else {
            throw SlowBrainError.localOnlyModeActive
        }

        // Step 1: Serialize AX context
        let snapshot = worldModel.currentSnapshot
        let contextData: Data
        let interactiveCount: Int
        do {
            contextData = try serializeContext(from: snapshot, expanded: true)
            interactiveCount = countInteractiveElements(in: snapshot)
        } catch {
            fputs("[slow-brain] AX serialization failed: \(error) — falling back to vision-only\n", stderr)
            return try await routeVisionOnly(goal: goal, worldModel: worldModel)
        }

        // Step 2: Decide routing path based on AX coverage
        let response: Data
        if interactiveCount >= config.minAXElements {
            // Good AX coverage — use text-only path (faster, no screenshot overhead)
            fputs("[slow-brain] AX path (\(interactiveCount) interactive elements)\n", stderr)
            response = try await callLLM(with: contextData, goal: goal)
        } else {
            // Poor AX coverage — likely a web SPA, canvas, or custom-rendered UI
            // Use vision (screenshot) + whatever AX context we do have
            fputs("[slow-brain] Vision path (only \(interactiveCount) AX elements, threshold=\(config.minAXElements))\n", stderr)
            response = try await callLLMWithVision(goal: goal, axContext: contextData, worldModel: worldModel)
        }

        return try parseActionPlan(from: response)
    }

    /// Legacy overload — routes without an explicit goal (used by tests and EVAL harness).
    public func route(worldModel: WorldModel) async throws -> [ActionPlan] {
        try await route(goal: "", worldModel: worldModel)
    }

    // MARK: - Vision-First Route (for TaskOrchestrator)

    /// Vision-first routing: ALWAYS takes a screenshot on every step.
    /// Used by TaskOrchestrator during `sdd run` — the LLM must SEE the screen
    /// to determine the next action, especially for web content where AX is sparse.
    ///
    /// The action history and stuck flag let the LLM avoid repeating failed actions.
    public func routeWithVision(
        goal: String,
        worldModel: WorldModel,
        actionHistory: [ActionPlan] = [],
        isStuck: Bool = false
    ) async throws -> [ActionPlan] {
        guard !config.localOnly else {
            throw SlowBrainError.localOnlyModeActive
        }

        // Always include AX context as supplemental signal (best effort)
        let axContext: Data?
        do {
            let snapshot = worldModel.currentSnapshot
            axContext = try serializeContext(from: snapshot, expanded: true)
        } catch {
            axContext = nil
        }

        fputs("[slow-brain] Vision path (routeWithVision, history=\(actionHistory.count), stuck=\(isStuck))\n", stderr)
        let response = try await callLLMWithVision(
            goal: goal,
            axContext: axContext,
            actionHistory: actionHistory,
            isStuck: isStuck,
            worldModel: worldModel
        )
        return try parseActionPlan(from: response)
    }

    /// VNC + ShowUI-2B routing: separates planning (Claude text-only) from grounding (ShowUI local).
    ///
    /// Flow:
    ///   1. Call Claude with TEXT-ONLY context (no screenshot) → get action + element_selector
    ///   2. For each plan that needs coordinates: call ShowUI with vncFrame + element_selector
    ///   3. Map ShowUI normalized (0–1) → physical pixels via coordMapper
    ///   4. Return ActionPlans with x, y populated from ShowUI
    ///   Fallback: if ShowUI unavailable → throw error (caller uses routeWithVision)
    public func routeWithVNCAndShowUI(
        goal: String,
        vncFrame: Data,                        // JPEG from VNCClient.captureFrame()
        showUIClient: ShowUIClient?,
        coordMapper: QuartzCoordinateMapper?,
        actionHistory: [ActionPlan] = [],
        isStuck: Bool = false
    ) async throws -> [ActionPlan] {
        guard !config.localOnly else { throw SlowBrainError.localOnlyModeActive }

        // Check ShowUI availability — if unavailable, signal caller to use vision path
        let showUIAvailable = await showUIClient?.isAvailable() ?? false
        if !showUIAvailable || showUIClient == nil {
            fputs("[slow-brain] ShowUI unavailable — caller should use routeWithVision instead\n", stderr)
            throw SlowBrainError.parsingFailed(NSError(domain: "SlowBrainRouter", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "ShowUI server unavailable — use routeWithVision"]))
        }

        // Step 1: Build text-only prompt (no screenshot sent to Claude)
        let textPrompt = buildTextOnlyPrompt(
            goal: goal,
            actionHistory: actionHistory,
            isStuck: isStuck
        )

        // Step 2: Call Claude TEXT-ONLY — ask what element/action to take
        let planData = try await callWithRetry { [self] in
            try await sendTextRequest(prompt: textPrompt)
        }

        // Parse the plans (Claude returns element_selector but x/y may be nil or 0)
        var plans: [ActionPlan]
        do {
            plans = try parseActionPlan(from: planData)
        } catch {
            fputs("[slow-brain] VNC+ShowUI parse failed — falling back to vision\n", stderr)
            throw SlowBrainError.parsingFailed(error as NSError)
        }

        // Step 3: For each plan needing coordinates, call ShowUI
        var groundedPlans: [ActionPlan] = []
        for plan in plans {
            let actionLower = plan.action.lowercased()
            let needsCoords = (actionLower == "click" || actionLower == "press" || actionLower == "tap"
                               || actionLower == "type" || actionLower == "input" || actionLower == "fill"
                               || actionLower == "scroll")

            guard needsCoords,
                  !plan.elementSelector.isEmpty,
                  plan.elementSelector.lowercased() != "done"
            else {
                groundedPlans.append(plan)
                continue
            }

            // Call ShowUI for coordinate grounding
            if let result = await showUIClient!.ground(query: plan.elementSelector, imageJpeg: vncFrame),
               result.confidence > 0.5 {
                // Map ShowUI normalized (0–1) → physical pixel coordinates
                let normalizedPoint = CGPoint(x: result.x, y: result.y)
                let physicalPoint: CGPoint
                if let mapper = coordMapper {
                    physicalPoint = mapper.normalizedToPhysical(normalizedPoint)
                } else {
                    // No mapper: assume 1:1 display, multiply by common resolution
                    let displayW = CGFloat(CGDisplayPixelsWide(CGMainDisplayID()))
                    let displayH = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
                    physicalPoint = CGPoint(x: normalizedPoint.x * displayW, y: normalizedPoint.y * displayH)
                }
                fputs("[slow-brain] ShowUI grounded '\(plan.elementSelector)' → (\(Int(physicalPoint.x)), \(Int(physicalPoint.y))) conf=\(String(format: "%.2f", result.confidence))\n", stderr)

                // Rebuild ActionPlan with coordinates
                let groundedPlan = ActionPlan(
                    action: plan.action,
                    elementSelector: plan.elementSelector,
                    value: plan.value,
                    verifyCondition: plan.verifyCondition,
                    x: Int(physicalPoint.x),
                    y: Int(physicalPoint.y)
                )
                groundedPlans.append(groundedPlan)
            } else {
                fputs("[slow-brain] ShowUI low-confidence for '\(plan.elementSelector)' — using ungrounded plan\n", stderr)
                groundedPlans.append(plan)
            }
        }

        return groundedPlans
    }

    // MARK: - Vision-only fallback (when AX serialization fails entirely)

    private func routeVisionOnly(goal: String, worldModel: WorldModel) async throws -> [ActionPlan] {
        let response = try await callLLMWithVision(goal: goal, axContext: nil, worldModel: worldModel)
        return try parseActionPlan(from: response)
    }

    // MARK: - AX Context Analysis

    /// Count interactive elements in the snapshot to judge AX coverage quality.
    private func countInteractiveElements(in snapshot: WorldModelSnapshot) -> Int {
        let interactiveRoles: Set<UIElementRole> = [
            .button, .textField, .checkBox, .link, .menuItem, .comboBox, .popUpButton
        ]
        return snapshot.elements.values
            .filter {
                interactiveRoles.contains($0.role) &&
                $0.state.contains(.enabled) &&
                !($0.label ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }
            .count
    }

    // MARK: - Context Serialization

    /// Serializes a WorldModelSnapshot into a compact JSON context for the LLM.
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
            .filter {
                interactiveRoles.contains($0.role) &&
                $0.state.contains(.enabled) &&
                !($0.label ?? "").trimmingCharacters(in: .whitespaces).isEmpty  // skip unlabeled
            }
            .sorted { ($0.label ?? "") < ($1.label ?? "") }
            .prefix(config.maxElementsInContext)
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

    // MARK: - Vision Path (Screenshot + Optional AX Context + Action History)

    /// Takes a screenshot via ScreenCaptureKit, sends it to the LLM with the goal
    /// and any available AX context. Includes action history and stuck detection.
    internal func callLLMWithVision(
        goal: String,
        axContext: Data?,
        actionHistory: [ActionPlan] = [],
        isStuck: Bool = false,
        worldModel: WorldModel? = nil
    ) async throws -> Data {
        let elementsArray: [UIElement]
        if let wm = worldModel {
            elementsArray = Array(wm.currentSnapshot.elements.values)
        } else {
            elementsArray = []
        }
        let (jpegData, textIndex) = await ScreenCapture.jpegAnnotated(
            elements: elementsArray,
            maxWidth: 1280
        )

        guard let jpegData else {
            fputs("[slow-brain] screenshot failed — falling back to text-only\n", stderr)
            return try await callLLM(with: axContext ?? Data(), goal: goal)
        }

        let base64Image = jpegData.base64EncodedString()
        let displayW = ScreenCapture.displayWidth
        let displayH = ScreenCapture.displayHeight

        // Build context supplement from AX data if available
        let axSupplement: String
        if let axData = axContext,
           let axString = String(data: axData, encoding: .utf8),
           axString.count > 10 {
            axSupplement = """

            Additionally, the following UI elements were detected via the accessibility API:
            \(axString)
            """
        } else {
            axSupplement = ""
        }

        let annotationContext: String
        if !textIndex.isEmpty {
            annotationContext = """

            INTERACTIVE ELEMENTS ANNOTATION INDEX (Set-of-Marks):
            The screenshot provided has numbered red bounding-boxes over interactive elements.
            Use these EXACT coordinates whenever interacting with the corresponding element:
            \(textIndex)
            """
        } else {
            annotationContext = ""
        }

        // Build action history context
        let historyContext: String
        if !actionHistory.isEmpty {
            let historyLines = actionHistory.suffix(5).map { plan in
                let coords = plan.x.map { x in plan.y.map { y in "(\(x),\(y))" } ?? "" } ?? "(no coords)"
                let val = plan.value.map { " value='\($0)'" } ?? ""
                return "  - \(plan.action) '\(plan.elementSelector)' at \(coords)\(val)"
            }
            historyContext = """

            PREVIOUS ACTIONS (most recent last):
            \(historyLines.joined(separator: "\n"))
            """
        } else {
            historyContext = ""
        }

        // Stuck warning
        let stuckWarning: String
        if isStuck {
            stuckWarning = """

            WARNING: Your last action DID NOT alter the UI context, or formed a LOOP (e.g. A->B->A->B).
            The previous approach is NOT working. You MUST try a completely different action.
            Look carefully at the screenshot — what you tried before did not have any effect, or you keep closing the very modal you need to interact with!
            Consider: Is the right page open? Do you need to scroll? Is there a different button? Are you accidentally closing a required modal?
            Do NOT repeat the same interaction. Try something new.
            """
        } else {
            stuckWarning = ""
        }

        let prompt = """
        You are controlling a Mac computer. The screenshot shows the current screen state (\(displayW)×\(displayH) px).

        GOAL: \(goal.isEmpty ? "Analyze the screen and determine the next action." : goal)
        \(axSupplement)\(annotationContext)\(historyContext)\(stuckWarning)

        What is the SINGLE NEXT ACTION to take toward completing the goal?

        Return ONLY a JSON array with exactly one action:
        [{"action":"click","x":850,"y":400,"element_selector":"Button description","value":null,"verify_condition":null}]

        Action types:
        - "click": click at coordinates. Set "x" and "y" separately to the CENTER of the element.
        - "type": type text. First click the field, then type value.
        - "scroll": scroll the page. Set value to "up" or "down". Set "x" and "y" separately to the scroll area center.
        - "key": press a single keyboard shortcut. Set value to "Return", "Escape", "Tab", etc. "x" and "y" can be 0.
        - "wait": wait for the page to load or transition. "x" and "y" can be 0.
        - "done": goal is complete. Set "x":0, "y":0.

        Rules:
        - "x" and "y" must be exact pixel coordinates. Use the ANNOTATION INDEX to get the exact center coordinates for any numbered item!
        - element_selector is a short description for logging (e.g. "Easy Apply button").
        - Return ONLY the JSON array — no markdown, no explanation.
        - If a previous action failed to produce a change, try a DIFFERENT action or coordinate.
        """

        return try await callWithRetry { [self] in
            try await sendVisionRequest(base64Image: base64Image, prompt: prompt)
        }
    }

    // MARK: - AX-Only Path (Text Context)

    /// Sends AX context to the LLM without a screenshot.
    /// Used when AX tree has good coverage (native macOS apps, standard web forms).
    internal func callLLM(with contextData: Data, goal: String = "") async throws -> Data {
        let prompt = buildPrompt(contextData: contextData, goal: goal)

        return try await callWithRetry { [self] in
            try await sendTextRequest(prompt: prompt)
        }
    }

    // MARK: - Network Layer

    /// Retry wrapper with exponential backoff on 429.
    private func callWithRetry(_ request: @Sendable () async throws -> (Data, Int)) async throws -> Data {
        let retryDelays: [UInt64] = [5_000_000_000, 15_000_000_000, 45_000_000_000]
        var lastError: Error = SlowBrainError.invalidResponse(statusCode: -1, body: "")

        for attempt in 0...retryDelays.count {
            let (data, status) = try await request()

            if (200...299).contains(status) { return data }

            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            if status == 429, attempt < retryDelays.count {
                let delay = retryDelays[attempt]
                fputs("[slow-brain] rate limited (429) — waiting \(delay / 1_000_000_000)s\n", stderr)
                try await Task.sleep(nanoseconds: delay)
                lastError = SlowBrainError.invalidResponse(statusCode: status, body: body)
                continue
            }
            throw SlowBrainError.invalidResponse(statusCode: status, body: body)
        }
        throw lastError
    }

    /// Send a vision (image + text) request to the LLM.
    private func sendVisionRequest(base64Image: String, prompt: String) async throws -> (Data, Int) {
        var request = URLRequest(url: config.resolvedEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        setAuthHeaders(on: &request)

        let payload: [String: Any]
        if config.provider == .claude {
            payload = [
                "model": config.resolvedModel,
                "max_tokens": 256,
                "messages": [[
                    "role": "user",
                    "content": [
                        ["type": "image", "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": base64Image
                        ]],
                        ["type": "text", "text": prompt]
                    ]
                ]]
            ]
        } else {
            payload = [
                "model": config.resolvedModel,
                "max_tokens": 256,
                "messages": [[
                    "role": "user",
                    "content": [
                        ["type": "image_url", "image_url": [
                            "url": "data:image/jpeg;base64,\(base64Image)"
                        ]],
                        ["type": "text", "text": prompt]
                    ]
                ]]
            ]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        // Set a long timeout to support slow local models spinning up (Ollama default timeout issues)
        request.timeoutInterval = 300
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, status)
    }

    /// Send a text-only request to the LLM.
    private func sendTextRequest(prompt: String) async throws -> (Data, Int) {
        var request = URLRequest(url: config.resolvedEndpoint)
        request.timeoutInterval = 300
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        setAuthHeaders(on: &request)

        let payload: [String: Any] = [
            "model": config.resolvedModel,
            "max_tokens": 256,
            "messages": [["role": "user", "content": prompt]]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, status)
    }

    /// Set auth headers based on provider.
    private func setAuthHeaders(on request: inout URLRequest) {
        guard let apiKey = config.apiKey else { return }
        switch config.provider {
        case .claude:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    // MARK: - Prompt Building

    private func buildPrompt(contextData: Data, goal: String) -> String {
        let contextString = String(data: contextData, encoding: .utf8) ?? ""
        if goal.isEmpty {
            return """
            Analyze this screen state and return the next action as a JSON array.
            Screen state: \(contextString)

            Return ONLY a JSON array:
            [{"action":"click","element_selector":"Button Label","value":null,"verify_condition":null}]
            Actions: "click", "type", "scroll", "done". For scroll use value "up"/"down".
            If goal complete: [{"action":"done","element_selector":"","value":null,"verify_condition":"goal complete"}]
            """
        }
        return """
        You are a macOS computer-use agent.
        GOAL: \(goal)

        Screen (JSON — up to \(config.maxElementsInContext) interactive elements):
        \(contextString)

        Return ONLY one JSON action:
        [{"action":"click","element_selector":"Exact Label","value":null,"verify_condition":null}]
        Rules: action ∈ {click,type,scroll,done} · element_selector must match a label exactly · type needs value · scroll value="up"/"down" · done when goal complete
        """
    }

    /// Builds a text-only prompt for Claude — no screenshot, no coordinates.
    /// Claude returns element descriptions; ShowUI handles coordinate grounding separately.
    private func buildTextOnlyPrompt(
        goal: String,
        actionHistory: [ActionPlan],
        isStuck: Bool
    ) -> String {
        let historyContext: String
        if !actionHistory.isEmpty {
            let lines = actionHistory.suffix(5).map { p in
                let coords = p.x.map { x in p.y.map { y in " at (\(x),\(y))" } ?? "" } ?? ""
                return "  - \(p.action) '\(p.elementSelector)'\(coords)"
            }
            historyContext = "\n\nPREVIOUS ACTIONS (most recent last):\n" + lines.joined(separator: "\n")
        } else {
            historyContext = ""
        }

        let stuckWarning = isStuck ? """
        \n\nWARNING: The previous action did NOT change the UI or is repeating in a loop.
        You MUST try a completely different element or action type.
        """ : ""

        return """
        You are a macOS computer-use agent. The screen is not visible to you — describe elements by their visible label or role.

        GOAL: \(goal)\(historyContext)\(stuckWarning)

        What is the SINGLE NEXT ACTION to take? Return ONLY a JSON array with one action.
        Use descriptive element_selector text (e.g. "Easy Apply button", "Phone number field").
        Do NOT include x or y coordinates — a separate vision model will locate the element.

        [{"action":"click","element_selector":"Easy Apply button","value":null,"verify_condition":null,"x":0,"y":0}]

        Actions: click, type (include value), scroll (value: up/down), key (value: Return/Escape/Tab), wait, done.
        Return ONLY the JSON array.
        """
    }

    // MARK: - Response Parsing

    /// Parses the LLM response into a structured action plan.
    internal func parseActionPlan(from data: Data) throws -> [ActionPlan] {
        let decoder = JSONDecoder()

        // Helper to extract JSON from a string that might contain markdown blocks
        // It also patches common LLM JSON hallucinations (like "x":396,301)
        func extractJSON(from text: String) -> Data? {
            // First, fix instances where LLM writes "x": 123, 456 instead of "x": 123, "y": 456
            let fixPattern = "\"x\"\\s*:\\s*(\\d+)\\s*,\\s*(\\d+)"
            let fixRegex = try? NSRegularExpression(pattern: fixPattern, options: [])
            let cleanText = fixRegex?.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: "\"x\":$1,\"y\":$2") ?? text

            // Try markdown code blocks first
            let mdPattern = "```(?:json)?\\s*([\\s\\S]*?)\\s*```"
            if let regex = try? NSRegularExpression(pattern: mdPattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: cleanText, options: [], range: NSRange(cleanText.startIndex..., in: cleanText)) {
                let jsonRange = Range(match.range(at: 1), in: cleanText)!
                return String(cleanText[jsonRange]).data(using: .utf8)
            }
            // Try bare JSON array in the text: find [{...}]
            let arrayPattern = "(\\[\\s*\\{[\\s\\S]*?\\}\\s*\\])"
            if let regex = try? NSRegularExpression(pattern: arrayPattern, options: []),
               let match = regex.firstMatch(in: cleanText, options: [], range: NSRange(cleanText.startIndex..., in: cleanText)) {
                let jsonRange = Range(match.range(at: 1), in: cleanText)!
                return String(cleanText[jsonRange]).data(using: .utf8)
            }
            return cleanText.data(using: .utf8)
        }

        /// Extract text content from an LLM API response (Claude or OpenAI format).
        func extractLLMText(from data: Data) -> String? {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            // Claude format: {content: [{type: "text", text: "..."}]}
            if let contentArray = json["content"] as? [[String: Any]],
               let text = contentArray.first?["text"] as? String {
                return text
            }
            // OpenAI format: {choices: [{message: {content: "..."}}]}
            if let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let text = message["content"] as? String {
                return text
            }
            return nil
        }

        // 1. Direct JSON array decode (raw response IS the array)
        if let plan = try? decoder.decode([ActionPlan].self, from: data) {
            return plan
        }

        // 2. Extract text from LLM API response wrapper
        if let llmText = extractLLMText(from: data) {
            // Try direct decode of the extracted text
            if let textData = llmText.data(using: .utf8),
               let plan = try? decoder.decode([ActionPlan].self, from: textData) {
                return plan
            }
            // Try extracting JSON from markdown or free text
            if let jsonData = extractJSON(from: llmText),
               let plan = try? decoder.decode([ActionPlan].self, from: jsonData) {
                return plan
            }
            // Log what the LLM actually returned for debugging
            fputs("[slow-brain] LLM response text: \(llmText.prefix(500))\n", stderr)
        }

        // 3. Try extracting from raw data string if it's markdown-wrapped JSON
        if let text = String(data: data, encoding: .utf8),
           let contentData = extractJSON(from: text),
           let plan = try? decoder.decode([ActionPlan].self, from: contentData) {
            return plan
        }

        // Log raw response for debugging
        let rawPreview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
        fputs("[slow-brain] PARSE FAILED — raw response: \(rawPreview)\n", stderr)

        throw SlowBrainError.parsingFailed(NSError(domain: "SlowBrainRouter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find valid ActionPlan JSON in response"]))
    }
}
