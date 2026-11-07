import Foundation
import SwiftUI
import UIKit

/// Ties together position tracking, Bluetooth, and the live analysis.
@MainActor
final class ScanSession: ObservableObject {
    enum Screen: String, CaseIterable, Identifiable { case scan = "Scan", mission = "Mission"; var id: String { rawValue } }

    /// Live signal from the current mission target's devices: are we getting warmer?
    struct TargetSignal { let rssi: Int; let trend: Int } // trend: +1 warmer, -1 colder, 0 steady

    /// Seconds of most recent data used to spot devices that have moved.
    nonisolated static let recentWindow: TimeInterval = 60

    @Published private(set) var running = false
    @Published private(set) var poses: [Pose] = []
    @Published private(set) var current: Pose?
    @Published private(set) var trackingStatus = "Ready"
    @Published private(set) var bluetoothStatus = "Ready"
    @Published private(set) var result: AnalysisResult?
    @Published private(set) var nearby: [NearbyDevice] = []
    @Published private(set) var namedHeard = 0
    @Published private(set) var unnamedIgnored = 0   // unnamed devices heard (ignored unless included)
    /// Also map devices that don't broadcast a name (many phones). Re-analyses the whole scan when flipped.
    @Published var includeUnnamed = false { didSet { if includeUnnamed != oldValue { reanalyze(); refreshNearby() } } }
    @Published var params = LocalizerParams()
    @Published var screen: Screen = .scan
    @Published private(set) var mission = MissionPlanner()
    @Published private(set) var arrivedTargetID: UUID?
    @Published private(set) var targetSignal: TargetSignal?
    private var signalHistory: [(t: TimeInterval, rssi: Int)] = []

    // Spin to pinpoint
    @Published private(set) var spinning = false
    @Published private(set) var spinCoverage = 0.0        // degrees of the circle covered
    @Published private(set) var spinReadings = 0
    @Published private(set) var spinOutcome: String?      // message after a spin
    private var spinTarget: UUID?
    private var spinDevices = Set<String>()
    private var spinData: [SpinReading] = []
    private var spinCovered = Set<Int>()
    private var spinStart: TimeInterval = 0

    let tracker = PoseTracker()
    let link = GroundLink()
    private var sessionStartWall: TimeInterval = 0
    private var sentPoses = 0, sentSamples = 0
    private var syncTask: Task<Void, Never>?
    private let scanner = BLEScanner()
    private var samples: [BLESample] = []
    private var allPoses: [Pose] = []          // every pose; `poses` is a throttled copy for the UI
    private var lastPosePublish: TimeInterval = 0
    private var namedIDs = Set<String>(), unnamedIDs = Set<String>()
    private var bestFixes: [String: DeviceFix] = [:]   // most confident position per device, whole session
    @Published private(set) var ignoredIDs = Set<String>() // "it's us": team / own devices, dropped for this scan
    private var knownNames: [String: String] = [:]
    private var analysisTask: Task<Void, Never>?
    private var lastNearbyUpdate: TimeInterval = 0

    var liveSupported: Bool { PoseTracker.isSupported }
    var hasData: Bool { allPoses.count > 1 }
    /// Stopped part-way: can resume without losing position.
    var paused: Bool { !running && hasData }

    init() {
        tracker.onPose = { [weak self] p in Task { @MainActor in self?.add(pose: p) } }
        tracker.onStatus = { [weak self] s in Task { @MainActor in self?.trackingStatus = s } }
        scanner.onSample = { [weak self] s in Task { @MainActor in self?.add(sample: s) } }
        scanner.onStatus = { [weak self] s in Task { @MainActor in self?.bluetoothStatus = s } }
    }

    // MARK: - Control

    /// New session: position (0, 0) = where the phone is now.
    func start() {
        guard liveSupported else { return }
        reset()
        screen = .scan
        sessionStartWall = Date().timeIntervalSince1970
        sentPoses = 0; sentSamples = 0
        trackingStatus = "Starting… move the phone slowly"
        tracker.start()
        begin()
    }

    /// Stop scanning for now; position tracking can pick up where it left off.
    func pause() {
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        analysisTask?.cancel()
        tracker.pause()
        scanner.stop()
        trackingStatus = "Paused"
        syncTask?.cancel()
        Task { await analyze(); await syncToGround() } // let the station know we paused
    }

    /// Continue the same session: ARKit keeps its coordinate frame, so hot spots stay put.
    /// Best results if you resume close to where you paused.
    func resume() {
        guard paused else { return }
        trackingStatus = "Resuming… move the phone slowly"
        tracker.resume()
        begin()
    }

    private func begin() {
        running = true
        UIApplication.shared.isIdleTimerDisabled = true // keep the screen on while walking
        scanner.start()
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.analyze()
            }
        }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.syncToGround()
            }
        }
    }

    func reset() {
        poses = []; allPoses = []; samples = []; current = nil; result = nil; nearby = []
        mission.reset(); arrivedTargetID = nil; targetSignal = nil; signalHistory = []
        namedIDs = []; unnamedIDs = []; namedHeard = 0; unnamedIgnored = 0
        bestFixes = [:]; knownNames = [:]; ignoredIDs = []
    }

    func reanalyze() { Task { await analyze() } }

    // MARK: - Data in

    private func add(pose: Pose) {
        guard running else { return }
        allPoses.append(pose)
        checkArrival(pose)
        if spinning { spinStep(pose) }
        // Redraw the screen ~4x a second, not on every 10 Hz pose: keeps taps responsive and saves battery.
        if pose.t - lastPosePublish >= 0.25 {
            lastPosePublish = pose.t
            poses = allPoses
            current = pose
        }
    }

    private func add(sample: BLESample) {
        guard running else { return }
        // Keep every reading, named or not, so the "include unnamed" switch can apply to the whole scan.
        // Many devices only send their name in some adverts, so "named" is decided per device, not per reading.
        samples.append(sample)
        if spinning, spinDevices.contains(sample.id), let h = allPoses.last?.heading {
            spinData.append(SpinReading(heading: h, device: sample.id, rssi: Double(sample.rssi)))
        }
        if let name = sample.name {
            knownNames[sample.id] = name
            if namedIDs.insert(sample.id).inserted {
                namedHeard = namedIDs.count
                unnamedIgnored = unnamedIDs.subtracting(namedIDs).count
            }
        } else if unnamedIDs.insert(sample.id).inserted {
            unnamedIgnored = unnamedIDs.subtracting(namedIDs).count
        }
        if sample.t - lastNearbyUpdate > 0.5 { updateNearby(now: sample.t) }
    }

    private func updateNearby(now: TimeInterval) {
        lastNearbyUpdate = now
        var best: [String: NearbyDevice] = [:]
        for s in samples.reversed() {
            if now - s.t > 3 { break }
            let name = knownNames[s.id]
            if name == nil && !includeUnnamed { continue }
            if ignoredIDs.contains(s.id) { continue }
            if let b = best[s.id], b.rssi >= s.rssi { continue }
            best[s.id] = NearbyDevice(id: s.id, name: name ?? "Unnamed · \(s.id.prefix(4))", rssi: s.rssi)
        }
        nearby = best.values.sorted { $0.rssi > $1.rssi }
        updateTargetSignal(now: now, loudest: best)
    }

    private func refreshNearby() {
        if let t = samples.last?.t { updateNearby(now: t) }
    }

    // MARK: - Mission

    var hasHotSpots: Bool { !(result?.clusters.isEmpty ?? true) }

    func clearTarget() {
        mission.clearCurrent(from: current)
        afterTargetChange()
    }

    func skipTarget() {
        mission.skipCurrent(from: current)
        afterTargetChange()
    }

    // MARK: - Ignore ("it's us")

    /// Drop devices that belong to the team (or you) for the rest of this scan.
    func ignore(deviceIDs: Set<String>) {
        ignoredIDs.formUnion(deviceIDs)
        for id in deviceIDs { bestFixes[id] = nil }
        for t in mission.targets where !t.deviceIDs.isDisjoint(with: deviceIDs) && t.status != .cleared {
            mission.drop(t.id)
        }
        afterTargetChange()
        reanalyze()
        refreshNearby()
    }

    func ignoreCurrentTarget() {
        if let t = mission.current { ignore(deviceIDs: t.deviceIDs) }
    }

    func restoreIgnored() {
        ignoredIDs = []
        reanalyze()
        refreshNearby()
    }

    // MARK: - Spin to pinpoint

    func startSpin() {
        guard let t = mission.current, running else { return }
        spinTarget = t.id
        spinDevices = t.deviceIDs
        spinData = []; spinCovered = []
        spinStart = allPoses.last?.t ?? 0
        spinCoverage = 0; spinReadings = 0; spinOutcome = nil
        spinning = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func cancelSpin() {
        spinning = false
        spinOutcome = nil
    }

    private func spinStep(_ p: Pose) {
        let before = spinCovered.count
        spinCovered.insert(SpinLocator.sector(p.heading))
        if spinCovered.count != before {
            spinCoverage = SpinLocator.coverageDegrees(spinCovered)
            if spinCovered.count % 6 == 0 { UIImpactFeedbackGenerator(style: .light).impactOccurred() } // every 90°
        }
        spinReadings = spinData.count
        let elapsed = p.t - spinStart
        if (spinCoverage >= 345 && elapsed >= 6) || elapsed >= 45 { finishSpin() }
    }

    func finishSpin() {
        guard spinning else { return }
        spinning = false
        guard let id = spinTarget, let me = allPoses.last else { return }
        guard let r = SpinLocator.estimate(spinData, pathLossN: params.n) else {
            spinOutcome = spinData.count < 8
                ? "Hardly heard this hot spot's devices during the spin. Move closer and try again."
                : "Turn a full circle, slowly, then try again."
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        if r.confidence == .low {
            spinOutcome = "No clear direction. The devices may be right next to you (within ~1 m), or the signal is bouncing off walls. Search close by."
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        let x = me.x + r.distance * sin(r.bearing), y = me.y + r.distance * cos(r.bearing)
        let note = String(format: "Pinpointed by spin: about %.0f m that way (%@ confidence)", r.distance, r.confidence.rawValue)
        mission.pin(id, x: x, y: y, note: note)
        arrivedTargetID = nil
        spinOutcome = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func afterTargetChange() {
        spinning = false
        spinOutcome = nil
        arrivedTargetID = nil
        targetSignal = nil
        signalHistory = []
    }

    private func checkArrival(_ p: Pose) {
        guard screen == .mission, let t = mission.current else { return }
        let d = hypot(t.goalX - p.x, t.goalY - p.y)
        if d <= t.arrivalRadius, arrivedTargetID != t.id {
            arrivedTargetID = t.id
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else if d > t.arrivalRadius + 1.0, arrivedTargetID == t.id {
            arrivedTargetID = nil // walked away again
        }
    }

    private func updateTargetSignal(now: TimeInterval, loudest: [String: NearbyDevice]) {
        guard let t = mission.current else { targetSignal = nil; return }
        guard let rssi = t.deviceIDs.compactMap({ loudest[$0]?.rssi }).max() else { targetSignal = nil; return }
        signalHistory.append((now, rssi))
        signalHistory.removeAll { now - $0.t > 8 }
        // compare the last ~2 s with what we heard ~4-6 s ago
        let recent = signalHistory.filter { now - $0.t <= 2 }.map(\.rssi)
        let earlier = signalHistory.filter { now - $0.t > 4 }.map(\.rssi)
        var trend = 0
        if !recent.isEmpty, !earlier.isEmpty {
            let delta = Double(recent.reduce(0, +)) / Double(recent.count) - Double(earlier.reduce(0, +)) / Double(earlier.count)
            trend = delta > 3 ? 1 : delta < -3 ? -1 : 0
        }
        targetSignal = TargetSignal(rssi: rssi, trend: trend)
    }

    private func analyze() async {
        let named = namedIDs, include = includeUnnamed, ignored = ignoredIDs
        let s = samples.filter { !ignored.contains($0.id) && (include || named.contains($0.id)) }
        let p = allPoses, params = params
        guard p.count > 1 else { return }
        let fresh = await Task.detached(priority: .userInitiated) {
            Localizer.analyze(samples: s, poses: p, params: params)
        }.value
        // Hot spots persist: remember each device's most confident position for the whole session...
        bestFixes = Localizer.mergeFixes(bestFixes, with: fresh.devices)
        // ...but follow devices that have moved: a confident fit of just the last minute that
        // clearly disagrees with the remembered spot replaces it.
        if let lastT = p.last?.t {
            let window = Self.recentWindow
            let rp = p.filter { $0.t > lastT - window }, rs = s.filter { $0.t > lastT - window }
            if rp.count > 1 {
                let recent = await Task.detached(priority: .userInitiated) {
                    Localizer.analyze(samples: rs, poses: rp, params: params)
                }.value
                bestFixes = Localizer.reconcile(bestFixes, withRecent: recent.devices)
            }
        }
        let fixes = bestFixes.values.filter { (include || $0.named) && !ignored.contains($0.id) }.sorted { $0.name < $1.name }
        let clusters = Localizer.makeClusters(fixes.filter { $0.status.isPlaced }, link: params.link)
        let r = AnalysisResult(devices: fixes, clusters: clusters,
                               heat: Localizer.heat(from: fixes, poses: p) ?? fresh.heat)
        result = r
        mission.update(with: r.clusters, from: current)
    }

    // MARK: - Ground station

    /// Send everything new since the last successful batch. If the station is unreachable the
    /// data waits and goes with the next batch (oldest readings dropped beyond a cap).
    private func syncToGround() async {
        guard link.canSend, sessionStartWall > 0 else { return }
        if samples.count - sentSamples > 20_000 { sentSamples = samples.count - 20_000 }
        let newPoses = Array(allPoses[min(sentPoses, allPoses.count)...])
        let newSamples = Array(samples[min(sentSamples, samples.count)...])
        let posesCount = allPoses.count, samplesCount = samples.count
        let spots = (result?.clusters ?? []).map {
            GroundBatch.HotSpot(id: $0.id, x: $0.x, y: $0.y, count: $0.count, roughCount: $0.roughCount,
                                names: $0.names, spread: $0.spread, uncertainty: $0.uncertainty)
        }
        let target = screen == .mission ? mission.current.map {
            GroundBatch.Target(x: $0.goalX, y: $0.goalY, names: $0.names)
        } : nil
        let batch = GroundBatch(
            phoneId: link.phoneID, name: link.displayName,
            sentAt: Date().timeIntervalSince1970, uptimeAtSend: ProcessInfo.processInfo.systemUptime,
            sessionStart: sessionStartWall, running: running, screen: screen.rawValue.lowercased(),
            pose: allPoses.last,
            poses: newPoses.enumerated().filter { $0.offset % 5 == 0 }.map(\.element), // ~2 per second
            samples: newSamples, hotSpots: spots, missionTarget: target,
            stats: ["named": namedHeard, "unnamed": unnamedIgnored])
        guard let body = try? JSONEncoder().encode(batch) else { return }
        if await link.send(body) {
            sentPoses = posesCount
            sentSamples = samplesCount
        }
    }

    // MARK: - Export

    struct Export: Codable {
        let poses: [Pose]
        let samples: [BLESample]
    }

    func exportFile() -> URL? {
        let data = try? JSONEncoder().encode(Export(poses: allPoses, samples: samples))
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blescout-\(f.string(from: Date())).json")
        guard let data, (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}
