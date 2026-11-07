import XCTest
@testable import BLEScout

/// Guards against hot spots popping up where you're standing (your own / your team's devices).
final class SensitivityTests: XCTestCase {
    private func line(to y: Double) -> [Pose] {
        stride(from: 0.0, through: y, by: 0.07).enumerated().map { Pose(t: Double($0.offset) * 0.1, x: 0, y: $0.element, heading: 0) }
    }

    func testNothingRoughIsPlacedBeforeWalkingAFewMetres() {
        // standing still-ish (walked 1 m): a loud device heard twice right where you are
        let poses = line(to: 1.0)
        let samples = [BLESample(t: 0.2, id: "watch", name: "My Watch", rssi: -48),
                       BLESample(t: 0.9, id: "watch", name: "My Watch", rssi: -47)]
        let r = Localizer.analyze(samples: samples, poses: poses)
        XCTAssertEqual(r.devices.first?.status, .tooFew)
        XCTAssertTrue(r.clusters.isEmpty, "no hot spot at your feet at the start")
    }

    func testDeviceTravellingWithYouIsIgnoredAfterShortWalk() {
        // walk 2 m with a device that stays loud the whole way
        let poses = line(to: 2.0)
        var rng = SeededRandom(seed: 9)
        let samples = poses.enumerated().compactMap { i, p -> BLESample? in
            i % 3 == 0 ? BLESample(t: p.t, id: "buds", name: "My AirPods", rssi: Int(-47 + rng.gauss() * 2)) : nil
        }
        let r = Localizer.analyze(samples: samples, poses: poses)
        XCTAssertEqual(r.devices.first?.status, .carried)
        XCTAssertTrue(r.clusters.isEmpty)
    }

    func testRoughOnlyHotSpotsRankBelowConfidentOnes() {
        var plan = MissionPlanner()
        let rough = Cluster(id: "A", x: 1, y: 1, names: ["r1", "r2"], deviceIDs: ["r1", "r2"], roughCount: 2, spread: 0.6, uncertainty: 3)
        let solid = Cluster(id: "B", x: 9, y: 9, names: ["s1", "s2"], deviceIDs: ["s1", "s2"], spread: 0.6, uncertainty: 0.8)
        plan.update(with: [rough, solid], from: Pose(t: 0, x: 0, y: 0, heading: 0))
        XCTAssertEqual(plan.current?.deviceIDs, ["s1", "s2"], "2 confident devices beat 2 rough ones, even farther away")
        XCTAssertTrue(plan.remaining.last?.allRough ?? false)
    }

    func testArrivalZoneIsAtMostTwoMetres() {
        let t = MissionTarget(id: UUID(), deviceIDs: ["a"], names: ["a"], x: 0, y: 0, spread: 1.5, uncertainty: 4)
        XCTAssertEqual(t.arrivalRadius, 2.0)
    }

    func testDroppingATargetRemovesIt() {
        var plan = MissionPlanner()
        plan.update(with: [Cluster(id: "A", x: 1, y: 1, names: ["team"], deviceIDs: ["team"], spread: 0.6, uncertainty: 0.6)], from: nil)
        plan.drop(plan.current!.id)
        XCTAssertNil(plan.current)
    }
}
