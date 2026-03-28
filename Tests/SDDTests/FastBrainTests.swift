import XCTest
import CoreGraphics
@testable import SDD

// MARK: - Test helpers

private let defaultViewport = CGRect(x: 0, y: 0, width: 1440, height: 900)
private let belowFoldY: CGFloat = 1100  // below the 900pt viewport height

private func makeSnapshot(
    elements: [UIElement],
    focusedElement: UIElement? = nil,
    viewportFrame: CGRect = defaultViewport
) -> WorldModelSnapshot {
    WorldModelSnapshot(
        appContext: AppContext(
            bundleID: "com.test.app",
            focusedElement: focusedElement,
            viewportFrame: viewportFrame
        ),
        elements: elements
    )
}

private func textField(
    label: String,
    focused: Bool = false,
    enabled: Bool = true,
    role: String = "AXTextField"
) -> UIElement {
    UIElement(role: role, label: label, isFocused: focused, isEnabled: enabled)
}

private func button(
    label: String,
    enabled: Bool = true,
    visible: Bool = true,
    frame: CGRect = CGRect(x: 0, y: 100, width: 100, height: 44)
) -> UIElement {
    UIElement(role: "AXButton", label: label, isEnabled: enabled, isVisible: visible, frame: frame)
}

private func checkbox(label: String, enabled: Bool = true) -> UIElement {
    UIElement(role: "AXCheckBox", label: label, isEnabled: enabled, isVisible: true)
}

private func scrollArea() -> UIElement {
    UIElement(role: "AXScrollArea", label: "Content", isVisible: true)
}

private func canvasElement(label: String) -> UIElement {
    // AXUnknown role signals a canvas region with no AX coverage
    UIElement(role: "AXUnknown", label: label, isEnabled: true, isVisible: true)
}

// MARK: - FastBrainTests

final class FastBrainTests: XCTestCase {
    let brain = FastBrain()  // default threshold: 0.85

    // =========================================================================
    // MARK: Known-Fast Tests — must NOT escalate (10 tests)
    // =========================================================================

    /// Test 1: Focused AXTextField + typeValue → AXSetValue, no escalation
    func test_fast_01_focusedTextField_typeValue() {
        let field = textField(label: "Email", focused: true)
        let snapshot = makeSnapshot(elements: [field], focusedElement: field)
        let task = TaskContext(intent: .typeValue(targetLabel: nil, value: "hello@example.com"))

        let result = brain.evaluate(snapshot: snapshot, task: task)

        assertAction(result) { action, conf in
            if case .setValue(let el, let val) = action {
                XCTAssertEqual(el.role, "AXTextField")
                XCTAssertEqual(val, "hello@example.com")
            } else {
                XCTFail("Expected setValue, got \(action)")
            }
            XCTAssertGreaterThanOrEqual(conf, brain.confidenceThreshold)
        }
    }

    /// Test 2: Focused AXTextArea + typeValue → AXSetValue, no escalation
    func test_fast_02_focusedTextArea_typeValue() {
        let field = textField(label: "Description", focused: true, role: "AXTextArea")
        let snapshot = makeSnapshot(elements: [field], focusedElement: field)
        let task = TaskContext(intent: .typeValue(targetLabel: nil, value: "Multi-line\ncontent"))

        let result = brain.evaluate(snapshot: snapshot, task: task)

        assertAction(result) { _, conf in
            XCTAssertGreaterThanOrEqual(conf, brain.confidenceThreshold)
        }
    }

    /// Test 3: Focused AXSearchField + typeValue → AXSetValue, no escalation
    func test_fast_03_focusedSearchField_typeValue() {
        let field = textField(label: "Search", focused: true, role: "AXSearchField")
        let snapshot = makeSnapshot(elements: [field], focusedElement: field)
        let task = TaskContext(intent: .typeValue(targetLabel: nil, value: "query"))

        let result = brain.evaluate(snapshot: snapshot, task: task)

        assertAction(result) { _, conf in
            XCTAssertGreaterThanOrEqual(conf, brain.confidenceThreshold)
        }
    }

    /// Test 4: Exact button "Submit" visible+enabled + pressButton("Submit") → AXPress, conf=0.97
    func test_fast_04_exactButtonMatch_submit() {
        let btn = button(label: "Submit")
        let snapshot = makeSnapshot(elements: [btn])
        let task = TaskContext(intent: .pressButton(label: "Submit"))

        let result = brain.evaluate(snapshot: snapshot, task: task)

        assertAction(result) { action, conf in
            if case .press(let el) = action {
                XCTAssertEqual(el.label, "Submit")
            } else {
                XCTFail("Expected press, got \(action)")
            }
            XCTAssertEqual(conf, 0.97)
        }
    }

    /// Test 5: Exact button "OK" visible+enabled + pressButton("OK") → AXPress, conf=0.97
    func test_fast_05_exactButtonMatch_ok() {
        let btn = button(label: "OK")
        let snapshot = makeSnapshot(elements: [btn])
        let task = TaskContext(intent: .pressButton(label: "OK"))

        let result = brain.evaluate(snapshot: snapshot, task: task)

        assertAction(result) { _, conf in
            XCTAssertGreaterThanOrEqual(conf, brain.confidenceThreshold)
        }
    }

    /// Test 6: Case-insensitive button "CANCEL" + pressButton("Cancel") → AXPress, conf=0.93
    func test_fast_06_caseInsensitiveButtonMatch() {
        let btn = button(label: "CANCEL")
        let snapshot = makeSnapshot(elements: [btn])
        let task = TaskContext(intent: .pressButton(label: "Cancel"))

        let result = brain.evaluate(snapshot: snapshot, task: task)

        assertAction(result) { _, conf in
            XCTAssertEqual(conf, 0.93)
            XCTAssertGreaterThanOrEqual(conf, brain.confidenceThreshold)
        }
    }

    /// Test 7: Checkbox "Agree" visible+enabled + pressButton("Agree") → AXPress
    func test_fast_07_checkboxMatch() {
        let box = checkbox(label: "Agree")
        let snapshot = makeSnapshot(elements: [box])
        let task = TaskContext(intent: .pressButton(label: "Agree"))

        let result = brain.evaluate(snapshot: snapshot, task: task)

        assertAction(result) { action, conf in
            if case .press(let el) = action {
                XCTAssertEqual(el.role, "AXCheckBox")
            } else {
                XCTFail("Expected press on checkbox, got \(action)")
            }
            XCTAssertGreaterThanOrEqual(conf, brain.confidenceThreshold)
        }
    }

    /// Test 8: Element frame.maxY > viewport.maxY + explicit scroll intent → AXScroll
    func test_fast_08_scrollIntent_elementBelowFold() {
        let scroll = scrollArea()
        let snapshot = makeSnapshot(elements: [scroll])
        let task = TaskContext(intent: .scroll(targetLabel: nil, direction: .down))

        let result = brain.evaluate(snapshot: snapshot, task: task)

        assertAction(result) { action, conf in
            if case .scroll(_, let dir, _) = action {
                XCTAssertEqual(dir, .down)
            } else {
                XCTFail("Expected scroll, got \(action)")
            }
            XCTAssertEqual(conf, 0.95)
        }
    }

    /// Test 9: typeValue with targetLabel, element is below fold → scroll action
    func test_fast_09_typeValue_targetBelowFold_scrollFirst() {
        let offScreenField = UIElement(
            role: "AXTextField",
            label: "City",
            isFocused: false,
            isEnabled: true,
            isVisible: false,  // not in viewport
            frame: CGRect(x: 0, y: belowFoldY, width: 300, height: 44)
        )
        let scroll = scrollArea()
        let snapshot = makeSnapshot(elements: [offScreenField, scroll])
        let task = TaskContext(intent: .typeValue(targetLabel: "City", value: "London"))

        let result = brain.evaluate(snapshot: snapshot, task: task)

        assertAction(result) { action, conf in
            if case .scroll(_, let dir, _) = action {
                XCTAssertEqual(dir, .down)
            } else {
                XCTFail("Expected scroll action for off-screen element, got \(action)")
            }
            XCTAssertGreaterThanOrEqual(conf, brain.confidenceThreshold)
        }
    }

    /// Test 10: Multiple elements present, only one exact button match → unambiguous AXPress
    func test_fast_10_multipleElements_singleExactMatch() {
        let otherField = textField(label: "Name")
        let btn = button(label: "Continue")
        let decoyBtn = button(label: "Go Back")
        let snapshot = makeSnapshot(elements: [otherField, btn, decoyBtn])
        let task = TaskContext(intent: .pressButton(label: "Continue"))

        let result = brain.evaluate(snapshot: snapshot, task: task)

        assertAction(result) { action, conf in
            if case .press(let el) = action {
                XCTAssertEqual(el.label, "Continue")
            } else {
                XCTFail("Expected press on Continue, got \(action)")
            }
            XCTAssertEqual(conf, 0.97)
        }
    }

    // =========================================================================
    // MARK: Ambiguous Tests — MUST escalate (5 tests)
    // =========================================================================

    /// Test A1: No elements at all → uncertain (conf=0.0)
    func test_ambiguous_01_noElements_escalates() {
        let snapshot = makeSnapshot(elements: [])
        let task = TaskContext(intent: .pressButton(label: "Submit"))

        let result = brain.evaluate(snapshot: snapshot, task: task)

        assertUncertain(result) { signal in
            XCTAssertEqual(signal.confidence, 0.0)
            XCTAssertLessThan(signal.confidence, brain.confidenceThreshold)
        }
    }

    /// Test A2: Matching button exists but isEnabled=false → uncertain
    func test_ambiguous_02_disabledButton_escalates() {
        let disabledBtn = button(label: "Submit", enabled: false)
        let snapshot = makeSnapshot(elements: [disabledBtn])
        let task = TaskContext(intent: .pressButton(label: "Submit"))

        let result = brain.evaluate(snapshot: snapshot, task: task)

        assertUncertain(result) { signal in
            XCTAssertLessThan(signal.confidence, brain.confidenceThreshold)
        }
    }

    /// Test A3: Two buttons with identical label "Next" → ambiguous, conf=0.60 < 0.85
    func test_ambiguous_03_duplicateButtonLabels_escalates() {
        let btn1 = button(label: "Next", frame: CGRect(x: 0, y: 100, width: 100, height: 44))
        let btn2 = button(label: "Next", frame: CGRect(x: 200, y: 100, width: 100, height: 44))
        let snapshot = makeSnapshot(elements: [btn1, btn2])
        let task = TaskContext(intent: .pressButton(label: "Next"))

        let result = brain.evaluate(snapshot: snapshot, task: task)

        assertUncertain(result) { signal in
            XCTAssertEqual(signal.confidence, 0.60, accuracy: 0.001)
            XCTAssertLessThan(signal.confidence, brain.confidenceThreshold)
        }
    }

    /// Test A4: Canvas region (AXUnknown role, no AX handle) → uncertain
    func test_ambiguous_04_canvasRegion_escalates() {
        let canvas = canvasElement(label: "Chart")
        let snapshot = makeSnapshot(elements: [canvas])
        let task = TaskContext(intent: .pressButton(label: "Chart"))

        let result = brain.evaluate(snapshot: snapshot, task: task)

        // AXUnknown is not in ButtonMatchRule's pressable roles → no match → escalate
        assertUncertain(result) { signal in
            XCTAssertLessThan(signal.confidence, brain.confidenceThreshold)
        }
    }

    /// Test A5: typeValue task but no text field is focused and label doesn't match → uncertain
    func test_ambiguous_05_noFocusedField_noLabelMatch_escalates() {
        // A button is present but no text field
        let btn = button(label: "Submit")
        let snapshot = makeSnapshot(elements: [btn])
        let task = TaskContext(intent: .typeValue(targetLabel: "Email", value: "x@y.com"))

        let result = brain.evaluate(snapshot: snapshot, task: task)

        assertUncertain(result) { signal in
            XCTAssertLessThan(signal.confidence, brain.confidenceThreshold)
        }
    }

    // =========================================================================
    // MARK: Configuration tests
    // =========================================================================

    /// Custom threshold of 0.95 causes a 0.93 case-insensitive match to escalate
    func test_config_customThreshold_higherThreshold_escalates() {
        let strictBrain = FastBrain(confidenceThreshold: 0.95)
        let btn = button(label: "CANCEL")
        let snapshot = makeSnapshot(elements: [btn])
        let task = TaskContext(intent: .pressButton(label: "Cancel"))

        let result = strictBrain.evaluate(snapshot: snapshot, task: task)

        // 0.93 < 0.95 → escalate
        assertUncertain(result) { _ in }
    }

    /// Custom threshold of 0.50 causes a case-insensitive match to resolve
    func test_config_customThreshold_lowerThreshold_resolves() {
        let lenientBrain = FastBrain(confidenceThreshold: 0.50)
        let btn = button(label: "CANCEL")
        let snapshot = makeSnapshot(elements: [btn])
        let task = TaskContext(intent: .pressButton(label: "Cancel"))

        let result = lenientBrain.evaluate(snapshot: snapshot, task: task)

        // 0.93 ≥ 0.50 → resolves
        assertAction(result) { _, _ in }
    }

    // =========================================================================
    // MARK: Assertion helpers
    // =========================================================================

    private func assertAction(
        _ result: FastBrainResult,
        file: StaticString = #file,
        line: UInt = #line,
        _ body: (ResolvedAction, Double) -> Void
    ) {
        switch result {
        case .action(let action, let conf):
            body(action, conf)
        case .uncertain(let signal):
            XCTFail(
                "Expected resolved action but got UncertaintySignal (confidence=\(signal.confidence), reason: \(signal.reason))",
                file: file,
                line: line
            )
        }
    }

    private func assertUncertain(
        _ result: FastBrainResult,
        file: StaticString = #file,
        line: UInt = #line,
        _ body: (UncertaintySignal) -> Void
    ) {
        switch result {
        case .action(let action, let conf):
            XCTFail(
                "Expected UncertaintySignal but got resolved action (conf=\(conf), action=\(action))",
                file: file,
                line: line
            )
        case .uncertain(let signal):
            body(signal)
        }
    }
}
