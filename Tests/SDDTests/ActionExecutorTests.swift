import XCTest
import ApplicationServices
// Note: In a real SPM project, we'd import the module.
// For this standalone task, we assume they are compiled together.

final class ActionExecutorTests: XCTestCase {
    var executor: ActionExecutor!
    
    override func setUp() {
        super.setUp()
        executor = ActionExecutor()
    }
    
    /// Verify that coordinateActionCount increments for valid canvas-region clicks.
    func testCoordinateActionCount() async throws {
        let element = UIElement(axElement: mockAXElement(), isCanvasRegion: true)
        _ = try await executor.execute(.mouseClick(.zero), on: element)
        XCTAssertEqual(executor.coordinateActionCount, 1, "Coordinate action count should increment")
    }
    
    /// Verify that coordinate actions on non-canvas elements are blocked (hard rule).
    func testNonCanvasCoordinateActionFails() async throws {
        let element = UIElement(axElement: mockAXElement(), isCanvasRegion: false)
        do {
            _ = try await executor.execute(.mouseClick(.zero), on: element)
            XCTFail("Should have failed for non-canvas coordinate action")
        } catch ActionError.invalidActionForElement {
            // Success: Exception caught as expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    /// Verify that the executor times out if no verify signal is received within 50ms.
    func testVerifySignalTimeout() async throws {
        // Mock a slow WorldModel observer
        executor.onWorldModelUpdate = {
            try? await Task.sleep(nanoseconds: 100 * 1_000_000) // 100ms
            return false
        }
        
        let element = UIElement(axElement: mockAXElement())
        do {
            _ = try await executor.execute(.press, on: element)
            XCTFail("Action should have timed out after 50ms")
        } catch ActionError.timeout {
            // Success: Timeout caught
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    /// Verify AXPress execution logic.
    func testAXPressAction() async throws {
        let element = UIElement(axElement: mockAXElement())
        let signal = try await executor.execute(.press, on: element)
        XCTAssertTrue(signal.success)
    }

    // MARK: - Mocks
    
    private func mockAXElement() -> AXUIElement {
        // System-wide element is a safe placeholder for non-interactive tests.
        return AXUIElementCreateSystemWide()
    }
}
