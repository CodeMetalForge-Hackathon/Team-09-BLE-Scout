import SwiftUI

struct ContentView: View {
    @EnvironmentObject var session: ScanSession
    @State private var tab = Tab.map
    @State private var showTruth = false
    @State private var exportURL: URL?

    enum Tab: String, CaseIterable { case map = "Map", clusters = "Clusters", nearby = "Nearby" }

    var body: some View {
        VStack(spacing: 0) {
            camera
                .frame(maxWidth: .infinity)
                .frame(height: UIScreen.main.bounds.height * 0.38)
                .clipped()
            controls
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text(label(for: $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 6)
            switch tab {
            case .map:
                MapView(poses: session.poses, current: session.current, result: session.result,
                        truth: showTruth ? session.demo?.devices ?? [] : [])
                    .overlay(alignment: .topTrailing) {
                        if session.mode == .demo && session.demo != nil {
                            Toggle("Truth", isOn: $showTruth).toggleStyle(.button).font(.caption).padding(8)
                        }
                    }
            case .clusters: ClusterListView()
            case .nearby: NearbyView()
            }
        }
        .background(Color(white: 0.07))
        .preferredColorScheme(.dark)
    }

    private func label(for t: Tab) -> String {
        switch t {
        case .clusters: return "Clusters (\(session.result?.clusters.count ?? 0))"
        case .nearby: return "Nearby (\(session.nearby.count))"
        case .map: return "Map"
        }
    }

    // MARK: camera / demo backdrop

    @ViewBuilder private var camera: some View {
        ZStack(alignment: .top) {
            if session.mode == .live && session.liveSupported {
                ARCameraView(session: session.tracker.session, clusters: session.result?.clusters ?? [])
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.15), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
                    VStack(spacing: 6) {
                        Image(systemName: "figure.walk").font(.system(size: 40))
                        Text(session.liveSupported ? "Demo mode" : "Demo mode (no camera/Bluetooth here)")
                            .font(.headline)
                        Text("A virtual walker wanders a fake room with named\nand unnamed devices.")
                            .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                status(session.trackingStatus, icon: "location.fill")
                status(session.bluetoothStatus, icon: "dot.radiowaves.left.and.right")
            }
            .padding(8)
        }
    }

    private func status(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption).lineLimit(2)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
    }

    // MARK: controls

    private var controls: some View {
        HStack(spacing: 10) {
            if !session.running {
                Picker("Mode", selection: $session.mode) {
                    ForEach(ScanSession.Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .disabled(!session.liveSupported)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(session.namedHeard) named").font(.subheadline.bold())
                    Text("\(session.unnamedIgnored) unnamed ignored").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !session.running, session.hasData, let url = exportURL {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
            }
            Button {
                if session.running {
                    session.stop()
                    exportURL = session.exportFile()
                } else {
                    exportURL = nil
                    session.start()
                }
            } label: {
                Label(session.running ? "Stop" : (session.hasData ? "New scan" : "Start"),
                      systemImage: session.running ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(session.running ? Color.red : Color.blue, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal).padding(.top, 10)
    }
}

struct ClusterListView: View {
    @EnvironmentObject var session: ScanSession

    var body: some View {
        List {
            if let clusters = session.result?.clusters, !clusters.isEmpty {
                ForEach(clusters) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Cluster \(c.id)").font(.title3.bold())
                            Spacer()
                            Text("\(c.count) device\(c.count == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let me = session.current {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .rotationEffect(.radians(Direction.relativeAngle(from: me, toX: c.x, y: c.y)))
                                    .animation(.easeOut(duration: 0.3), value: me.heading)
                                Text(Direction.describe(from: me, toX: c.x, y: c.y))
                            }
                            .font(.headline).foregroundStyle(.orange)
                        }
                        Text(Direction.fromStart(x: c.x, y: c.y)).font(.subheadline)
                        Text(c.names.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "Spread ≈ %.1f m · position ±%.1f m", c.spread, c.uncertainty))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Text(session.running ? "Keep walking. Clusters appear once devices are heard from several spots."
                                     : "Press Start and walk around the room, any route.")
                    .foregroundStyle(.secondary)
            }
            if let devs = session.result?.devices, !devs.isEmpty {
                Section("All named devices") {
                    ForEach(devs) { d in
                        HStack {
                            Text(d.name).lineLimit(1)
                            Spacer()
                            Text(d.status == .located ? String(format: "±%.1f m", d.radius) : d.status.rawValue)
                                .font(.caption).foregroundStyle(d.status == .located ? .primary : .secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
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
                    GeometryReader { g in
                        Capsule().fill(.blue)
                            .frame(width: g.size.width * CGFloat(min(max(Double(d.rssi + 100) / 60, 0.03), 1)))
                    }
                    .frame(height: 4)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}
