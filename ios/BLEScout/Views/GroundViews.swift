import SwiftUI

/// One-line ground station status under the title; tap for settings.
struct GroundStatusRow: View {
    @ObservedObject var link: GroundLink
    @State private var showSettings = false

    var body: some View {
        Button { showSettings = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                Text(link.statusText).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSettings) { GroundSettingsView(link: link) }
    }

    private var color: Color {
        switch link.state {
        case .connected: return .green
        case .failing: return .orange
        case .off: return .secondary
        default: return .blue
        }
    }
}

struct GroundSettingsView: View {
    @ViewBuilder private var testButton: some View {
        Button {
            testing = true
            Task { testResult = await link.testConnection(); testing = false }
        } label: {
            HStack { Text("Test connection"); if testing { Spacer(); ProgressView() } }
        }
        .disabled(testing || (link.mode == .local && link.targetURL == nil))
        if let r = testResult { Text(r).font(.caption) }
    }

    @ObservedObject var link: GroundLink
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Share with ground station", isOn: $link.enabled)
                    LabeledContent("Your name") {
                        TextField("shown on the map", text: $link.displayName)
                            .textInputAutocapitalization(.words).multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text("While you scan, your position, Bluetooth readings and hot spots are sent to the team's ground station every 2 seconds.")
                }

                Section {
                    Picker("Connect via", selection: $link.mode) {
                        ForEach(GroundLink.Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(link.mode == .cloud
                         ? "Cloud works over any internet connection (Wi-Fi or cellular). The ground station must use the same team code."
                         : "Local Wi-Fi talks straight to the laptop. Only works if the network lets phones reach it.")
                }

                if link.mode == .cloud {
                    Section("Cloud") {
                        LabeledContent("Team code") {
                            TextField("TEAM9", text: $link.teamCode)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Status", value: link.statusText.replacingOccurrences(of: "Cloud: ", with: ""))
                        testButton
                    }
                } else {
                Section("Ground station") {
                    LabeledContent("Status", value: link.statusText.replacingOccurrences(of: "Ground station: ", with: ""))
                    if let u = link.discoveredURL {
                        LabeledContent("Found on Wi-Fi", value: u.absoluteString)
                    } else if link.enabled {
                        Text("Searching on this Wi-Fi…").foregroundStyle(.secondary)
                    }
                    TextField("Or type its address, e.g. 192.168.1.20:8765", text: $link.manualAddress)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    testButton
                }
                }

                Section {
                    Text("For the maps to line up, everyone presses **Start** standing on the **same mark**, facing the **same way**.")
                        .font(.callout)
                } header: { Text("Important") }
            }
            .onChange(of: link.mode) { _, _ in testResult = nil }
            .navigationTitle("Ground station")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
