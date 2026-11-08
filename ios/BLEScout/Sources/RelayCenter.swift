import Foundation

/// One relayed signal: "device <target_name> is at (target_x, target_y)", passed phone to phone.
/// Coordinates are in the shared map frame (everyone pressed Start on the same mark facing
/// the same way), so a receiving phone gets its own vector to the target by subtraction.
struct RelayMessage: Codable, Identifiable, Equatable {
    struct Hop: Codable, Equatable {
        let phone_id: String
        let name: String
        let x: Double
        let y: Double
    }
    let id: Int
    let team: String
    let from_phone: String
    let from_name: String?
    let target_name: String
    let target_x: Double
    let target_y: Double
    let target_radius: Double?
    let hop: Int
    let chain: [Hop]

    /// Who first picked the signal.
    var originName: String { chain.first?.name ?? from_name ?? "?" }
}

/// Sends relays to the Supabase `relays` table and polls it for the team's new ones.
/// (Supabase is the transport for now; a direct phone-to-phone mesh could replace it later.)
@MainActor
final class RelayCenter: ObservableObject {
    /// Latest relay per signal from other phones, newest first.
    @Published private(set) var incoming: [RelayMessage] = []
    @Published private(set) var lastError: String?
    @Published var dismissed = Set<Int>()

    private let link: GroundLink
    private var lastID = 0
    private var pollTask: Task<Void, Never>?
    private var startedAt = Date()

    init(link: GroundLink) {
        self.link = link
        startPolling()
    }

    var available: Bool { link.enabled && link.mode == .cloud && CloudConfig.isConfigured }

    /// The newest relay not dismissed, if any.
    var top: RelayMessage? { incoming.first { !dismissed.contains($0.id) } }

    func startPolling() {
        pollTask?.cancel()
        startedAt = Date()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func headers(_ req: inout URLRequest) {
        req.setValue(CloudConfig.anonKey, forHTTPHeaderField: "apikey")
        if CloudConfig.anonKey.hasPrefix("eyJ") {
            req.setValue("Bearer \(CloudConfig.anonKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func poll() async {
        guard available else { return }
        let team = link.teamCode.trimmingCharacters(in: .whitespaces).uppercased()
        var comps = URLComponents(string: CloudConfig.supabaseURL + "/rest/v1/relays")!
        var items = [URLQueryItem(name: "select", value: "id,team,from_phone,from_name,target_name,target_x,target_y,target_radius,hop,chain"),
                     URLQueryItem(name: "team", value: "eq.\(team)"),
                     URLQueryItem(name: "order", value: "id.asc"),
                     URLQueryItem(name: "limit", value: "200")]
        if lastID > 0 {
            items.append(URLQueryItem(name: "id", value: "gt.\(lastID)"))
        } else {
            // first poll: only relays from the last 10 minutes
            let since = ISO8601DateFormatter().string(from: startedAt.addingTimeInterval(-600))
            items.append(URLQueryItem(name: "created_at", value: "gte.\(since)"))
        }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 6
        headers(&req)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                lastError = "relay inbox: server said \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
                return
            }
            let rows = try JSONDecoder().decode([RelayMessage].self, from: data)
            lastError = nil
            guard !rows.isEmpty else { return }
            lastID = rows.map(\.id).max() ?? lastID
            for r in rows where r.from_phone != link.phoneID {
                incoming.removeAll { $0.target_name == r.target_name } // keep the newest per signal
                incoming.insert(r, at: 0)
            }
        } catch {
            lastError = "relay inbox: \(error.localizedDescription)"
        }
    }

    /// Relay a signal's position to the fleet. `chain` = hops so far (empty when you picked it).
    func send(targetName: String, x: Double, y: Double, radius: Double?, chain: [RelayMessage.Hop],
              me: Pose?) async -> Bool {
        guard available, let url = URL(string: CloudConfig.supabaseURL + "/rest/v1/relays") else {
            lastError = "Relays need Cloud mode (📡 settings)."
            return false
        }
        var hops = chain.map { ["phone_id": $0.phone_id, "name": $0.name, "x": $0.x, "y": $0.y] as [String: Any] }
        hops.append(["phone_id": link.phoneID, "name": link.displayName, "x": me?.x ?? 0, "y": me?.y ?? 0])
        var row: [String: Any] = ["team": link.teamCode.trimmingCharacters(in: .whitespaces).uppercased(),
                                  "from_phone": link.phoneID, "from_name": link.displayName,
                                  "target_name": targetName, "target_x": x, "target_y": y,
                                  "hop": hops.count - 1, "chain": hops]
        if let radius { row["target_radius"] = radius }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 6
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        headers(&req)
        req.httpBody = try? JSONSerialization.data(withJSONObject: row)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                lastError = "relay failed (\(code)) \(String(data: data, encoding: .utf8)?.prefix(100) ?? "")"
                return false
            }
            lastError = nil
            return true
        } catch {
            lastError = "relay failed: \(error.localizedDescription)"
            return false
        }
    }
}
