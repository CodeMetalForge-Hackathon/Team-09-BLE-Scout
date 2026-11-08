import XCTest
@testable import BLEScout

final class RelayTests: XCTestCase {
    private func cluster(_ x: Double, _ y: Double, _ ids: [String]) -> Cluster {
        Cluster(id: "A", x: x, y: y, names: ids, deviceIDs: ids, spread: 0.6, uncertainty: 0.6)
    }

    func testRelayedSignalGoesFirstAndSurvivesReanalysis() {
        var plan = MissionPlanner()
        let me = Pose(t: 0, x: 0, y: 0, heading: 0)
        plan.update(with: [cluster(1, 1, ["a", "b", "c", "d"])], from: me)   // a big local hot spot
        plan.setRelayTarget(name: "Galaxy Buds2", x: 8, y: 3, radius: 1.5, note: "Relayed from Alex through 2 phones",
                            deviceIDs: [], from: me)
        XCTAssertEqual(plan.current?.names, ["Galaxy Buds2"], "the relayed signal beats a bigger local hot spot")
        XCTAssertTrue(plan.current?.external ?? false)

        plan.update(with: [cluster(1.2, 1.1, ["a", "b", "c", "d"])], from: me) // next analysis
        XCTAssertEqual(plan.relayTarget?.x, 8, "re-analysing hot spots must not drop or move it")

        plan.refineRelayTarget(x: 7.4, y: 3.3, radius: 0.8, deviceIDs: ["my-id-for-buds"])
        XCTAssertEqual(plan.relayTarget?.x, 7.4)
        XCTAssertEqual(plan.relayTarget?.deviceIDs, ["my-id-for-buds"])
        XCTAssertTrue(plan.relayTarget?.relayNote?.contains("heard here") ?? false)

        plan.clearCurrent(from: me)
        XCTAssertNil(plan.relayTarget)
        XCTAssertEqual(plan.current?.count, 4, "after finding it, back to the hot spots")
    }

    func testOnlyOneRelayedTargetAtATime() {
        var plan = MissionPlanner()
        plan.setRelayTarget(name: "A", x: 1, y: 1, radius: 1, note: "", deviceIDs: [], from: nil)
        plan.setRelayTarget(name: "B", x: 2, y: 2, radius: 1, note: "", deviceIDs: [], from: nil)
        XCTAssertEqual(plan.targets.filter(\.external).map(\.names), [["B"]])
    }

    func testRelayRowDecodesFromSupabase() throws {
        let json = """
        [{"id":7,"team":"TEAM9","from_phone":"p2","from_name":"Sam","target_name":"JBL Flip 5",
          "target_x":3.5,"target_y":-1.25,"target_radius":null,"hop":1,
          "chain":[{"phone_id":"p1","name":"Alex","x":0,"y":0},{"phone_id":"p2","name":"Sam","x":2,"y":1}]}]
        """.data(using: .utf8)!
        let r = try XCTUnwrap(JSONDecoder().decode([RelayMessage].self, from: json).first)
        XCTAssertEqual(r.originName, "Alex")
        XCTAssertEqual(r.chain.count, 2)
        XCTAssertNil(r.target_radius)
    }
}
