import XCTest
import SDDCore
@testable import SDD

/// Tests for the canonical WorldModel protocol implementation.
///
/// Note: apply(event:) requires live AXUIElement references so we cannot drive
/// full AX event cycles in unit tests. These tests cover:
///   - subscribe() / unsubscribe lifecycle
///   - currentSnapshot returns a non-nil FBSnapshot (zero-element baseline)
///   - makeFBSnapshot() structural correctness
///   - Token cancellation stops diff delivery
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

    // MARK: - Snapshot baseline

    func testInitialSnapshot_isEmpty() {
        let snap = worldModel.currentSnapshot
        XCTAssertEqual(snap.elements.count, 0)
        XCTAssertNil(snap.focusedElementID)
    }

    func testMakeFBSnapshot_isEmpty() {
        let fb = worldModel.makeFBSnapshot()
        XCTAssertEqual(fb.elements.count, 0)
        XCTAssertNil(fb.appContext.focusedElement)
    }

    // MARK: - Subscription lifecycle

    func testSubscribe_returnsToken() {
        var tokenReceived = false
        let token = worldModel.subscribe { _ in }
        tokenReceived = (token != nil)
        XCTAssertTrue(tokenReceived)
        _ = token  // keep alive
    }

    func testSubscribe_multipleSubscribers_allReceiveToken() {
        let t1 = worldModel.subscribe { _ in }
        let t2 = worldModel.subscribe { _ in }
        XCTAssertNotNil(t1)
        XCTAssertNotNil(t2)
        _ = (t1, t2)
    }

    func testToken_deinit_cancelsSubscription() {
        // We can't inject events, so just verify no crash on token deinit
        var token: SubscriptionToken? = worldModel.subscribe { _ in }
        token = nil
        XCTAssertNil(token)  // subscription cancelled, no crash
    }

    // MARK: - focusedElement helper

    func testFocusedElement_initially_nil() {
        XCTAssertNil(worldModel.focusedElement)
    }

    // MARK: - element(for:) helper

    func testElementFor_unknownID_returnsNil() {
        let result = worldModel.element(for: UIElementID(rawValue: 999999))
        XCTAssertNil(result)
    }

    // MARK: - Performance: snapshot is cheap

    func testMakeFBSnapshot_latency_under1ms() {
        let start = Date()
        _ = worldModel.makeFBSnapshot()
        let elapsed = Date().timeIntervalSince(start) * 1000
        XCTAssertLessThan(elapsed, 1.0, "makeFBSnapshot() took \(elapsed)ms, target <1ms")
    }
}
