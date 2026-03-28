import Foundation
import SDDCore
import SDDBrain
import AppKit
import ApplicationServices

/// All 12 SDD MCP tool definitions and their dispatch logic.
///
/// Communication with the running `sdd` process is done exclusively through
/// files in `~/.sdd/` — this keeps the MCP server dependency-free and fast.
public enum SDDMCPTools {

    // MARK: - ~/.sdd directory

    private static var sddDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sdd")
    }

    /// Ensure `~/.sdd/` exists. Called once before any file I/O.
    private static func ensureSDDDir() {
        try? FileManager.default.createDirectory(at: sddDir, withIntermediateDirectories: true)
    }

    private static func sddFile(_ name: String) -> URL {
        sddDir.appendingPathComponent(name)
    }

    // MARK: - Tool definitions

    public static func definitions() -> [[String: Any]] {
        return [
            tool(
                name: "sdd_run",
                description: "Start an autonomous computer-use run. SDD will execute the goal step-by-step using vision + accessibility APIs. Monitor progress with sdd_status.",
                properties: [
                    "goal":       prop("string", "High-level goal to accomplish, e.g. 'Open Safari and search for Swift documentation'"),
                    "max_steps":  prop("integer", "Maximum number of steps before giving up (default: 30)"),
                    "focus_app":  prop("string", "Name of the app to focus before starting, e.g. 'Safari'"),
                ],
                required: ["goal"]
            ),
            tool(
                name: "sdd_status",
                description: "Get the current status of the active SDD run. Returns step count, current action, and completion state.",
                properties: [:],
                required: []
            ),
            tool(
                name: "sdd_stop",
                description: "Send a stop signal to the currently running SDD task. The run will halt at the next step boundary.",
                properties: [:],
                required: []
            ),
            tool(
                name: "sdd_override",
                description: "Inject a corrective instruction into the running SDD task. Applied at the next step. Use when the agent is going off-track.",
                properties: [
                    "instruction": prop("string", "Corrective instruction, e.g. 'The search box is in the top-right, not the center'"),
                ],
                required: ["instruction"]
            ),
            tool(
                name: "sdd_intervene",
                description: "Execute a single direct action in the running environment, bypassing the SDD run loop. Use for one-off corrections.",
                properties: [
                    "action":   prop("string", "Action type: click, type, scroll, key, wait"),
                    "x":        prop("integer", "Screen X coordinate for click/type"),
                    "y":        prop("integer", "Screen Y coordinate for click/type"),
                    "value":    prop("string", "Text to type, key name, or scroll direction"),
                    "selector": prop("string", "Accessibility label of target element"),
                ],
                required: ["action"]
            ),
            tool(
                name: "sdd_screenshot",
                description: "Capture the current screen state as a JPEG image. Returns the last screenshot taken by SDD (updated every step during a run).",
                properties: [
                    "annotated": prop("boolean", "If true, return screenshot with UI element annotations overlaid (when available)"),
                ],
                required: []
            ),
            tool(
                name: "sdd_elements",
                description: "Get the list of interactive UI elements currently visible on screen, as extracted by the accessibility layer.",
                properties: [:],
                required: []
            ),
            tool(
                name: "sdd_execute",
                description: "Queue a single UI action for immediate execution (no run loop). Useful for one-off interactions.",
                properties: [
                    "action":   prop("string", "Action type: click, type, scroll, key, wait"),
                    "selector": prop("string", "Accessibility label of target element"),
                    "x":        prop("integer", "Screen X coordinate"),
                    "y":        prop("integer", "Screen Y coordinate"),
                    "value":    prop("string", "Text to type, key name, or scroll direction"),
                ],
                required: ["action"]
            ),
            tool(
                name: "sdd_ground",
                description: "Use ShowUI-2B visual grounding to find the screen coordinates of a UI element described in natural language.",
                properties: [
                    "query": prop("string", "Natural language description of the element to locate, e.g. 'the blue Submit button'"),
                ],
                required: ["query"]
            ),
            tool(
                name: "sdd_record",
                description: "Request a workflow recording session. SDD will watch you perform the task once and learn it as a reusable workflow.",
                properties: [
                    "task_name": prop("string", "Name for the workflow to record, e.g. 'upload_file_to_drive'"),
                ],
                required: ["task_name"]
            ),
            tool(
                name: "sdd_workflows",
                description: "List all available workflows: built-in primitives and learned workflows recorded by sdd_record.",
                properties: [:],
                required: []
            ),
            tool(
                name: "sdd_run_workflow",
                description: "Execute a named workflow (built-in or learned). Faster and more reliable than a full sdd_run for known tasks.",
                properties: [
                    "name":   prop("string", "Workflow name, e.g. 'open_url' or 'upload_file_to_drive'"),
                    "params": prop("object", "Parameters for the workflow, e.g. {\"url\": \"https://swift.org\"}"),
                ],
                required: ["name"]
            ),
        ]
    }

    // MARK: - Tool dispatch

    public static func handle(_ params: [String: Any]) -> [String: Any] {
        ensureSDDDir()

        let toolName = str(params, "_tool") ?? ""

        switch toolName {
        case "sdd_run":         return handleRun(params)
        case "sdd_status":      return handleStatus()
        case "sdd_stop":        return handleStop()
        case "sdd_override":    return handleOverride(params)
        case "sdd_intervene":   return handleIntervene(params)
        case "sdd_screenshot":  return handleScreenshot(params)
        case "sdd_elements":    return handleElements()
        case "sdd_execute":     return handleExecute(params)
        case "sdd_ground":      return handleGround(params)
        case "sdd_record":      return handleRecord(params)
        case "sdd_workflows":   return handleWorkflows()
        case "sdd_run_workflow": return handleRunWorkflow(params)
        default:
            return errorContent("Unknown tool: \(toolName)")
        }
    }

    // MARK: - Individual tool handlers

    // 1. sdd_run
    private static func handleRun(_ params: [String: Any]) -> [String: Any] {
        guard let goal = str(params, "goal"), !goal.isEmpty else {
            return errorContent("sdd_run requires 'goal' parameter")
        }

        var request: [String: Any] = ["goal": goal, "requested_at": ISO8601DateFormatter().string(from: Date())]
        if let maxSteps = int(params, "max_steps") { request["max_steps"] = maxSteps }
        if let focusApp = str(params, "focus_app") { request["focus_app"] = focusApp }

        guard atomicWriteJSON(request, to: sddFile("run-request.json")) else {
            return errorContent("Failed to write run-request.json")
        }

        return textContent(toJSONString([
            "success": true,
            "message": "Run started. Use sdd_status to monitor progress.",
            "goal": goal,
        ]))
    }

    // 2. sdd_status
    private static func handleStatus() -> [String: Any] {
        let stateFile = sddFile("run-state.json")
        if let data = try? Data(contentsOf: stateFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return textContent(toJSONString(obj))
        }
        return textContent(toJSONString(["status": "idle", "message": "No active run"]))
    }

    // 3. sdd_stop
    private static func handleStop() -> [String: Any] {
        let stateFile = sddFile("run-state.json")
        var state: [String: Any]
        if let data = try? Data(contentsOf: stateFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            state = obj
        } else {
            state = [:]
        }
        state["status"] = "abort"
        _ = atomicWriteJSON(state, to: stateFile)
        return textContent(toJSONString(["success": true, "message": "Stop signal sent"]))
    }

    // 4. sdd_override
    private static func handleOverride(_ params: [String: Any]) -> [String: Any] {
        guard let instruction = str(params, "instruction"), !instruction.isEmpty else {
            return errorContent("sdd_override requires 'instruction' parameter")
        }
        let expiresAt = Date().timeIntervalSince1970 + 60
        let payload: [String: Any] = ["instruction": instruction, "expires_at": expiresAt]
        guard atomicWriteJSON(payload, to: sddFile("override.json")) else {
            return errorContent("Failed to write override.json")
        }
        return textContent(toJSONString([
            "success": true,
            "message": "Override injected. Will apply at next step.",
        ]))
    }

    // 5. sdd_intervene
    private static func handleIntervene(_ params: [String: Any]) -> [String: Any] {
        guard let action = str(params, "action"), !action.isEmpty else {
            return errorContent("sdd_intervene requires 'action' parameter")
        }
        var payload: [String: Any] = ["action": action, "queued_at": ISO8601DateFormatter().string(from: Date())]
        if let x = int(params, "x") { payload["x"] = x }
        if let y = int(params, "y") { payload["y"] = y }
        if let value = str(params, "value") { payload["value"] = value }
        if let selector = str(params, "selector") { payload["selector"] = selector }

        guard atomicWriteJSON(payload, to: sddFile("intervene.json")) else {
            return errorContent("Failed to write intervene.json")
        }
        return textContent(toJSONString([
            "success": true,
            "message": "Intervention queued. Will execute at next step.",
        ]))
    }

    // 6. sdd_screenshot
    private static func handleScreenshot(_ params: [String: Any]) -> [String: Any] {
        // Take a real live screenshot using ScreenCapture
        let screenshotFile = sddFile("last-screenshot.jpg")

        // Try to capture a live screenshot using a box to hold the result
        class ScreenshotBox: @unchecked Sendable {
            var data: Data? = nil
        }
        let box = ScreenshotBox()
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            Task {
                let result = await ScreenCapture.jpeg()
                box.data = result
                semaphore.signal()
            }
        }
        semaphore.wait()

        let data = box.data

        // Fallback to cached screenshot if live capture failed
        var finalData = data
        if finalData == nil || finalData?.isEmpty != false {
            if FileManager.default.fileExists(atPath: screenshotFile.path),
               let cachedData = try? Data(contentsOf: screenshotFile) {
                finalData = cachedData
            }
        }

        guard let data = finalData, !data.isEmpty else {
            return textContent("Screenshot failed — check Screen Recording permission in System Settings")
        }

        // Cache for sdd_ground to use
        try? data.write(to: screenshotFile)

        let base64 = data.base64EncodedString()
        let content: [[String: Any]] = [
            ["type": "image", "data": base64, "mimeType": "image/jpeg"],
            ["type": "text", "text": "Live screenshot captured"],
        ]
        return ["content": content, "isError": false]
    }

    // 7. sdd_elements
    private static func handleElements() -> [String: Any] {
        let worldModel = WorldModel()

        class SnapshotBox: @unchecked Sendable {
            var snapshot: FBSnapshot? = nil
        }
        let box = SnapshotBox()
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.accessory)
            let pids = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { $0.processIdentifier }
            for pid in pids { worldModel.scanApp(pid: pid) }
            worldModel.drainScanQueue()
            worldModel.captureFocus()
            box.snapshot = worldModel.makeFBSnapshot()
            semaphore.signal()
        }
        semaphore.wait()

        guard let snap = box.snapshot else {
            return textContent("Failed to scan UI elements")
        }

        let elements = snap.elements.map { el -> [String: Any] in
            var d: [String: Any] = ["role": el.role, "label": el.label]
            if el.frame != .zero {
                d["x"] = Int(el.frame.midX)
                d["y"] = Int(el.frame.midY)
            }
            return d
        }

        // Cache for reference
        if let data = try? JSONSerialization.data(withJSONObject: elements) {
            try? data.write(to: sddFile("last-elements.json"))
        }

        return textContent(toJSONString(["elements": elements, "count": elements.count] as [String: Any]))
    }

    // 8. sdd_execute
    private static func handleExecute(_ params: [String: Any]) -> [String: Any] {
        guard let action = str(params, "action"), !action.isEmpty else {
            return errorContent("sdd_execute requires 'action' parameter")
        }

        // Capture all parameters before entering the async closure
        let actionType = action
        let selector = str(params, "selector")
        let x = int(params, "x")
        let y = int(params, "y")
        let value = str(params, "value") ?? ""

        class MessageBox: @unchecked Sendable {
            var message: String = ""
        }
        let box = MessageBox()
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.accessory)

            switch actionType.lowercased() {
            case "click":
                if let sx = x, let sy = y {
                    // Coordinate-based click via CGEvent
                    let pt = CGPoint(x: sx, y: sy)
                    let src = CGEventSource(stateID: .hidSystemState)
                    if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left),
                       let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left) {
                        down.post(tap: .cghidEventTap)
                        up.post(tap: .cghidEventTap)
                        box.message = "Clicked at (\(sx), \(sy))"
                    } else {
                        box.message = "Failed to create CGEvent"
                    }
                } else if let sel = selector {
                    // Find element via AX scan and click at its center
                    let worldModel = WorldModel()
                    let pids = NSWorkspace.shared.runningApplications
                        .filter { $0.activationPolicy == .regular }
                        .map { $0.processIdentifier }
                    for pid in pids { worldModel.scanApp(pid: pid) }
                    worldModel.drainScanQueue()
                    let snap = worldModel.makeFBSnapshot()
                    if let el = snap.elements.first(where: { $0.label.lowercased().contains(sel.lowercased()) }) {
                        let centerX = Int(el.frame.midX)
                        let centerY = Int(el.frame.midY)
                        let pt = CGPoint(x: centerX, y: centerY)
                        let src = CGEventSource(stateID: .hidSystemState)
                        if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left),
                           let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left) {
                            down.post(tap: .cghidEventTap)
                            up.post(tap: .cghidEventTap)
                            box.message = "Clicked '\(sel)' at (\(centerX), \(centerY))"
                        } else {
                            box.message = "Failed to create click CGEvent for '\(sel)'"
                        }
                    } else {
                        box.message = "Element '\(sel)' not found"
                    }
                } else {
                    box.message = "click requires x+y or selector"
                }

            case "type":
                // Type text at current focus using CGEvent key sequence
                if !value.isEmpty {
                    for char in value {
                        let src = CGEventSource(stateID: .hidSystemState)
                        if let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                            var uniChar = char.unicodeScalars.first.map { UniChar($0.value) } ?? 0
                            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uniChar)
                            event.post(tap: .cghidEventTap)
                            let upEvent = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
                            upEvent?.post(tap: .cghidEventTap)
                        }
                    }
                    box.message = "Typed \(value.count) character(s)"
                } else {
                    box.message = "type requires 'value'"
                }

            case "scroll":
                let scrollX = x ?? 960
                let scrollY = y ?? 540
                let direction = value.isEmpty ? "down" : value
                let pt = CGPoint(x: scrollX, y: scrollY)
                let src = CGEventSource(stateID: .hidSystemState)
                let dy: Int32 = direction == "up" ? 5 : -5
                if let scrollEvent = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) {
                    scrollEvent.location = pt
                    scrollEvent.post(tap: .cghidEventTap)
                    box.message = "Scrolled \(direction) at (\(scrollX), \(scrollY))"
                } else {
                    box.message = "Failed to create scroll event"
                }

            case "key":
                // e.g. value = "cmd+l" or "return" or "escape"
                let keyName = value.lowercased()
                var keyCode: CGKeyCode = 0
                var flags: CGEventFlags = []
                if keyName.contains("cmd") || keyName.contains("command") { flags.insert(.maskCommand) }
                if keyName.contains("shift") { flags.insert(.maskShift) }
                if keyName.contains("alt") || keyName.contains("option") { flags.insert(.maskAlternate) }
                if keyName == "return" || keyName.contains("enter") { keyCode = 36 }
                else if keyName == "escape" { keyCode = 53 }
                else if keyName == "tab" { keyCode = 48 }
                else if keyName.contains("l") { keyCode = 37 }  // cmd+l for URL bar
                let src = CGEventSource(stateID: .hidSystemState)
                if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
                   let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
                    down.flags = flags
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                    box.message = "Key pressed: \(value)"
                } else {
                    box.message = "Failed to create key event"
                }

            case "wait":
                let ms = x ?? 1000
                Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
                box.message = "Waited \(ms)ms"

            default:
                box.message = "Unknown action: \(actionType)"
            }
            semaphore.signal()
        }
        semaphore.wait()

        return textContent(toJSONString(["success": !box.message.contains("Failed"), "result": box.message] as [String: Any]))
    }

    // 9. sdd_ground
    private static func handleGround(_ params: [String: Any]) -> [String: Any] {
        guard let query = str(params, "query"), !query.isEmpty else {
            return errorContent("sdd_ground requires 'query' parameter")
        }

        // Build request body — include last screenshot if available
        var requestBody: [String: Any] = ["query": query]
        let screenshotFile = sddFile("last-screenshot.jpg")
        if let imageData = try? Data(contentsOf: screenshotFile), !imageData.isEmpty {
            requestBody["image"] = imageData.base64EncodedString()
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return errorContent("Failed to serialize ground request")
        }

        // Synchronous HTTP POST to ShowUI grounding endpoint
        let url = URL(string: "http://127.0.0.1:7080/ground")!
        var request = URLRequest(url: url, timeoutInterval: 10.0)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        var resultText = ""
        var errorText: String? = nil

        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                errorText = "ShowUI unavailable: \(error.localizedDescription)"
                return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorText = "ShowUI returned invalid response"
                return
            }
            resultText = toJSONString(obj)
        }
        task.resume()
        semaphore.wait()

        if let err = errorText {
            return errorContent(err)
        }
        return textContent(resultText)
    }

    // 10. sdd_record
    private static func handleRecord(_ params: [String: Any]) -> [String: Any] {
        guard let taskName = str(params, "task_name"), !taskName.isEmpty else {
            return errorContent("sdd_record requires 'task_name' parameter")
        }
        let payload: [String: Any] = ["task_name": taskName, "requested_at": ISO8601DateFormatter().string(from: Date())]
        guard atomicWriteJSON(payload, to: sddFile("record-request.json")) else {
            return errorContent("Failed to write record-request.json")
        }
        return textContent(toJSONString([
            "success": true,
            "message": "Recording session requested. Run 'sdd record \(taskName)' in terminal to start.",
        ]))
    }

    // 11. sdd_workflows
    private static func handleWorkflows() -> [String: Any] {
        let builtins = ["open_url", "file_upload", "keyboard_shortcut", "scroll_to_top", "wait_for_load"]
        let learnedCount = queryLearnedWorkflowCount()
        return textContent(toJSONString([
            "builtin": builtins,
            "learned_count": learnedCount,
        ] as [String: Any]))
    }

    // 12. sdd_run_workflow
    private static func handleRunWorkflow(_ params: [String: Any]) -> [String: Any] {
        guard let name = str(params, "name"), !name.isEmpty else {
            return errorContent("sdd_run_workflow requires 'name' parameter")
        }
        var payload: [String: Any] = ["name": name, "queued_at": ISO8601DateFormatter().string(from: Date())]
        if let wfParams = params["params"] as? [String: Any] {
            payload["params"] = wfParams
        }
        guard atomicWriteJSON(payload, to: sddFile("workflow-request.json")) else {
            return errorContent("Failed to write workflow-request.json")
        }
        return textContent(toJSONString(["success": true, "message": "Workflow '\(name)' queued"]))
    }

    // MARK: - SQLite learned-rules count

    /// Returns the count of learned workflows from the SQLite database, or 0 if unavailable.
    private static func queryLearnedWorkflowCount() -> Int {
        let dbPath = sddDir.appendingPathComponent("learned-rules.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return 0 }

        // Use sqlite3 CLI to avoid importing SQLite3 and keep this target dependency-free
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, "SELECT COUNT(*) FROM learned_rules;"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // suppress errors
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            return Int(output) ?? 0
        } catch {
            return 0
        }
    }

    // MARK: - File I/O helpers

    /// Atomically write a JSON dict to a file (write to temp, then move).
    @discardableResult
    private static func atomicWriteJSON(_ dict: [String: Any], to url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) else {
            fputs("[sdd-mcp] atomicWriteJSON: serialization failed for \(url.lastPathComponent)\n", stderr)
            return false
        }
        let tmpURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        do {
            try data.write(to: tmpURL, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
            // replaceItemAt moves the tmp file; if it fails, try a direct move
            if FileManager.default.fileExists(atPath: tmpURL.path) {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: tmpURL, to: url)
            }
            return true
        } catch {
            fputs("[sdd-mcp] atomicWriteJSON error: \(error) for \(url.lastPathComponent)\n", stderr)
            return false
        }
    }

    // MARK: - Tool builder helpers

    private static func tool(
        name: String,
        description: String,
        properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        var inputSchema: [String: Any] = [
            "type": "object",
            "properties": properties,
        ]
        if !required.isEmpty {
            inputSchema["required"] = required
        }
        return [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
        ]
    }

    private static func prop(_ type: String, _ description: String) -> [String: Any] {
        return ["type": type, "description": description]
    }

    private static func str(_ args: [String: Any], _ key: String) -> String? {
        return args[key] as? String
    }

    private static func int(_ args: [String: Any], _ key: String) -> Int? {
        if let i = args[key] as? Int { return i }
        if let d = args[key] as? Double { return Int(d) }
        return nil
    }

    private static func bool(_ args: [String: Any], _ key: String) -> Bool? {
        return args[key] as? Bool
    }

    private static func textContent(_ text: String, isError: Bool = false) -> [String: Any] {
        return [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ]
    }

    private static func errorContent(_ message: String) -> [String: Any] {
        fputs("[sdd-mcp] tool error: \(message)\n", stderr)
        return textContent(message, isError: true)
    }

    // MARK: - JSON serialization helper

    private static func toJSONString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
