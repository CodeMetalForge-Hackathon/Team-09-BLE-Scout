import Foundation
import SwiftUI

/// Ties together position tracking, Bluetooth, and the live analysis.
@MainActor
final class ScanSession: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable { case live = "Live", demo = "Demo"; var id: String { rawValue } }

    @Published var mode: Mode = PoseTracker.isSupported ? .live : .demo
    @Published private(set) var running = false
    @Published private(set) var poses: [Pose] = []
    @Published private(set) var current: Pose?
    @Published private(set) var trackingStatus = "Ready"
    @Published private(set) var bluetoothStatus = "Ready"
    @Published private(set) var result: AnalysisResult?
    @Published private(set) var nearby: [NearbyDevice] = []
    @Published private(set) var namedHeard = 0
    @Published private(set) var unnamedIgnored = 0
    @Published var params = LocalizerParams()

    let tracker = PoseTracker()
    private let scanner = BLEScanner()
    private(set) var demo: DemoWorld?
    private var samples: [BLESample] = []
    private var namedIDs = Set<String>(), unnamedIDs = Set<String>()
    private var analysisTask: Task<Void, Never>?
    private var lastNearbyUpdate: TimeInterval = 0

    var liveSupported: Bool { PoseTracker.isSupported }
    var hasData: Bool { poses.count > 1 }

    init() {
        tracker.onPose = { [weak self] p in Task { @MainActor in self?.add(pose: p) } }
        tracker.onStatus = { [weak self] s in Task { @MainActor in self?.trackingStatus = s } }
        scanner.onSample = { [weak self] s in Task { @MainActor in self?.add(sample: s) } }
        scanner.onStatus = { [weak self] s in Task { @MainActor in self?.bluetoothStatus = s } }
    }

    // MARK: - Control

    func start() {
        reset()
        running = true
        UIApplication.shared.isIdleTimerDisabled = true // keep the screen on while walking
        if mode == .live {
            trackingStatus = "Starting… move the phone slowly"
            tracker.start()
            scanner.start()
        } else {
            let world = DemoWorld()
            world.onPose = { [weak self] p in self?.add(pose: p) }
            world.onSample = { [weak self] s in self?.add(sample: s) }
            demo = world
            trackingStatus = "Demo walker"
            bluetoothStatus = "Demo devices"
            world.start()
        }
        analysisTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.analyze()
            }
        }
    }

    func stop() {
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        analysisTask?.cancel()
        tracker.pause()
        scanner.stop()
        demo?.stop()
        Task { await analyze() }
    }

    func reset() {
        poses = []; samples = []; current = nil; result = nil; nearby = []
        namedIDs = []; unnamedIDs = []; namedHeard = 0; unnamedIgnored = 0
    }

    func reanalyze() { Task { await analyze() } }

    // MARK: - Data in

    private func add(pose: Pose) {
        guard running else { return }
        poses.append(pose)
        current = pose
    }

    private func add(sample: BLESample) {
        guard running else { return }
        if sample.name == nil {
            // Only named devices are of interest; count the rest so the user knows they were seen.
            if unnamedIDs.insert(sample.id).inserted { unnamedIgnored = unnamedIDs.count }
            return
        }
        samples.append(sample)
        if namedIDs.insert(sample.id).inserted { namedHeard = namedIDs.count }
        if sample.t - lastNearbyUpdate > 0.5 { updateNearby(now: sample.t) }
    }

    private func updateNearby(now: TimeInterval) {
        lastNearbyUpdate = now
        var best: [String: NearbyDevice] = [:]
        for s in samples.reversed() {
            if now - s.t > 3 { break }
            if let b = best[s.id], b.rssi >= s.rssi { continue }
            best[s.id] = NearbyDevice(id: s.id, name: s.name ?? "?", rssi: s.rssi)
        }
        nearby = best.values.sorted { $0.rssi > $1.rssi }
    }

    private func analyze() async {
        let s = samples, p = poses, params = params
        guard p.count > 1 else { return }
        let r = await Task.detached(priority: .userInitiated) {
            Localizer.analyze(samples: s, poses: p, params: params)
        }.value
        result = r
    }

    // MARK: - Export

    struct Export: Codable {
        let mode: String
        let poses: [Pose]
        let samples: [BLESample]
    }

    func exportFile() -> URL? {
        let data = try? JSONEncoder().encode(Export(mode: mode.rawValue, poses: poses, samples: samples))
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blescout-\(f.string(from: Date())).json")
        guard let data, (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}
