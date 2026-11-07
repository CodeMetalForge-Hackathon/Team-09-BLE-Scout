import Foundation
import Network

/// Connection to the team's ground station (`groundstation/` in the repo). Two ways to reach it:
/// - **Cloud** (default when configured): batches go to a Supabase table over any internet
///   connection (Wi-Fi or cellular); the ground station pulls them for the team code.
/// - **Local Wi-Fi**: finds the laptop over Bonjour (or a typed address) and POSTs to it directly.
///   Needs a network that lets phones reach the laptop.
@MainActor
final class GroundLink: ObservableObject {
    enum State: Equatable { case off, searching, found, connected, failing(String) }
    enum Mode: String, CaseIterable, Identifiable {
        case cloud = "Cloud", local = "Local Wi-Fi"
        var id: String { rawValue }
    }

    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "gs.mode"); applyMode() }
    }
    @Published var teamCode: String {
        didSet { UserDefaults.standard.set(teamCode, forKey: "gs.team") }
    }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "gs.enabled"); applyMode() }
    }
    @Published var displayName: String {
        didSet { UserDefaults.standard.set(displayName, forKey: "gs.name") }
    }
    @Published var manualAddress: String {
        didSet { UserDefaults.standard.set(manualAddress, forKey: "gs.manual"); refreshState() }
    }
    @Published private(set) var discoveredURL: URL?
    @Published private(set) var state: State = .off
    @Published private(set) var lastSent: Date?
    @Published private(set) var phonesAtStation = 0

    let phoneID: String
    private var browser: NWBrowser?
    private var inFlight = false

    init() {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "gs.phoneID") { phoneID = id } else {
            phoneID = UUID().uuidString
            d.set(phoneID, forKey: "gs.phoneID")
        }
        enabled = d.object(forKey: "gs.enabled") as? Bool ?? true
        displayName = d.string(forKey: "gs.name") ?? "Phone \(phoneID.prefix(4))"
        manualAddress = d.string(forKey: "gs.manual") ?? ""
        teamCode = d.string(forKey: "gs.team") ?? "TEAM9"
        mode = Mode(rawValue: d.string(forKey: "gs.mode") ?? "") ?? (CloudConfig.isConfigured ? .cloud : .local)
        applyMode()
    }

    private var normalizedTeam: String { teamCode.trimmingCharacters(in: .whitespaces).uppercased() }

    /// Can a batch be sent right now (has somewhere to go)?
    var canSend: Bool {
        guard enabled else { return false }
        return mode == .cloud ? CloudConfig.isConfigured && !normalizedTeam.isEmpty : targetURL != nil
    }

    private func applyMode() {
        state = .off
        if enabled && mode == .local { startBrowsing() } else { stopBrowsing() }
        refreshState()
    }

    /// The typed-in address wins; otherwise whatever Bonjour found.
    var targetURL: URL? {
        let m = manualAddress.trimmingCharacters(in: .whitespaces)
        if !m.isEmpty {
            let withScheme = m.contains("://") ? m : "http://\(m)"
            if let u = URL(string: withScheme), u.host != nil { return u }
        }
        return discoveredURL
    }

    var statusText: String {
        if enabled && mode == .cloud {
            switch state {
            case .connected: return "Cloud: sharing as team \(normalizedTeam)"
            case .failing(let why): return "Cloud: \(why)"
            default: return CloudConfig.isConfigured ? "Cloud: ready (team \(normalizedTeam)) · starts when you scan"
                                                     : "Cloud: not set up in this build"
            }
        }
        switch state {
        case .off: return "Ground station: off"
        case .searching: return "Ground station: searching on this Wi-Fi…"
        case .found: return "Ground station: found · starts sharing when you scan"
        case .connected: return "Ground station: connected · \(phonesAtStation) phone\(phonesAtStation == 1 ? "" : "s")"
        case .failing(let why): return "Ground station: \(why)"
        }
    }

    // MARK: discovery

    func startBrowsing() {
        stopBrowsing()
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_blescout._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let url = results.lazy.compactMap { r -> URL? in
                if case let .bonjour(txt) = r.metadata, let s = txt["url"] { return URL(string: s) }
                return nil
            }.first
            Task { @MainActor in
                self?.discoveredURL = url
                self?.refreshState()
            }
        }
        b.start(queue: .main) // first start shows iOS's Local Network permission prompt
        browser = b
        refreshState()
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        discoveredURL = nil
        refreshState()
    }

    private func refreshState() {
        guard enabled else { state = .off; return }
        if mode == .cloud { if case .connected = state {} else { state = .found }; return }
        if case .connected = state, targetURL != nil { return }
        state = targetURL == nil ? .searching : .found
    }

    // MARK: sending

    /// POST one batch. Returns true if the station accepted it (so the caller can move on).
    func send(_ body: Data) async -> Bool {
        guard canSend, !inFlight else { return false }
        if mode == .cloud { return await sendToCloud(body, kind: "batch") }
        guard let base = targetURL else { return false }
        inFlight = true
        defer { inFlight = false }
        var req = URLRequest(url: base.appendingPathComponent("api/phone/\(phoneID)/batch"))
        req.httpMethod = "POST"
        req.timeoutInterval = 4
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                state = .failing("error from station")
                return false
            }
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                phonesAtStation = j["phones"] as? Int ?? phonesAtStation
            }
            state = .connected
            lastSent = Date()
            return true
        } catch {
            state = .failing("can't reach \(base.host ?? "station")")
            return false
        }
    }

    // MARK: cloud relay (Supabase REST)

    private func cloudRequest(kind: String, payload: Data) -> URLRequest? {
        guard CloudConfig.isConfigured, let url = URL(string: CloudConfig.supabaseURL + "/rest/v1/batches"),
              let payloadJSON = try? JSONSerialization.jsonObject(with: payload) else { return nil }
        let row: [String: Any] = ["team": normalizedTeam, "phone_id": phoneID, "name": displayName,
                                  "kind": kind, "payload": payloadJSON]
        guard let body = try? JSONSerialization.data(withJSONObject: row) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 6
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")   // insert only, don't read back
        req.setValue(CloudConfig.anonKey, forHTTPHeaderField: "apikey")
        if CloudConfig.anonKey.hasPrefix("eyJ") {                        // legacy JWT-style keys
            req.setValue("Bearer \(CloudConfig.anonKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
        return req
    }

    private func sendToCloud(_ payload: Data, kind: String) async -> Bool {
        guard let req = cloudRequest(kind: kind, payload: payload) else {
            state = .failing("not set up in this build"); return false
        }
        inFlight = true
        defer { inFlight = false }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let msg = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
                state = .failing("server said \(code) \(msg)")
                return false
            }
            state = .connected
            lastSent = Date()
            return true
        } catch {
            state = .failing("no internet? (\(error.localizedDescription))")
            return false
        }
    }

    /// For the settings screen: is the station reachable right now?
    func testConnection() async -> String {
        if mode == .cloud {
            guard CloudConfig.isConfigured else { return "Cloud isn't set up in this build of the app." }
            let ping = (try? JSONSerialization.data(withJSONObject: ["ping": true, "name": displayName])) ?? Data()
            return await sendToCloud(ping, kind: "ping")
                ? "✓ Sent a test to the cloud as team \(normalizedTeam). The ground station terminal shows it if it uses the same team code."
                : "Couldn't reach the cloud: \(statusText)"
        }
        guard let base = targetURL else { return "No ground station found yet. Same Wi-Fi? Or type its address." }
        var req = URLRequest(url: base.appendingPathComponent("api/ping"))
        req.timeoutInterval = 4
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 200,
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["ok"] as? Bool == true {
                if case .connected = state {} else { state = .found }
                return "✓ Reached the ground station at \(base.absoluteString)"
            }
            return "Something answered at \(base.absoluteString), but it isn't the ground station."
        } catch {
            return "Can't reach \(base.absoluteString): \(error.localizedDescription)"
        }
    }
}

/// What a phone sends to the ground station (see groundstation/station/server.py for the schema).
struct GroundBatch: Encodable {
    struct HotSpot: Encodable {
        let id: String, x: Double, y: Double, count: Int, roughCount: Int
        let names: [String], spread: Double, uncertainty: Double
    }
    struct Target: Encodable { let x: Double, y: Double, names: [String] }

    let v = 1
    let phoneId: String
    let name: String
    let sentAt: TimeInterval
    let uptimeAtSend: TimeInterval
    let sessionStart: TimeInterval
    let running: Bool
    let screen: String
    let pose: Pose?
    let poses: [Pose]
    let samples: [BLESample]
    let hotSpots: [HotSpot]
    let missionTarget: Target?
    let stats: [String: Int]
}
