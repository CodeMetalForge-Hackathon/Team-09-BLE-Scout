import XCTest
@testable import BLEScout

final class MissionTests: XCTestCase {
    private func cluster(_ id: String, _ x: Double, _ y: Double, _ devices: [String]) -> Cluster {
        Cluster(id: id, x: x, y: y, names: devices, deviceIDs: devices, spread: 0.6, uncertainty: 0.6)
    }

    func testMostDevicesFirstThenNearest() {
        var plan = MissionPlanner()
        let here = Pose(t: 0, x: 0, y: 0, heading: 0)
        plan.update(with: [cluster("A", 8, 0, ["a"]),
                           cluster("B", 5, 5, ["b1", "b2", "b3"]),
                           cluster("C", 1, 0, ["c"])], from: here)
        XCTAssertEqual(plan.current?.deviceIDs, ["b1", "b2", "b3"])
        XCTAssertEqual(plan.remaining.map(\.count), [3, 1, 1])
        XCTAssertEqual(plan.remaining[1].deviceIDs, ["c"]) // 1 m away beats 8 m away
    }

    func testTargetsSurviveRelabelingAndClearedStaysCleared() {
        var plan = MissionPlanner()
        plan.update(with: [cluster("A", 2, 2, ["x", "y"]), cluster("B", 6, 6, ["z"])], from: nil)
        let firstID = plan.current!.id
        plan.clearCurrent(from: nil)
        XCTAssertEqual(plan.current?.deviceIDs, ["z"])

        // Next analysis: letters swapped, positions nudged. The cleared hot spot must not come back.
        plan.update(with: [cluster("A", 6.2, 6.1, ["z"]), cluster("B", 2.1, 2.0, ["x", "y"])], from: nil)
        XCTAssertEqual(plan.current?.deviceIDs, ["z"])
        XCTAssertEqual(plan.current?.x ?? 0, 6.2, accuracy: 1e-9)
        XCTAssertEqual(plan.targets.first { $0.id == firstID }?.status, .cleared)

        // ...unless several new devices turn up there.
        plan.update(with: [cluster("A", 2, 2, ["x", "y", "n1", "n2"]), cluster("B", 6, 6, ["z"])], from: nil)
        XCTAssertEqual(plan.current?.id, firstID)
    }

    func testSkipMovesToBackAndCycles() {
        var plan = MissionPlanner()
        plan.update(with: [cluster("A", 1, 1, ["a1", "a2"]), cluster("B", 3, 3, ["b"])], from: nil)
        plan.skipCurrent(from: nil)
        XCTAssertEqual(plan.current?.deviceIDs, ["b"])
        plan.clearCurrent(from: nil)
        XCTAssertEqual(plan.current?.deviceIDs, ["a1", "a2"]) // only the skipped one is left
    }

    func testSteeringWording() {
        XCTAssertEqual(Steering.instruction(turn: 0.1, distance: 4.25), "Straight ahead · 4.2 m")
        XCTAssertTrue(Steering.instruction(turn: 0.5, distance: 3).hasPrefix("Bear right"))
        XCTAssertTrue(Steering.instruction(turn: -1.5, distance: 3).hasPrefix("Turn left"))
        XCTAssertTrue(Steering.instruction(turn: 3.0, distance: 12).hasPrefix("Turn around · 12 m"))
    }
}
