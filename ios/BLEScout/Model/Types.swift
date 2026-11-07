import Foundation

/// Map coordinates, in metres, relative to where you pressed Start:
/// +x = to your right, +y = straight ahead (the way the phone faced at Start).

/// One Bluetooth advertisement.
struct BLESample: Codable {
    let t: TimeInterval   // system uptime, same clock as ARKit frames
    let id: String        // per-phone identifier iOS assigns to the device
    let name: String?
    let rssi: Int
}

/// Where the phone was. `heading` is in radians: 0 = start-forward, positive = turned right.
struct Pose: Codable {
    let t: TimeInterval
    let x: Double
    let y: Double
    let heading: Double
}

struct DeviceFix: Identifiable {
    enum Status: String {
        case located                                  // proper fit, within ±2.5 m
        case uncertain                                // proper fit, but noisy (> ±2.5 m)
        case approximate = "rough"                    // heard from too few spots to fit: placed near its loudest reading
        case tooFew = "too few readings"              // (kept for older saved data; no longer produced)
        case carried = "carried by you"               // loud everywhere you walk: excluded

        /// Devices that count toward hot spots and the heat map.
        var isPlaced: Bool { self == .located || self == .uncertain || self == .approximate }
        /// Higher = more trustworthy position.
        var rank: Int { switch self { case .located: 3; case .uncertain: 2; case .approximate: 1; default: 0 } }
    }
    let id: String
    var name: String
    let status: Status
    var x = 0.0, y = 0.0
    var radius = 0.0       // ~68% confidence radius, metres
    let readings: Int
    let medianRSSI: Double
    var named = true       // broadcast a name (unnamed ones are only used when the user opts in)
}

struct Cluster: Identifiable {
    let id: String          // "A", "B", ...
    let x: Double
    let y: Double
    let names: [String]
    let deviceIDs: [String]
    var roughCount = 0      // members without a confident position
    let spread: Double      // how far members sit from the centre, metres
    let uncertainty: Double // typical position error of members, metres
    var count: Int { deviceIDs.count }
    /// Devices with proper positions count fully, rough ones half.
    var score: Double { Double(count - roughCount) + 0.5 * Double(roughCount) }
}

struct HeatGrid {
    let x0: Double, y0: Double, cell: Double
    let nx: Int, ny: Int
    let values: [Double]    // row-major, ny rows of nx
    let maxValue: Double
}

struct AnalysisResult {
    let devices: [DeviceFix]
    let clusters: [Cluster]
    let heat: HeatGrid?
}

struct NearbyDevice: Identifiable {
    let id: String
    let name: String
    let rssi: Int
}

// MARK: - Direction helpers

enum Direction {
    /// "3.4 m · ahead-left" from a pose to a point.
    static func describe(from p: Pose, toX x: Double, y: Double) -> String {
        let dx = x - p.x, dy = y - p.y
        let dist = (dx * dx + dy * dy).squareRoot()
        if dist < 0.7 { return "right here" }
        var rel = atan2(dx, dy) - p.heading
        while rel > .pi { rel -= 2 * .pi }
        while rel < -.pi { rel += 2 * .pi }
        let deg = abs(rel * 180 / .pi)
        let side = rel > 0 ? "right" : "left"
        let dir: String
        switch deg {
        case ..<20: dir = "straight ahead"
        case ..<70: dir = "ahead-\(side)"
        case ..<110: dir = "to your \(side)"
        case ..<160: dir = "behind-\(side)"
        default: dir = "behind you"
        }
        return String(format: "%.1f m · %@", dist, dir)
    }

    /// Angle to turn (radians, + = right) to face the point.
    static func relativeAngle(from p: Pose, toX x: Double, y: Double) -> Double {
        var rel = atan2(x - p.x, y - p.y) - p.heading
        while rel > .pi { rel -= 2 * .pi }
        while rel < -.pi { rel += 2 * .pi }
        return rel
    }

    /// "2.1 m right, 4.0 m ahead of start"
    static func fromStart(x: Double, y: Double) -> String {
        let lr = String(format: "%.1f m %@", abs(x), x >= 0 ? "right" : "left")
        let fb = String(format: "%.1f m %@", abs(y), y >= 0 ? "ahead" : "behind")
        return "\(lr), \(fb) of start"
    }
}
