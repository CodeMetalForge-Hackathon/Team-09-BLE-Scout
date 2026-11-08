import XCTest
@testable import BLEScout

final class RescueCoordinationTests: XCTestCase {
    private func c(_ x: Double, _ y: Double, _ ids: [String]) -> Cluster {
        Cluster(id: "?", x: x, y: y, names: ids, deviceIDs: ids, spread: 0.6, uncertainty: 0.6)
    }
    private let me = Pose(t: 0, x: 0, y: 0, heading: 0)

    func testIncomingRescueSignalPreemptsAnOrdinaryHotSpot() {
        var plan = MissionPlanner()
        plan.update(with: [c(2, 2, ["a", "b", "c"])], from: me)
        plan.lockCurrent()
        XCTAssertFalse(plan.current?.external ?? true)
        plan.upsertExternal(key: "SOS phone", names: ["SOS phone"], x: 9, y: 9, radius: 1, note: "",
                            deviceIDs: [], lock: true, from: me)
        XCTAssertEqual(plan.current?.names, ["SOS phone"])
    }

    func testTaggedByAnotherRescuerIsDroppedByNameOrPlace() {
        var plan = MissionPlanner()
        plan.update(with: [c(2, 2, ["a", "b", "c"]), c(8, 8, ["x", "y", "z"])], from: me)
        plan.upsertExternal(key: "Buds", names: ["Buds"], x: 5, y: 5, radius: 1, note: "", deviceIDs: [], lock: true, from: me)
        // someone tagged the Buds (by name) ...
        XCTAssertTrue(plan.clearMatching(key: "Buds", names: ["Buds"], x: 50, y: 50), "our current target was the tagged one")
        XCTAssertTrue(plan.externals.isEmpty)
        // ... and someone tagged the hot spot at (8, 8) (by place)
        plan.clearMatching(key: "other", names: ["other"], x: 8.5, y: 8.2)
        XCTAssertEqual(plan.remaining.map(\.deviceIDs), [["a", "b", "c"]])
    }

    /// The bug from the morning test: a hot-spot tag listing 35 names (including the relayed
    /// MacBook) far from the MacBook must not silence or clear the MacBook rescue signal.
    func testBroadHotSpotTagDoesNotSilenceADifferentRescueSignal() {
        var plan = MissionPlanner()
        plan.upsertExternal(key: "Evana's MacBook Pro", names: ["Evana's MacBook Pro"], x: 6, y: 6, radius: 1,
                            note: "", deviceIDs: [], lock: true, from: me)
        let bigTag = Set((1...34).map { "dev\($0)" } + ["Evana's MacBook Pro"])
        XCTAssertFalse(plan.clearMatching(key: "dev1 · dev2 · dev3", names: bigTag, x: -1.3, y: -0.9))
        XCTAssertEqual(plan.current?.names, ["Evana's MacBook Pro"], "still navigating to the MacBook")
        // ...but a tag of the MacBook itself does clear it
        XCTAssertTrue(plan.clearMatching(key: "Evana's MacBook Pro", names: ["Evana's MacBook Pro"], x: 6, y: 6))

        func row(_ kind: String, _ name: String, _ names: [String], _ x: Double, _ y: Double) -> RelayMessage {
            RelayMessage(id: 1, team: "T", from_phone: "p", from_name: "P", target_name: name, target_x: x, target_y: y,
                         target_radius: nil, hop: 0, chain: [], kind: kind, to_phone: nil, target_names: names)
        }
        let relay = row("relay", "Evana's MacBook Pro", ["Evana's MacBook Pro"], 6, 6)
        XCTAssertFalse(RelayCenter.tag(row("cleared", "dev1 · dev2 · dev3", Array(bigTag), -1.3, -0.9), covers: relay))
        XCTAssertTrue(RelayCenter.tag(row("cleared", "dev1 · dev2", Array(bigTag), 6.5, 5.5), covers: relay), "same place")
    }

    func testBigHotSpotIsHeldWhenAnalysisDropsIt() {
        var held: [Cluster] = []
        let big = c(4, 4, (1...8).map { "d\($0)" })      // 8 devices: more than 6 -> held
        let small = c(1, 1, ["s1", "s2", "s3"])
        var out = Localizer.holdBigSpots([big, small], held: &held, minHeld: 7)
        XCTAssertEqual(out.count, 2)
        // people walk off: the next analysis only finds 4 of them (below the threshold) -> still held
        out = Localizer.holdBigSpots([c(4.2, 4.1, ["d1", "d2", "d3", "d4"]), small], held: &held, minHeld: 7)
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out.contains { $0.count == 8 && abs($0.x - 4.2) < 1e-9 },
                      "shrunk to 4 devices -> still shown as the full 8-device hot spot, at the new position")
        // gone entirely: still on the map
        out = Localizer.holdBigSpots([small], held: &held, minHeld: 7)
        XCTAssertTrue(out.contains { $0.count == 8 })
    }
}
