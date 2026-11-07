import XCTest
@testable import BLEScout

final class PersistenceTests: XCTestCase {
    /// Walk through `waypoints` at 0.7 m/s, sampling every device in `world` (virtual clock).
    private func walk(_ waypoints: [(Double, Double)], world: DemoWorld, seed: UInt64 = 3)
        -> (poses: [Pose], samples: [BLESample]) {
        var rng = SeededRandom(seed: seed)
        var poses: [Pose] = [], samples: [BLESample] = []
        var t = 0.0, tick = 0
        var pos = waypoints[0]
        for target in waypoints.dropFirst() {
            while hypot(target.0 - pos.0, target.1 - pos.1) > 0.07 {
                let h = atan2(target.0 - pos.0, target.1 - pos.1)
                pos = (pos.0 + sin(h) * 0.07, pos.1 + cos(h) * 0.07)
                t += 0.1; tick += 1
                poses.append(Pose(t: t, x: pos.0, y: pos.1, heading: h))
                guard tick % 3 == 0 else { continue }
                for d in world.devices {
                    let dd = d.carried ? 0.4 : max(hypot(d.x - pos.0, d.y - pos.1), 0.3)
                    let r = d.p0 - 25 * log10(dd) + rng.gauss() * 4
                    if r > -95 { samples.append(BLESample(t: t, id: d.id, name: d.name, rssi: Int(r.rounded()))) }
                }
            }
        }
        return (poses, samples)
    }

    /// Same as the app: analyse the scan so far every few seconds and merge into the remembered fixes.
    private func runSession(_ poses: [Pose], _ samples: [BLESample], namedOnly: Bool = true) -> [Cluster] {
        let named = Set(samples.compactMap { $0.name != nil ? $0.id : nil })
        var best: [String: DeviceFix] = [:]
        var t = 10.0
        while t <= (poses.last?.t ?? 0) + 5 {
            let p = poses.filter { $0.t <= t }
            let s = samples.filter { $0.t <= t && (!namedOnly || named.contains($0.id)) }
            best = Localizer.mergeFixes(best, with: Localizer.analyze(samples: s, poses: p).devices)
            t += 10
        }
        let fixes = best.values.filter { (!namedOnly || $0.named) && $0.status.isPlaced }
        return Localizer.makeClusters(Array(fixes), link: 1.5)
    }

    func testHotSpotsSurviveWalkingFarAway() {
        let world = DemoWorld(seed: 42)
        // Tour the room (devices are at roughly x -3...4, y 0...6), then walk 25 m away and linger.
        let tour: [(Double, Double)] = [(0, 0), (3, 1), (3, 6), (1, 7), (-3, 6), (-3, 1), (0, 3), (2.5, 4.5),
                                        (-2, 3), (0, 0)]
        let away: [(Double, Double)] = [(0, 0), (0, 25), (6, 25), (6, 31), (0, 31), (0, 25), (6, 25), (6, 31)]
        let (poses, samples) = walk(tour + away.dropFirst(), world: world)

        let clusters = runSession(poses, samples)
        let group = Set(world.devices.filter { ["AirPods Pro", "Apple Watch", "Galaxy Buds2"].contains($0.name ?? "") }.map(\.id))
        let speakers = Set(world.devices.filter { ["JBL Flip 5", "Bose QC45"].contains($0.name ?? "") }.map(\.id))
        XCTAssertTrue(clusters.contains { Set($0.deviceIDs).intersection(group).count >= 2 },
                      "the 3-device group should still be a hot spot after walking away")
        XCTAssertTrue(clusters.contains { Set($0.deviceIDs) == speakers },
                      "the speaker pair should still be a hot spot after walking away")
    }

    func testMergeKeepsConfidentFixAndAcceptsBetterOnes() {
        let good = DeviceFix(id: "d", name: "Speaker", status: .located, x: 1, y: 1, radius: 0.8, readings: 20, medianRSSI: -60)
        let worse = DeviceFix(id: "d", name: "Speaker", status: .uncertain, x: 9, y: 9, radius: 4, readings: 40, medianRSSI: -80)
        let better = DeviceFix(id: "d", name: "Speaker", status: .located, x: 1.2, y: 1.1, radius: 0.6, readings: 50, medianRSSI: -65)
        var m = Localizer.mergeFixes([:], with: [good])
        m = Localizer.mergeFixes(m, with: [worse])
        XCTAssertEqual(m["d"]?.x, 1)          // stayed put
        XCTAssertEqual(m["d"]?.status, .located)
        m = Localizer.mergeFixes(m, with: [better])
        XCTAssertEqual(m["d"]?.x, 1.2)        // improved
        let carried = DeviceFix(id: "d", name: "Speaker", status: .carried, readings: 60, medianRSSI: -45)
        XCTAssertEqual(Localizer.mergeFixes(m, with: [carried])["d"]?.status, .carried)
    }

    func testBrieflyHeardDeviceStillGetsRoughPosition() {
        // walk a straight line; a slow beacon at (2, 5) is only heard twice, near the closest point
        var poses: [Pose] = []
        for i in 0...100 { poses.append(Pose(t: Double(i) * 0.1, x: 0, y: Double(i) * 0.1, heading: 0)) }
        let samples = [BLESample(t: 4.6, id: "slow", name: "Slow beacon", rssi: -68),
                       BLESample(t: 5.1, id: "slow", name: "Slow beacon", rssi: -66)]
        let r = Localizer.analyze(samples: samples, poses: poses)
        let d = try! XCTUnwrap(r.devices.first)
        XCTAssertEqual(d.status, .approximate)
        XCTAssertLessThan(hypot(d.x - 0, d.y - 5), 1.0)         // near where it was loudest
        XCTAssertGreaterThanOrEqual(d.radius, hypot(2, 0) - 0.5) // radius covers its real distance
        XCTAssertEqual(r.clusters.count, 1)                      // and it counts as a hot spot

        // a rough fix is upgraded when a proper one arrives, but never replaces one
        var m = Localizer.mergeFixes([:], with: [d])
        let proper = DeviceFix(id: "slow", name: "Slow beacon", status: .located, x: 2, y: 5, radius: 0.9, readings: 9, medianRSSI: -65)
        m = Localizer.mergeFixes(m, with: [proper])
        XCTAssertEqual(m["slow"]?.status, .located)
        m = Localizer.mergeFixes(m, with: [d])
        XCTAssertEqual(m["slow"]?.x, 2)
    }

    func testUnnamedDevicesAreMappedWhenIncluded() {
        let world = DemoWorld(seed: 42)
        let tour: [(Double, Double)] = [(0, 0), (3, 1), (3, 6), (1, 7), (-3, 6), (-3, 1), (0, 3), (2.5, 4.5), (-2, 3), (0, 0)]
        let (poses, samples) = walk(tour, world: world)
        let r = Localizer.analyze(samples: samples, poses: poses)
        let unnamed = r.devices.filter { !$0.named }
        XCTAssertFalse(unnamed.isEmpty)
        XCTAssertTrue(unnamed.allSatisfy { $0.name.hasPrefix("Unnamed") })
        // the unnamed phone sitting with the 3-device group joins that hot spot
        let withUnnamed = runSession(poses, samples, namedOnly: false)
        let namedOnly = runSession(poses, samples, namedOnly: true)
        XCTAssertGreaterThan(withUnnamed.map(\.count).reduce(0, +), namedOnly.map(\.count).reduce(0, +))
    }
}
