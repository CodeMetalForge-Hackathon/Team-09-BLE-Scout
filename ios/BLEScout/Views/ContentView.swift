import SwiftUI

struct ContentView: View {
    @EnvironmentObject var session: ScanSession
    @State private var exportURL: URL?
    @State private var confirmNew = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if session.running || session.hasData {
                Picker("", selection: $session.screen) {
                    Text("Scan").tag(ScanSession.Screen.scan)
                    Text("Mission").tag(ScanSession.Screen.mission)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.bottom, 8)
            }
            switch session.screen {
            case .scan: ScanView()
            case .mission: MissionView()
            }
        }
        .background(Color(white: 0.07))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BLE Scout").font(.title2.bold())
                    Text(session.running || session.paused ? statusLine : "Find hot spots of Bluetooth devices")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if session.paused {
                    Menu {
                        if let url = exportURL { ShareLink("Export data", item: url) }
                        Button("New scan (start over)", systemImage: "arrow.counterclockwise", role: .destructive) { confirmNew = true }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title2)
                    }
                }
                Button {
                    if session.running {
                        session.pause()
                        exportURL = session.exportFile()
                    } else if session.paused {
                        session.resume()
                    } else {
                        exportURL = nil
                        session.start()
                    }
                } label: {
                    Label(session.running ? "Pause" : session.paused ? "Resume" : "Start",
                          systemImage: session.running ? "pause.fill" : "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(session.running ? Color.red : Color.blue, in: Capsule())
                        .foregroundStyle(.white)
                }
                .disabled(!session.liveSupported)
            }
            GroundStatusRow(link: session.link)
            if !session.liveSupported {
                Text("Needs a real iPhone: the Simulator has no Bluetooth or motion tracking.")
                    .font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog("Start a new scan? This scan's hot spots and mission progress will be cleared.",
                            isPresented: $confirmNew, titleVisibility: .visible) {
            Button("Start new scan", role: .destructive) { exportURL = nil; session.start() }
        }
        .padding(.horizontal).padding(.top, 8).padding(.bottom, 10)
    }

    private var statusLine: String {
        "\(session.trackingStatus) · \(session.bluetoothStatus)"
    }
}

// MARK: - Scan

struct ScanView: View {
    @EnvironmentObject var session: ScanSession
    @State private var tab = Tab.map

    enum Tab: String, CaseIterable { case map = "Map", spots = "Hot spots", nearby = "Nearby" }

    var body: some View {
        VStack(spacing: 0) {
            if !session.running && !session.hasData {
                intro
            } else {
                HStack {
                    stat("\(session.namedHeard)", "named devices")
                    stat("\(session.result?.clusters.count ?? 0)", "hot spots")
                    stat("\(session.unnamedIgnored)", session.includeUnnamed ? "unnamed (included)" : "unnamed (ignored)")
                }
                .padding(.horizontal)
                unnamedToggle.padding(.horizontal).padding(.top, 6)
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 8)
                switch tab {
                case .map:
                    MapView(poses: session.poses, current: session.current, result: session.result)
                        .overlay(alignment: .bottom) {
                            if session.hasHotSpots {
                                Button { session.screen = .mission } label: {
                                    Label("Plan mission to hot spots", systemImage: "flag.checkered")
                                        .font(.headline).padding(.horizontal, 18).padding(.vertical, 12)
                                        .background(Color.orange, in: Capsule()).foregroundStyle(.black)
                                }
                                .padding(.bottom, 36)
                            }
                        }
                case .spots: HotSpotListView()
                case .nearby: NearbyView()
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.title3.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var unnamedToggle: some View {
        Toggle(isOn: $session.includeUnnamed) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Include unnamed devices").font(.subheadline)
                Text("Many phones don't broadcast a name. Adds more devices, but more noise and duplicates.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .tint(.orange)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            unnamedToggle.padding(.bottom, 4)
            Label("Stand at your start point, facing into the area, and tap Start.", systemImage: "1.circle.fill")
            Label("Walk slowly on any route, holding the phone upright with the back camera uncovered. It's only used for tracking; nothing is shown or saved.", systemImage: "2.circle.fill")
            Label("Hot spots (places with several Bluetooth devices) appear on the map as you go, and stay there when you walk away.", systemImage: "3.circle.fill")
            Label("Switch to Mission to be guided to the hot spots with the most devices first.", systemImage: "4.circle.fill")
            Spacer()
        }
        .font(.callout)
        .padding()
    }
}

struct HotSpotListView: View {
    @EnvironmentObject var session: ScanSession

    var body: some View {
        List {
            if let clusters = session.result?.clusters, !clusters.isEmpty {
                ForEach(clusters) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Hot spot \(c.id)").font(.title3.bold())
                            Spacer()
                            Text("\(c.count) device\(c.count == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let me = session.current {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .rotationEffect(.radians(Direction.relativeAngle(from: me, toX: c.x, y: c.y)))
                                Text(Direction.describe(from: me, toX: c.x, y: c.y))
                            }
                            .font(.headline).foregroundStyle(.orange)
                        }
                        Text(Direction.fromStart(x: c.x, y: c.y)).font(.subheadline)
                        Text(c.names.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "Spread ≈ %.1f m · position ±%.1f m", c.spread, c.uncertainty)
                             + (c.roughCount > 0 ? " · \(c.roughCount) rough" : ""))
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("It's us · ignore") { session.ignore(deviceIDs: Set(c.deviceIDs)) }
                            .font(.caption).buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Text(session.running ? "Keep walking. Hot spots appear once devices are heard from several spots."
                                     : "Press Start and walk around, any route.")
                    .foregroundStyle(.secondary)
            }
            if !session.ignoredIDs.isEmpty {
                Section {
                    Button("Restore \(session.ignoredIDs.count) ignored device\(session.ignoredIDs.count == 1 ? "" : "s")") {
                        session.restoreIgnored()
                    }
                } footer: {
                    Text("Ignored as team or own gear for this scan.")
                }
            }
            if let devs = session.result?.devices, !devs.isEmpty {
                Section("All devices heard (\(devs.count))") {
                    ForEach(devs.sorted { $0.status.rank != $1.status.rank ? $0.status.rank > $1.status.rank : $0.name < $1.name }) { d in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: d.status == .located ? "circle.fill" : d.status.isPlaced ? "circle" : "minus.circle")
                                    .font(.caption2).foregroundStyle(d.status == .located ? .primary : .secondary)
                                Text(d.name).lineLimit(1)
                                Spacer()
                                Text(Self.badge(d)).font(.caption.monospacedDigit())
                                    .foregroundStyle(d.status == .located ? .primary : .secondary)
                            }
                            if let why = Self.why(d) {
                                Text(why).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}

extension HotSpotListView {
    static func badge(_ d: DeviceFix) -> String {
        switch d.status {
        case .located: return String(format: "±%.1f m", d.radius)
        case .uncertain, .approximate: return String(format: "rough ±%.0f m", d.radius)
        case .carried: return "ignored"
        case .tooFew: return "waiting"
        }
    }

    /// Why a position is rough, and what to do about it.
    static func why(_ d: DeviceFix) -> String? {
        switch d.status {
        case .located: return nil
        case .approximate:
            return "Heard from only \(d.readings) spot\(d.readings == 1 ? "" : "s") (it broadcasts rarely or was far away). Walk slowly near it and pause a few seconds."
        case .uncertain:
            return "Readings were noisy. Walk past it on two different sides."
        case .carried:
            return "Stayed loud wherever you walked, so it's probably on you."
        case .tooFew:
            return "Waiting: walk a few metres so the app can tell whether it's on you."
        }
    }
}

struct NearbyView: View {
    @EnvironmentObject var session: ScanSession

    var body: some View {
        List {
            if session.nearby.isEmpty {
                Text(session.running ? "No named devices heard in the last 3 seconds." : "Start a scan to see nearby devices.")
                    .foregroundStyle(.secondary)
            }
            ForEach(session.nearby) { d in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(d.name).lineLimit(1)
                        Spacer()
                        Text("\(d.rssi) dBm").font(.caption.monospacedDigit())
                    }
                    SignalBar(rssi: d.rssi)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

struct SignalBar: View {
    let rssi: Int
    var color: Color = .blue
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                Capsule().fill(color)
                    .frame(width: g.size.width * CGFloat(min(max(Double(rssi + 100) / 60, 0.03), 1)))
            }
        }
        .frame(height: 6)
    }
}
