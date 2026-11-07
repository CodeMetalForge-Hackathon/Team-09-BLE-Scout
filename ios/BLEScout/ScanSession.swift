import Foundation
import SwiftUI
import UIKit

/// Ties together position tracking, Bluetooth, and the live analysis.
@MainActor
final class ScanSession: ObservableObject {
    enum Screen: String, CaseIterable, Identifiable { case scan = "Scan", mission = "Mission"; var id: String { rawValue } }

    /// Live signal from the current mission target's devices: are we getting warmer?
    struct TargetSignal { let rssi: Int; let trend: Int } // trend: +1 warmer, -1 colder, 0 steady

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

    let tracker = PoseTracker()
    private let scanner = BLEScanner()
    private var samples: [BLESample] = []
    private var allPoses: [Pose] = []          // every pose; `poses` is a throttled copy for the UI
    private var lastPosePublish: TimeInterval = 0
    private var namedIDs = Set<String>(), unnamedIDs = Set<String>()
    private var bestFixes: [String: DeviceFix] = [:]   // most confident position per device, whole session
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
        Task { await analyze() }
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
    }

    func reset() {
        poses = []; allPoses = []; samples = []; current = nil; result = nil; nearby = []
        mission.reset(); arrivedTargetID = nil; targetSignal = nil; signalHistory = []
        namedIDs = []; unnamedIDs = []; namedHeard = 0; unnamedIgnored = 0
        bestFixes = [:]; knownNames = [:]
    }

    func reanalyze() { Task { await analyze() } }

    // MARK: - Data in

    private func add(pose: Pose) {
        guard running else { return }
        allPoses.append(pose)
        checkArrival(pose)
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

    private func afterTargetChange() {
        arrivedTargetID = nil
        targetSignal = nil
        signalHistory = []
    }

    private func checkArrival(_ p: Pose) {
        guard screen == .mission, let t = mission.current else { return }
        let d = hypot(t.x - p.x, t.y - p.y)
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
        let named = namedIDs, include = includeUnnamed
        let s = include ? samples : samples.filter { named.contains($0.id) }
        let p = allPoses, params = params
        guard p.count > 1 else { return }
        let fresh = await Task.detached(priority: .userInitiated) {
            Localizer.analyze(samples: s, poses: p, params: params)
        }.value
        // Hot spots persist: remember each device's most confident position for the whole session.
        bestFixes = Localizer.mergeFixes(bestFixes, with: fresh.devices)
        let fixes = bestFixes.values.filter { include || $0.named }.sorted { $0.name < $1.name }
        let clusters = Localizer.makeClusters(fixes.filter { $0.status.isPlaced }, link: params.link)
        let r = AnalysisResult(devices: fixes, clusters: clusters,
                               heat: Localizer.heat(from: fixes, poses: p) ?? fresh.heat)
        result = r
        mission.update(with: r.clusters, from: current)
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
