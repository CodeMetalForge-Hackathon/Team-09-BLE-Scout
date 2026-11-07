import Foundation

/// "Spin to pinpoint": turn a full circle in place with the phone held out in front.
/// Your body blocks Bluetooth, so a device's signal is strongest when you face it and
/// weakest when it's behind you. Fitting   rssi(θ) ≈ a + b·cos(θ − φ)   to the readings
/// gives φ, the direction of the device; b (dB) says how clear that direction is.
struct SpinReading {
    let heading: Double   // radians, same convention as Pose.heading
    let device: String
    let rssi: Double
}

struct SpinResult: Equatable {
    enum Confidence: String { case high, medium, low }
    let bearing: Double     // radians, map frame (0 = start-forward, + = right)
    let swingDB: Double     // b: how much stronger it is facing the device than facing away
    let distance: Double    // rough metres from the strongest reading
    let confidence: Confidence
    let readings: Int
}

enum SpinLocator {
    static let sectors = 24 // 15° each

    static func sector(_ heading: Double) -> Int {
        var a = heading.truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        return min(Int(a / (2 * .pi) * Double(sectors)), sectors - 1)
    }

    /// Degrees of the circle covered so far (by any heading samples).
    static func coverageDegrees(_ covered: Set<Int>) -> Double { Double(covered.count) * 360 / Double(sectors) }

    static func estimate(_ readings: [SpinReading], pathLossN n: Double = 2.5) -> SpinResult? {
        // Devices transmit at different strengths: compare each device only with itself.
        let byDevice = Dictionary(grouping: readings, by: \.device)
        var rows: [(c: Double, s: Double, y: Double)] = []
        for (_, rs) in byDevice where rs.count >= 3 {
            let mean = rs.map(\.rssi).reduce(0, +) / Double(rs.count)
            rows += rs.map { (cos($0.heading), sin($0.heading), $0.rssi - mean) }
        }
        // Need readings spread around the circle, or the direction is meaningless.
        let covered = Set(readings.map { sector($0.heading) })
        guard rows.count >= 8, covered.count >= sectors / 2 else { return nil }

        // Least squares for y = a + c·cosθ + s·sinθ  (3x3 normal equations).
        var m = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        var v = [Double](repeating: 0, count: 3)
        for r in rows {
            let x = [1, r.c, r.s]
            for i in 0..<3 { v[i] += x[i] * r.y; for j in 0..<3 { m[i][j] += x[i] * x[j] } }
        }
        guard let sol = solve3(m, v) else { return nil }
        let c = sol[1], s = sol[2]
        let swing = hypot(c, s)
        let bearing = atan2(s, c)

        // Rough distance from the loudest readings (median of the top few), assuming ~-59 dBm at 1 m.
        let top = readings.map(\.rssi).sorted(by: >).prefix(5)
        let loud = top.sorted()[top.count / 2]
        let distance = min(max(pow(10, (-59 - loud) / (10 * n)), 0.5), 6)

        let conf: SpinResult.Confidence = swing >= 4 ? .high : swing >= 2 ? .medium : .low
        return SpinResult(bearing: bearing, swingDB: swing, distance: distance, confidence: conf, readings: readings.count)
    }

    private static func solve3(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
                - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let d = det(a)
        guard abs(d) > 1e-9 else { return nil }
        return (0..<3).map { k in
            var mk = a
            for i in 0..<3 { mk[i][k] = b[i] }
            return det(mk) / d
        }
    }
}
