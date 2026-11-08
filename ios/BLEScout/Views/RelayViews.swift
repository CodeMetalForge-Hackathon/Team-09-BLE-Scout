import SwiftUI

/// Card for the newest signal relayed by another phone: where it is from *you*, plus Forward / Find it.
struct RelayCard: View {
    @EnvironmentObject var session: ScanSession
    @ObservedObject var relays: RelayCenter

    var body: some View {
        if let r = relays.top {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Relayed signal", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.bold()).foregroundStyle(.purple)
                    Spacer()
                    Button { relays.dismissed.insert(r.id) } label: { Image(systemName: "xmark").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Text(r.target_name).font(.headline)
                if let v = session.vectorText(to: r) {
                    Text("\(v) from you").font(.title3.bold()).foregroundStyle(.purple)
                }
                Text("Picked by \(r.originName) · relayed through \(r.chain.map(\.name).joined(separator: " → "))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 10) {
                    Button { session.forward(r) } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Button { session.findRelayed(r) } label: {
                        Label("Find it", systemImage: "scope").font(.subheadline.bold())
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(Color.purple, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.purple.opacity(0.5)))
            .padding(.horizontal).padding(.bottom, 8)
        }
    }
}

/// Ground station picked this phone as the rescuer.
struct DispatchBanner: View {
    @EnvironmentObject var session: ScanSession

    var body: some View {
        if let d = session.dispatchNotice {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("You're the rescuer", systemImage: "light.beacon.max.fill")
                        .font(.headline).foregroundStyle(.white)
                    Spacer()
                    Button { session.dispatchNotice = nil } label: { Image(systemName: "xmark").foregroundStyle(.white.opacity(0.8)) }
                        .buttonStyle(.plain)
                }
                Text("The ground station sent you to: \(d.names.joined(separator: ", "))")
                    .font(.subheadline).foregroundStyle(.white)
                Text(session.running ? "Mission mode is guiding you there. Follow the arrow."
                                     : "Tap Start (on the shared mark) and Mission mode will guide you there.")
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
            }
            .padding(12)
            .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal).padding(.bottom, 8)
        }
    }
}

/// Status line after relaying/forwarding (auto-hides).
struct RelayStatusLine: View {
    let text: String?
    var body: some View {
        if let text {
            Text(text).font(.caption).foregroundStyle(.purple)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.bottom, 4)
        }
    }
}

/// Tap a device row → "Relay this signal to the fleet?"
struct RelayOnTap: ViewModifier {
    @EnvironmentObject var session: ScanSession
    let deviceID: String
    let name: String
    @State private var asking = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { asking = true }
            .confirmationDialog("Relay \(name)?", isPresented: $asking, titleVisibility: .visible) {
                Button("Relay this signal to the fleet") { session.relaySignal(deviceID: deviceID) }
            } message: {
                Text("Sends this device's position to the other phones on your team. They can forward it on, and a rescuer can tap Find it to be guided there.")
            }
    }
}

extension View {
    func relayOnTap(deviceID: String, name: String) -> some View { modifier(RelayOnTap(deviceID: deviceID, name: name)) }
}
