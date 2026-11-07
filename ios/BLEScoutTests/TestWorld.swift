import Foundation
@testable import BLEScout

/// Demo mode: a fake room with named and unnamed devices, and a fake walker who
/// wanders between random spots. Feeds the app exactly what ARKit and Bluetooth
/// would, so everything can be tried in the Simulator.
final class DemoWorld {
    struct Device {
        let id: String
        let name: String?
        let x: Double, y: Double
        let p0: Double
        var carried = false
    }

    var onPose: ((Pose) -> Void)?
    /// When set (Mission mode), the walker heads here and waits instead of wandering.
    var goal: (x: Double, y: Double)?
    var onSample: ((BLESample) -> Void)?

    private(set) var devices: [Device]
    private var rng: SeededRandom
    private var timer: Timer?
    private var pos = (x: 0.0, y: 0.0)
    private var heading = 0.0
    private var target = (x: 0.0, y: 3.0)
    private var tick = 0
    private let bounds = (minX: -4.0, maxX: 5.0, minY: -1.0, maxY: 8.0)
    let speed = 0.7 // m/s

    init(seed: UInt64 = 42) {
        rng = SeededRandom(seed: seed)
        var d: [Device] = []
        var r = SeededRandom(seed: seed &+ 1)
        func group(_ cx: Double, _ cy: Double, _ names: [String?], spread: Double) {
            for n in names {
                d.append(Device(id: UUID().uuidString, name: n,
                                x: cx + r.gauss() * spread, y: cy + r.gauss() * spread,
                                p0: -64 + r.uniform() * 10))
            }
        }
        group(2.5, 5.5, ["AirPods Pro", "Apple Watch", "Galaxy Buds2", nil], spread: 0.4) // a group of people
        group(-2.5, 2.5, ["JBL Flip 5", "Bose QC45", nil], spread: 0.35)
        group(3.5, 0.5, ["Tile Mate"], spread: 0)
        group(-2.0, 7.0, [nil, nil], spread: 1.0) // unnamed only: should never show up
        d.append(Device(id: UUID().uuidString, name: "My AirPods", x: 0, y: 0, p0: -50, carried: true))
        devices = d
    }

    func start() {
        pos = (0, 0); heading = 0; target = (0, 3); tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.step() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func step() {
        let dt = 0.1
        let now = ProcessInfo.processInfo.systemUptime
        tick += 1

        // Walk toward the current target; pick a new random one on arrival.
        if let goal { target = goal }
        let dx = target.x - pos.x, dy = target.y - pos.y
        let dist = (dx * dx + dy * dy).squareRoot()
        if goal != nil && dist < 0.5 {
            // arrived at the mission target: stand still and look around
            heading += 0.03
        } else if dist < 0.2 {
            target = (bounds.minX + rng.uniform() * (bounds.maxX - bounds.minX),
                      bounds.minY + rng.uniform() * (bounds.maxY - bounds.minY))
        } else {
            let want = atan2(dx, dy)
            var turn = want - heading
            while turn > .pi { turn -= 2 * .pi }
            while turn < -.pi { turn += 2 * .pi }
            heading += max(-0.25, min(0.25, turn)) // turn smoothly
            pos.x += sin(heading) * speed * dt
            pos.y += cos(heading) * speed * dt
        }
        onPose?(Pose(t: now, x: pos.x, y: pos.y, heading: heading))

        // Each device advertises ~3 times a second; some adverts get missed.
        guard tick % 3 == 0 else { return }
        for d in devices where rng.uniform() < 0.85 {
            let dd = d.carried ? 0.4 : max(((d.x - pos.x) * (d.x - pos.x) + (d.y - pos.y) * (d.y - pos.y)).squareRoot(), 0.3)
            let rssi = d.p0 - 25 * log10(dd) + rng.gauss() * 4
            if rssi > -95 {
                onSample?(BLESample(t: now, id: d.id, name: d.name, rssi: Int(rssi.rounded())))
            }
        }
    }
}

/// Small deterministic random generator (SplitMix64) so demo runs are repeatable.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func gauss() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
