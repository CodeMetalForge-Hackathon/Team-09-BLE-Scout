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
    var roughCount = 0          // devices without a confident position
    /// Set by "spin to pinpoint": a more precise spot to head for than the hot spot's centre.
    var pinX: Double? = nil
    var pinY: Double? = nil
    var pinNote: String? = nil
    /// A relayed signal from another phone ("find this device"), not one of our own hot spots.
    var external = false
    var relayNote: String? = nil
    /// Device names to match against our own scan (a dispatched hot spot can hold several).
    var relayNames: [String]? = nil
    var matchNames: [String] { relayNames ?? names }
    /// Identifies a relayed signal across updates (its name).
    var externalKey: String? = nil
    var count: Int { deviceIDs.count }
    var pinned: Bool { pinX != nil }
    /// Ranking weight: confidently placed devices count 1, rough ones 0.5.
    var score: Double { Double(count - roughCount) + 0.5 * Double(roughCount) }
    var allRough: Bool { roughCount == count }

    /// Where to walk to: the pinpointed spot if there is one, else the hot spot's centre.
    var goalX: Double { pinX ?? x }
    var goalY: Double { pinY ?? y }

    /// How close counts as "there": 1 m for a pinpointed spot, else the hot spot's size
    /// plus its position error (1-3 m).
    var arrivalRadius: Double { pinned ? 1.0 : max(1.0, min(spread + uncertainty, 2.0)) }
}

/// Keeps an ordered plan of hot spots to visit: most devices first.
struct MissionPlanner {
    private(set) var targets: [MissionTarget] = []
    /// Once navigation to a target starts it stays the target (no switching mid-walk) until
    /// it's cleared or skipped. Re-ranking only changes what comes after it.
    private(set) var lockedID: UUID?

    /// Smoothing for the locked target's position: ignore wobble under this many metres,
    /// and move this fraction of the way to each new estimate.
    static let wobble = 0.5
    static let follow = 0.3

    /// The target to head for now: the locked one if any, else the best-ranked.
    var current: MissionTarget? {
        if let l = lockedID, let t = targets.first(where: { $0.id == l && $0.status != .cleared }) { return t }
        return targets.first { $0.status == .pending } ?? targets.first { $0.status == .skipped }
    }
    /// Still to visit, in order: the locked target first.
    var remaining: [MissionTarget] {
        let open = targets.filter { $0.status != .cleared }
        guard let l = lockedID, let i = open.firstIndex(where: { $0.id == l }) else { return open }
        var out = open
        out.insert(out.remove(at: i), at: 0)
        return out
    }

    /// Start (or keep) navigating: lock onto the current target if nothing is locked yet.
    mutating func lockCurrent() {
        if let l = lockedID, targets.contains(where: { $0.id == l && $0.status != .cleared }) { return }
        lockedID = current?.id
    }

    /// Ease a locked target toward a new estimate instead of jumping.
    private static func smoothed(_ old: Double, _ new: Double, moved: Double) -> Double {
        moved < wobble ? old : old + follow * (new - old)
    }
    var clearedCount: Int { targets.filter { $0.status == .cleared }.count }

    /// Merge freshly computed hot spots into the plan, keep cleared/skipped state,
    /// and re-rank what's left.
    mutating func update(with clusters: [Cluster], from pose: Pose?) {
        var matched = Set<UUID>()
        for c in clusters {
            let devs = Set(c.deviceIDs)
            // the existing target sharing the most devices with this hot spot
            let best = targets.indices
                .filter { !matched.contains(targets[$0].id) && !targets[$0].external }
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
                if targets[i].id == lockedID {
                    let moved = hypot(c.x - targets[i].x, c.y - targets[i].y)
                    targets[i].x = Self.smoothed(targets[i].x, c.x, moved: moved)
                    targets[i].y = Self.smoothed(targets[i].y, c.y, moved: moved)
                } else {
                    targets[i].x = c.x; targets[i].y = c.y
                }
                targets[i].spread = c.spread; targets[i].uncertainty = c.uncertainty
                targets[i].roughCount = c.roughCount
            } else {
                let t = MissionTarget(id: UUID(), deviceIDs: devs, names: c.names, x: c.x, y: c.y,
                                      spread: c.spread, uncertainty: c.uncertainty, roughCount: c.roughCount)
                targets.append(t)
                matched.insert(t.id)
            }
        }
        // Pending hot spots that vanished from the analysis (devices merged elsewhere or
        // became uncertain) are dropped; cleared ones stay for the record.
        // (The locked target is never dropped mid-walk: it keeps its last position.)
        targets.removeAll { $0.status != .cleared && !$0.external && $0.id != lockedID && !matched.contains($0.id) }
        rank(from: pose)
    }

    /// Most devices first; among equals, the closer one first. Skipped ones go last.
    mutating func rank(from pose: Pose?) {
        let px = pose?.x ?? 0, py = pose?.y ?? 0
        func key(_ t: MissionTarget) -> (Int, Double, Double) {
            let order = t.status == .pending ? (t.external ? -1 : 0) : t.status == .skipped ? 1 : 2
            return (order, -t.score, hypot(t.x - px, t.y - py))
        }
        targets.sort { key($0) < key($1) }
    }

    /// Record a spin-to-pinpoint result for a target.
    mutating func pin(_ id: UUID, x: Double, y: Double, note: String) {
        guard let i = targets.firstIndex(where: { $0.id == id }) else { return }
        targets[i].pinX = x; targets[i].pinY = y; targets[i].pinNote = note
    }

    /// Add (or update) a rescue signal relayed from another phone or dispatched by the ground
    /// station. Several can queue; they rank ahead of ordinary hot spots. `lock` switches
    /// navigation to it now. `key` identifies the signal across updates (its name).
    @discardableResult
    mutating func upsertExternal(key: String, names: [String], x: Double, y: Double, radius: Double, note: String,
                                 deviceIDs: Set<String>, lock: Bool, from pose: Pose?) -> UUID {
        if let i = targets.firstIndex(where: { $0.external && $0.status != .cleared && $0.externalKey == key }) {
            let moved = hypot(x - targets[i].x, y - targets[i].y)
            targets[i].x = Self.smoothed(targets[i].x, x, moved: moved)
            targets[i].y = Self.smoothed(targets[i].y, y, moved: moved)
            targets[i].uncertainty = min(max(radius, 0.5), 3)
            targets[i].relayNote = note
            targets[i].relayNames = names
            if !deviceIDs.isEmpty { targets[i].deviceIDs = deviceIDs }
            if lock { lockedID = targets[i].id }
            rank(from: pose)
            return targets[i].id
        }
        var t = MissionTarget(id: UUID(), deviceIDs: deviceIDs, names: [key], x: x, y: y,
                              spread: 0.5, uncertainty: min(max(radius, 0.5), 3),
                              external: true, relayNote: note)
        t.relayNames = names
        t.externalKey = key
        targets.append(t)
        if lock { lockedID = t.id }  // a deliberate switch (Find it, dispatch, or a new rescue signal)
        rank(from: pose)
        return t.id
    }

    /// Head for a relayed signal now (Find it / dispatch).
    mutating func setRelayTarget(name: String, x: Double, y: Double, radius: Double, note: String,
                                 deviceIDs: Set<String>, from pose: Pose?) {
        upsertExternal(key: name, names: [name], x: x, y: y, radius: radius, note: note,
                       deviceIDs: deviceIDs, lock: true, from: pose)
    }

    /// Our own scanner has located a relayed device: ease toward our own fix for the last metres.
    mutating func refineExternal(_ id: UUID, x: Double, y: Double, radius: Double, deviceIDs: Set<String>) {
        guard let i = targets.firstIndex(where: { $0.id == id }) else { return }
        let moved = hypot(x - targets[i].x, y - targets[i].y)
        targets[i].x = Self.smoothed(targets[i].x, x, moved: moved)
        targets[i].y = Self.smoothed(targets[i].y, y, moved: moved)
        targets[i].uncertainty = min(max(radius, 0.5), 3)
        targets[i].deviceIDs = deviceIDs
        if !(targets[i].relayNote ?? "").contains("heard here") {
            targets[i].relayNote = (targets[i].relayNote ?? "") + " · now heard here too"
        }
    }

    /// Back-compat: refine the first open relayed target.
    mutating func refineRelayTarget(x: Double, y: Double, radius: Double, deviceIDs: Set<String>) {
        if let t = relayTarget { refineExternal(t.id, x: x, y: y, radius: radius, deviceIDs: deviceIDs) }
    }

    mutating func setRelayNames(_ names: [String]) {
        guard let l = lockedID, let i = targets.firstIndex(where: { $0.id == l && $0.external }) else { return }
        targets[i].relayNames = names
    }

    /// Open relayed/dispatched targets.
    var externals: [MissionTarget] { targets.filter { $0.external && $0.status != .cleared } }
    var relayTarget: MissionTarget? { externals.first }

    /// Another rescuer tagged (cleared) a target: mark ours cleared too if it's the same one.
    /// - a relayed signal: the same signal (key), or the same place (within 3 m) sharing a name
    /// - a hot spot: the same spot (within 2 m), or sharing at least half its devices nearby
    /// One shared name elsewhere on the map is not enough (hot-spot tags can list dozens).
    /// Returns true if our current target went.
    @discardableResult
    mutating func clearMatching(key: String, names: Set<String>, x: Double, y: Double) -> Bool {
        let wasCurrent = current?.id
        var hitCurrent = false
        for i in targets.indices where targets[i].status != .cleared {
            let t = targets[i]
            let dist = hypot(t.goalX - x, t.goalY - y)
            let mine = Set(t.matchNames)
            let shared = mine.intersection(names).count
            let match: Bool
            if t.external {
                match = t.externalKey == key || (dist < 3 && shared > 0)
            } else {
                match = dist < 2 || (dist < 4 && shared > 0 && Double(shared) >= 0.5 * Double(min(mine.count, names.count)))
            }
            if match {
                targets[i].status = .cleared
                if t.id == wasCurrent { hitCurrent = true }
                if t.id == lockedID { lockedID = nil }
            }
        }
        return hitCurrent
    }

    /// Forget a target entirely (e.g. it was the team's own devices).
    mutating func drop(_ id: UUID) {
        targets.removeAll { $0.id == id }
        if lockedID == id { lockedID = nil }
    }

    mutating func clearCurrent(from pose: Pose?) { setCurrent(.cleared, pose) }
    mutating func skipCurrent(from pose: Pose?) { setCurrent(.skipped, pose) }

    private mutating func setCurrent(_ s: MissionTarget.Status, _ pose: Pose?) {
        guard let c = current, let i = targets.firstIndex(where: { $0.id == c.id }) else { return }
        targets[i].status = s
        lockedID = nil  // checked in (or skipped): the next target gets locked when navigation continues
        if s == .skipped, !targets.contains(where: { $0.status == .pending }) {
            // everything left was skipped: start the skipped ones over
            for j in targets.indices where targets[j].status == .skipped && j != i { targets[j].status = .pending }
        }
        rank(from: pose)
    }

    mutating func reset() { targets = []; lockedID = nil }
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
