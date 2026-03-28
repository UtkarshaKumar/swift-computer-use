import XCTest
@testable import SDD

final class WorldModelTests: XCTestCase {
    var worldModel: WorldModel!
    
    override func setUp() {
        super.setUp()
        worldModel = WorldModel()
    }
    
    override func tearDown() {
        worldModel = nil
        super.tearDown()
    }
    
    // MARK: - Basic State Tests
    
    func testInitialStateIsEmpty() async {
        let state = await worldModel.currentState
        XCTAssertTrue(state.isEmpty)
    }
    
    func testElementCreation() async {
        let element = UIElement(
            id: "test-1",
            role: "button",
            label: "Submit",
            frame: CGRect(x: 10, y: 20, width: 100, height: 30)
        )
        
        await worldModel.update(with: .elementCreated(element, app: "TestApp"))
        
        let state = await worldModel.currentState
        XCTAssertEqual(state.count, 1)
        XCTAssertEqual(state.first?.id, "test-1")
        XCTAssertEqual(state.first?.label, "Submit")
    }
    
    func testElementUpdate() async {
        let element = UIElement(
            id: "test-1",
            role: "button",
            label: "Submit",
            frame: CGRect(x: 10, y: 20, width: 100, height: 30)
        )
        
        await worldModel.update(with: .elementCreated(element, app: "TestApp"))
        
        let updatedElement = UIElement(
            id: "test-1",
            role: "button",
            label: "Save",
            frame: CGRect(x: 10, y: 20, width: 100, height: 30)
        )
        
        await worldModel.update(with: .elementUpdated(updatedElement, app: "TestApp"))
        
        let retrieved = await worldModel.element(byId: "test-1")
        XCTAssertEqual(retrieved?.label, "Save")
    }
    
    func testElementDeletion() async {
        let element = UIElement(
            id: "test-1",
            role: "button",
            frame: CGRect(x: 10, y: 20, width: 100, height: 30)
        )
        
        await worldModel.update(with: .elementCreated(element, app: "TestApp"))
        await worldModel.update(with: .elementDestroyed(id: "test-1", app: "TestApp"))
        
        let state = await worldModel.currentState
        XCTAssertTrue(state.isEmpty)
    }
    
    // MARK: - Diff Tests
    
    func testDiffSinceReturnsChanges() async {
        let element = UIElement(
            id: "test-1",
            role: "button",
            frame: CGRect(x: 10, y: 20, width: 100, height: 30)
        )
        
        let startTime = Date()
        await worldModel.update(with: .elementCreated(element, app: "TestApp"))
        
        let diff = await worldModel.diff(since: startTime)
        XCTAssertEqual(diff.changedElements.count, 1)
        XCTAssertEqual(diff.activeApp, "TestApp")
    }
    
    func testDiffExcludesOldChanges() async {
        let element1 = UIElement(
            id: "test-1",
            role: "button",
            frame: CGRect(x: 10, y: 20, width: 100, height: 30)
        )
        
        await worldModel.update(with: .elementCreated(element1, app: "TestApp"))
        
        let cutoffTime = Date()
        
        // Small delay to ensure timestamp difference
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        let element2 = UIElement(
            id: "test-2",
            role: "textfield",
            frame: CGRect(x: 10, y: 60, width: 100, height: 30)
        )
        
        await worldModel.update(with: .elementCreated(element2, app: "TestApp"))
        
        let diff = await worldModel.diff(since: cutoffTime)
        XCTAssertEqual(diff.changedElements.count, 1)
        XCTAssertEqual(diff.changedElements.first?.id, "test-2")
    }
    
    func testDiffTracksRemovedIds() async {
        let element = UIElement(
            id: "test-1",
            role: "button",
            frame: CGRect(x: 10, y: 20, width: 100, height: 30)
        )
        
        let startTime = Date()
        await worldModel.update(with: .elementCreated(element, app: "TestApp"))
        await worldModel.update(with: .elementDestroyed(id: "test-1", app: "TestApp"))
        
        let diff = await worldModel.diff(since: startTime)
        XCTAssertEqual(diff.removedIds.count, 1)
        XCTAssertEqual(diff.removedIds.first, "test-1")
    }
    
    // MARK: - Focus Tests
    
    func testFocusChange() async {
        let element = UIElement(
            id: "test-1",
            role: "textfield",
            frame: CGRect(x: 10, y: 20, width: 100, height: 30)
        )
        
        await worldModel.update(with: .elementCreated(element, app: "TestApp"))
        await worldModel.update(with: .focusChanged(elementId: "test-1", app: "TestApp"))
        
        let startTime = Date()
        let diff = await worldModel.diff(since: startTime)
        XCTAssertEqual(diff.focusedElementId, "test-1")
    }
    
    func testAppChange() async {
        await worldModel.update(with: .appChanged(app: "Safari"))
        
        let startTime = Date()
        let diff = await worldModel.diff(since: startTime)
        XCTAssertEqual(diff.activeApp, "Safari")
    }
    
    // MARK: - Stream Tests
    
    func testDiffStreamEmitsUpdates() async throws {
        let element = UIElement(
            id: "test-1",
            role: "button",
            frame: CGRect(x: 10, y: 20, width: 100, height: 30)
        )
        
        var receivedDiffs: [WorldModelDiff] = []
        
        let streamTask = Task {
            for await diff in await worldModel.diffStream {
                receivedDiffs.append(diff)
                if receivedDiffs.count >= 1 { break }
            }
        }
        
        // Give stream time to set up
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        await worldModel.update(with: .elementCreated(element, app: "TestApp"))
        
        // Wait for stream to receive
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        await streamTask.value
        
        XCTAssertEqual(receivedDiffs.count, 1)
        XCTAssertEqual(receivedDiffs.first?.changedElements.first?.id, "test-1")
    }
    
    // MARK: - History Tests
    
    func testRollingHistoryLimit() async {
        // Add 150 elements (exceeds 100 limit)
        for i in 0..<150 {
            let element = UIElement(
                id: "test-\(i)",
                role: "button",
                frame: CGRect(x: 0, y: 0, width: 10, height: 10)
            )
            await worldModel.update(with: .elementCreated(element, app: "TestApp"))
        }
        
        // Diff from beginning should only show last 100
        let startTime = Date(timeIntervalSince1970: 0)
        let diff = await worldModel.diff(since: startTime)
        
        // Should have at most 100 changed elements (the last 100 created)
        XCTAssertLessThanOrEqual(diff.changedElements.count, 100)
    }
    
    // MARK: - Performance Tests
    
    func testUpdateLatency() async throws {
        let element = UIElement(
            id: "perf-test",
            role: "button",
            frame: CGRect(x: 10, y: 20, width: 100, height: 30)
        )
        
        let start = Date()
        await worldModel.update(with: .elementCreated(element, app: "TestApp"))
        let elapsed = Date().timeIntervalSince(start) * 1000 // ms
        
        // Target: <5ms for update
        XCTAssertLessThan(elapsed, 5.0, "Update took \(elapsed)ms, target is <5ms")
    }
    
    func testDiffLatency() async throws {
        // Populate with some data
        for i in 0..<100 {
            let element = UIElement(
                id: "test-\(i)",
                role: "button",
                frame: CGRect(x: 0, y: 0, width: 10, height: 10)
            )
            await worldModel.update(with: .elementCreated(element, app: "TestApp"))
        }
        
        let startTime = Date(timeIntervalSince1970: 0)
        
        let start = Date()
        _ = await worldModel.diff(since: startTime)
        let elapsed = Date().timeIntervalSince(start) * 1000 // ms
        
        // Target: <5ms for diff
        XCTAssertLessThan(elapsed, 5.0, "Diff took \(elapsed)ms, target is <5ms")
    }
    
    // MARK: - Thread Safety Tests
    
    func testConcurrentUpdates() async throws {
        let iterations = 100
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let element = UIElement(
                        id: "concurrent-\(i)",
                        role: "button",
                        frame: CGRect(x: 0, y: 0, width: 10, height: 10)
                    )
                    await self.worldModel.update(with: .elementCreated(element, app: "TestApp"))
                }
            }
        }
        
        let state = await worldModel.currentState
        // All 100 elements should be present (actor ensures thread safety)
        XCTAssertEqual(state.count, iterations)
    }
    
    func testConcurrentReadsAndWrites() async throws {
        // Start with some data
        for i in 0..<50 {
            let element = UIElement(
                id: "initial-\(i)",
                role: "button",
                frame: CGRect(x: 0, y: 0, width: 10, height: 10)
            )
            await worldModel.update(with: .elementCreated(element, app: "TestApp"))
        }
        
        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<50 {
                group.addTask {
                    let element = UIElement(
                        id: "new-\(i)",
                        role: "textfield",
                        frame: CGRect(x: 0, y: 0, width: 10, height: 10)
                    )
                    await self.worldModel.update(with: .elementCreated(element, app: "TestApp"))
                }
            }
            
            // Readers
            for _ in 0..<50 {
                group.addTask {
                    _ = await self.worldModel.currentState
                    _ = await self.worldModel.element(byId: "initial-0")
                    _ = await self.worldModel.diff(since: Date())
                }
            }
        }
        
        // Should complete without crashes or data races
        let state = await worldModel.currentState
        XCTAssertGreaterThanOrEqual(state.count, 50)
    }
}
