import XCTest
@testable import BLEScout

/// Remembered positions must not get stuck when a device moves (people walk around).
final class StalenessTests: XCTestCase {
    /// Walk loops around `center` for `seconds`, hearing one device at `device(t)`.
    private func loops(around c: (Double, Double), from t0: Double, seconds: Double, radius: Double = 2.5,
                       device: (Double) -> (Double, Double), rng: inout SeededRandom) -> ([Pose], [BLESample]) {
        var poses: [Pose] = [], samples: [BLESample] = []
        var t = t0, i = 0
        while t < t0 + seconds {
            let a = (t - t0) * 0.28 // ~0.7 m/s around a 2.5 m circle
            let x = c.0 + radius * sin(a), y = c.1 + radius * cos(a)
            poses.append(Pose(t: t, x: x, y: y, heading: a + .pi / 2))
            if i % 3 == 0 {
                let d = device(t)
                let r = -60 - 25 * log10(max(hypot(d.0 - x, d.1 - y), 0.3)) + rng.gauss() * 3
                if r > -95 { samples.append(BLESample(t: t, id: "phone", name: "Someone's phone", rssi: Int(r.rounded()))) }
            }
            t += 0.1; i += 1
        }
        return (poses, samples)
    }

    /// The app's loop: every 10 s, merge a whole-scan fit, then let a recent-window fit override stale positions.
    private func run(_ poses: [Pose], _ samples: [BLESample]) -> DeviceFix? {
        var best: [String: DeviceFix] = [:]
        var t = 10.0
        while t <= (poses.last?.t ?? 0) + 5 {
            let p = poses.filter { $0.t <= t }, s = samples.filter { $0.t <= t }
            best = Localizer.mergeFixes(best, with: Localizer.analyze(samples: s, poses: p).devices)
            let rp = p.filter { $0.t > t - ScanSession.recentWindow }, rs = s.filter { $0.t > t - ScanSession.recentWindow }
            best = Localizer.reconcile(best, withRecent: Localizer.analyze(samples: rs, poses: rp).devices)
            t += 10
        }
        return best["phone"]
    }

    func testMovedDeviceIsFollowed() {
        var rng = SeededRandom(seed: 11)
        // 90 s around A while the phone sits at A; then it moves 8 m to B and we follow it there.
        let a = (0.0, 0.0), b = (8.0, 4.0)
        let (p1, s1) = loops(around: a, from: 0, seconds: 90, device: { _ in a }, rng: &rng)
        let (p2, s2) = loops(around: b, from: 90, seconds: 90, device: { _ in b }, rng: &rng)
        let fix = try! XCTUnwrap(run(p1 + p2, s1 + s2))
        XCTAssertTrue(fix.status.isPlaced)
        XCTAssertLessThan(hypot(fix.x - b.0, fix.y - b.1), 1.5, "should follow the phone to its new spot")
    }

    func testStationaryDeviceStaysPutWhenWeLeave() {
        var rng = SeededRandom(seed: 12)
        // 90 s around the phone at A, then 90 s of loops 25 m away (it's out of range there).
        let a = (0.0, 0.0)
        let (p1, s1) = loops(around: a, from: 0, seconds: 90, device: { _ in a }, rng: &rng)
        let (p2, s2) = loops(around: (0, 25), from: 90, seconds: 90, device: { _ in a }, rng: &rng)
        let fix = try! XCTUnwrap(run(p1 + p2, s1 + s2))
        XCTAssertLessThan(hypot(fix.x - a.0, fix.y - a.1), 1.5, "walking away must not move or drop it")
    }
}
