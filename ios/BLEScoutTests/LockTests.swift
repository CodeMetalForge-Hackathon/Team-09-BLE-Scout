import XCTest
@testable import BLEScout

/// Navigation must not jump between hot spots mid-walk.
final class LockTests: XCTestCase {
    private func c(_ x: Double, _ y: Double, _ ids: [String]) -> Cluster {
        Cluster(id: "?", x: x, y: y, names: ids, deviceIDs: ids, spread: 0.6, uncertainty: 0.6)
    }
    private let me = Pose(t: 0, x: 0, y: 0, heading: 0)

    func testLockedTargetSurvivesReRankingUntilCheckedIn() {
        var plan = MissionPlanner()
        plan.update(with: [c(2, 2, ["a", "b"]), c(8, 8, ["x"])], from: me)
        plan.lockCurrent()
        XCTAssertEqual(plan.current?.deviceIDs, ["a", "b"])

        // the other hot spot grows bigger: without the lock it would take over
        plan.update(with: [c(2, 2, ["a", "b"]), c(8, 8, ["x", "y", "z", "w"])], from: me)
        plan.lockCurrent()
        XCTAssertEqual(plan.current?.deviceIDs, ["a", "b"], "stays on the locked target")
        XCTAssertEqual(plan.remaining.first?.deviceIDs, ["a", "b"], "locked target listed first")

        // check in -> straight on to the next (now biggest) one, which locks
        plan.clearCurrent(from: me)
        plan.lockCurrent()
        XCTAssertEqual(plan.current?.deviceIDs, ["x", "y", "z", "w"])
        XCTAssertEqual(plan.lockedID, plan.current?.id)
    }

    func testLockedTargetIsNotDroppedWhenAnalysisLosesIt() {
        var plan = MissionPlanner()
        plan.update(with: [c(2, 2, ["a", "b"]), c(8, 8, ["x"])], from: me)
        plan.lockCurrent()
        plan.update(with: [c(8, 8, ["x"])], from: me) // "a","b" briefly missing
        plan.lockCurrent()
        XCTAssertEqual(plan.current?.deviceIDs, ["a", "b"])
        XCTAssertEqual(plan.current?.x, 2, "keeps its last position")
    }

    func testLockedTargetMovesSmoothlyAndIgnoresWobble() {
        var plan = MissionPlanner()
        plan.update(with: [c(2, 2, ["a", "b"])], from: me)
        plan.lockCurrent()
        plan.update(with: [c(2.3, 2.2, ["a", "b"])], from: me) // < 0.5 m wobble
        XCTAssertEqual(plan.current?.x, 2)
        plan.update(with: [c(4, 2, ["a", "b"])], from: me)     // real move: eases 30% of the way
        XCTAssertEqual(plan.current?.x ?? 0, 2.6, accuracy: 1e-9)
    }

    func testDispatchOrRelaySwitchesImmediately() {
        var plan = MissionPlanner()
        plan.update(with: [c(2, 2, ["a", "b"])], from: me)
        plan.lockCurrent()
        plan.setRelayTarget(name: "SOS", x: 9, y: 9, radius: 1, note: "", deviceIDs: [], from: me)
        XCTAssertEqual(plan.current?.names, ["SOS"])
        XCTAssertEqual(plan.lockedID, plan.current?.id)
    }
}
