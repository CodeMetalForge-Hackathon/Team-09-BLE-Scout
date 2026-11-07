import Foundation

/// A hot spot to visit. Hot spots are re-computed (and re-lettered) every few
/// seconds as more data comes in, so a target is identified by *which devices*
/// it contains, not by its letter.
struct MissionTarget: Identifiable, Equatable {
    enum Status: String { case pending, cleared, skipped }

    let id: UUID
    var deviceIDs: Set<String>
    var names: [String]
    var x: Double
    var y: Double
    var spread: Double
    var uncertainty: Double
    var status: Status = .pending
    var count: Int { deviceIDs.count }

    /// How close counts as "there": the hot spot's size plus its position error, at least 1 m.
    var arrivalRadius: Double { max(1.0, min(spread + uncertainty, 3.0)) }
}

/// Keeps an ordered plan of hot spots to visit: most devices first.
struct MissionPlanner {
    private(set) var targets: [MissionTarget] = []

    /// The target to head for now.
    var current: MissionTarget? { targets.first { $0.status == .pending } ?? targets.first { $0.status == .skipped } }
    var remaining: [MissionTarget] { targets.filter { $0.status != .cleared } }
    var clearedCount: Int { targets.filter { $0.status == .cleared }.count }

    /// Merge freshly computed hot spots into the plan, keep cleared/skipped state,
    /// and re-rank what's left.
    mutating func update(with clusters: [Cluster], from pose: Pose?) {
        var matched = Set<UUID>()
        for c in clusters {
            let devs = Set(c.deviceIDs)
            // the existing target sharing the most devices with this hot spot
            let best = targets.indices
                .filter { !matched.contains(targets[$0].id) }
                .max { targets[$0].deviceIDs.intersection(devs).count < targets[$1].deviceIDs.intersection(devs).count }
            if let i = best, !targets[i].deviceIDs.isDisjoint(with: devs) {
                matched.insert(targets[i].id)
                if targets[i].status == .cleared {
                    // Already searched: only resurface it if clearly new devices showed up there.
                    let fresh = devs.subtracting(targets[i].deviceIDs)
                    if fresh.count >= 2 { targets[i].status = .pending } else { continue }
                }
                targets[i].deviceIDs = devs
                targets[i].names = c.names
                targets[i].x = c.x; targets[i].y = c.y
                targets[i].spread = c.spread; targets[i].uncertainty = c.uncertainty
            } else {
                let t = MissionTarget(id: UUID(), deviceIDs: devs, names: c.names, x: c.x, y: c.y,
                                      spread: c.spread, uncertainty: c.uncertainty)
                targets.append(t)
                matched.insert(t.id)
            }
        }
        // Pending hot spots that vanished from the analysis (devices merged elsewhere or
        // became uncertain) are dropped; cleared ones stay for the record.
        targets.removeAll { $0.status != .cleared && !matched.contains($0.id) }
        rank(from: pose)
    }

    /// Most devices first; among equals, the closer one first. Skipped ones go last.
    mutating func rank(from pose: Pose?) {
        let px = pose?.x ?? 0, py = pose?.y ?? 0
        func key(_ t: MissionTarget) -> (Int, Int, Double) {
            let order = t.status == .pending ? 0 : t.status == .skipped ? 1 : 2
            return (order, -t.count, hypot(t.x - px, t.y - py))
        }
        targets.sort { key($0) < key($1) }
    }

    mutating func clearCurrent(from pose: Pose?) { setCurrent(.cleared, pose) }
    mutating func skipCurrent(from pose: Pose?) { setCurrent(.skipped, pose) }

    private mutating func setCurrent(_ s: MissionTarget.Status, _ pose: Pose?) {
        guard let c = current, let i = targets.firstIndex(where: { $0.id == c.id }) else { return }
        targets[i].status = s
        if s == .skipped, !targets.contains(where: { $0.status == .pending }) {
            // everything left was skipped: start the skipped ones over
            for j in targets.indices where targets[j].status == .skipped && j != i { targets[j].status = .pending }
        }
        rank(from: pose)
    }

    mutating func reset() { targets = [] }
}

/// Plain-language steering instruction for the turn needed (radians, + = right).
enum Steering {
    static func instruction(turn rel: Double, distance: Double) -> String {
        let deg = rel * 180 / .pi, a = abs(deg)
        let side = deg > 0 ? "right" : "left"
        let dist = distance >= 10 ? String(format: "%.0f m", distance) : String(format: "%.1f m", distance)
        switch a {
        case ..<15: return "Straight ahead · \(dist)"
        case ..<45: return "Bear \(side) · \(dist)"
        case ..<135: return "Turn \(side) · \(dist)"
        default: return "Turn around · \(dist)"
        }
    }
}
