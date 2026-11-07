import XCTest
@testable import BLEScout

final class LocalizerTests: XCTestCase {
    /// Walk a wandering route through a fake room (same model as DemoWorld) with a virtual clock.
    private func simulate(world: DemoWorld, seconds: Double = 120) -> ([Pose], [BLESample]) {
        var rng = SeededRandom(seed: 7)
        var poses: [Pose] = [], samples: [BLESample] = []
        var x = 0.0, y = 0.0, heading = 0.0, target = (0.0, 3.0)
        var t = 0.0, tick = 0
        while t < seconds {
            t += 0.1; tick += 1
            let dx = target.0 - x, dy = target.1 - y
            if (dx * dx + dy * dy).squareRoot() < 0.2 {
                target = (-4 + rng.uniform() * 9, -1 + rng.uniform() * 9)
            } else {
                heading = atan2(dx, dy)
                x += sin(heading) * 0.07; y += cos(heading) * 0.07
            }
            poses.append(Pose(t: t, x: x, y: y, heading: heading))
            guard tick % 3 == 0 else { continue }
            for d in world.devices {
                let dd = d.carried ? 0.4 : max(hypot(d.x - x, d.y - y), 0.3)
                let r = d.p0 - 25 * log10(dd) + rng.gauss() * 4
                if r > -95 { samples.append(BLESample(t: t, id: d.id, name: d.name, rssi: Int(r.rounded()))) }
            }
        }
        // the app drops unnamed devices before analysis
        return (poses, samples.filter { $0.name != nil })
    }

    func testFindsNamedGroupsAndIgnoresCarriedDevice() {
        let world = DemoWorld(seed: 42)
        let (poses, samples) = simulate(world: world)
        let r = Localizer.analyze(samples: samples, poses: poses)

        let byName = Dictionary(uniqueKeysWithValues: r.devices.map { ($0.name, $0) })
        XCTAssertEqual(byName["My AirPods"]?.status, .carried)
        XCTAssertFalse(r.devices.contains { $0.name.isEmpty })

        // The 3-named-device group near (2.5, 5.5) should form one cluster, close to its true centre.
        let truth = world.devices.filter { ["AirPods Pro", "Apple Watch", "Galaxy Buds2"].contains($0.name ?? "") }
        let cx = truth.map(\.x).reduce(0, +) / 3, cy = truth.map(\.y).reduce(0, +) / 3
        let a = try! XCTUnwrap(r.clusters.first { $0.names.contains("Apple Watch") })
        XCTAssertGreaterThanOrEqual(a.count, 2)
        XCTAssertTrue(r.clusters.contains { Set($0.names) == ["JBL Flip 5", "Bose QC45"] })
        XCTAssertFalse(r.clusters.contains { $0.names.contains("My AirPods") })
        XCTAssertLessThan(hypot(a.x - cx, a.y - cy), 1.5)

        // Located named devices land near where they really are.
        let errs = r.devices.filter { $0.status == .located }.compactMap { d -> Double? in
            guard let t = world.devices.first(where: { $0.id == d.id }) else { return nil }
            return hypot(d.x - t.x, d.y - t.y)
        }.sorted()
        XCTAssertFalse(errs.isEmpty)
        XCTAssertLessThan(errs[errs.count / 2], 1.5)
    }

    func testPoseLookupInterpolatesAndRefusesGaps() {
        let poses = [Pose(t: 0, x: 0, y: 0, heading: 0), Pose(t: 1, x: 1, y: 0, heading: 0),
                     Pose(t: 5, x: 5, y: 0, heading: 0)]
        let l = PoseLookup(poses)
        XCTAssertEqual(l.position(at: 0.5)?.x ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertNil(l.position(at: 3))   // 4 s tracking gap
        XCTAssertNil(l.position(at: 6))   // after the walk
    }

    func testDirectionWording() {
        let me = Pose(t: 0, x: 0, y: 0, heading: 0)
        XCTAssertTrue(Direction.describe(from: me, toX: 0, y: 3).contains("straight ahead"))
        XCTAssertTrue(Direction.describe(from: me, toX: 3, y: 0).contains("to your right"))
        let turned = Pose(t: 0, x: 0, y: 0, heading: .pi / 2) // facing right
        XCTAssertTrue(Direction.describe(from: turned, toX: 0, y: 3).contains("to your left"))
        XCTAssertEqual(Direction.fromStart(x: -2, y: 4), "2.0 m left, 4.0 m ahead of start")
    }
}
