import SwiftUI

/// Turn-by-turn guidance to the hot spots, most devices first.
struct MissionView: View {
    @EnvironmentObject var session: ScanSession

    var body: some View {
        let plan = session.mission
        VStack(spacing: 12) {
            if session.paused {
                pausedCard
            } else if session.spinning {
                spinCard
            } else if let target = plan.current, let me = session.current {
                guidance(target: target, me: me, plan: plan)
            } else if plan.clearedCount > 0 && plan.current == nil {
                done(plan)
            } else {
                waiting
            }
            MapView(poses: session.poses, current: session.current, result: session.result, mission: plan)
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: guidance

    @ViewBuilder
    private func guidance(target t: MissionTarget, me: Pose, plan: MissionPlanner) -> some View {
        let rank = (plan.remaining.firstIndex { $0.id == t.id } ?? 0) + 1
        let distance = hypot(t.goalX - me.x, t.goalY - me.y)
        let turn = Direction.relativeAngle(from: me, toX: t.goalX, y: t.goalY)
        let arrived = session.arrivedTargetID == t.id

        VStack(spacing: 10) {
            HStack {
                if t.external {
                    Label("Relayed signal", systemImage: "dot.radiowaves.left.and.right").font(.headline).foregroundStyle(.purple)
                } else {
                    Text("Hot spot \(rank) of \(plan.remaining.count)").font(.headline)
                }
                if t.status == .skipped { Text("skipped earlier").font(.caption).foregroundStyle(.secondary) }
                if t.allRough { Text("rough").font(.caption.bold()).foregroundStyle(.yellow) }
                Spacer()
                Text("\(t.count) device\(t.count == 1 ? "" : "s")")
                    .font(.headline).foregroundStyle(.orange)
            }

            HStack(spacing: 18) {
                ZStack {
                    Circle().fill(arrived ? Color.green.opacity(0.2) : Color.orange.opacity(0.15))
                    if arrived {
                        Image(systemName: "checkmark").font(.system(size: 54, weight: .bold)).foregroundStyle(.green)
                    } else {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.orange)
                            .rotationEffect(.radians(turn))
                            .animation(.easeOut(duration: 0.25), value: turn)
                    }
                }
                .frame(width: 120, height: 120)

                VStack(alignment: .leading, spacing: 6) {
                    if arrived {
                        Text("You're there").font(.title2.bold()).foregroundStyle(.green)
                        Text(String(format: "Search ~%.0f m around you", max(t.arrivalRadius, 1)))
                            .font(.callout).lineLimit(2).minimumScaleFactor(0.8)
                    } else {
                        Text(Steering.instruction(turn: turn, distance: distance))
                            .font(.title2.bold())
                            .minimumScaleFactor(0.7).lineLimit(2)
                        Text(Direction.fromStart(x: t.goalX, y: t.goalY)).font(.caption).foregroundStyle(.secondary)
                    }
                    signal
                }
                Spacer(minLength: 0)
            }

            Text(t.names.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
            if let note = t.relayNote {
                Label(note, systemImage: "point.3.connected.trianglepath.dotted").font(.caption).foregroundStyle(.purple)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let note = t.pinNote {
                Label(note, systemImage: "scope").font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let msg = session.spinOutcome {
                Label(msg, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button { session.skipTarget() } label: {
                    Label("Skip", systemImage: "forward.fill").frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 12))
                }
                Button { session.clearTarget() } label: {
                    Label("Cleared · next", systemImage: "checkmark.circle.fill").font(.headline)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(arrived ? Color.green : Color.green.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.black)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button { session.ignoreCurrentTarget() } label: {
                Label("It's us (team or own gear) · ignore", systemImage: "person.2.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Button { session.startSpin() } label: {
                Label(t.pinned ? "Spin again to re-pinpoint" : "Spin to pinpoint (turn a full circle)",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange, lineWidth: 1.5))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    @ViewBuilder private var signal: some View {
        if let s = session.targetSignal {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("Signal \(s.rssi) dBm").font(.caption.monospacedDigit())
                    switch s.trend {
                    case 1: Label("warmer", systemImage: "arrow.up").font(.caption.bold()).foregroundStyle(.green)
                    case -1: Label("colder", systemImage: "arrow.down").font(.caption.bold()).foregroundStyle(.red)
                    default: EmptyView()
                    }
                }
                SignalBar(rssi: s.rssi, color: .orange).frame(width: 140)
            }
        } else {
            Text("Target devices not heard right now").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func done(_ plan: MissionPlanner) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text("All \(plan.clearedCount) hot spot\(plan.clearedCount == 1 ? "" : "s") cleared").font(.title3.bold())
            Text("Keep the scan running. New hot spots will be added here if more devices show up.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding().frame(maxWidth: .infinity)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    // MARK: spin

    private var spinCard: some View {
        let deg = session.spinCoverage
        return VStack(spacing: 12) {
            Text("Spin to pinpoint").font(.headline)
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 14)
                Circle().trim(from: 0, to: min(deg / 360, 1))
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: deg)
                VStack(spacing: 2) {
                    Text("\(Int(deg))°").font(.system(size: 34, weight: .bold).monospacedDigit())
                    Text("of 360°").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, height: 140)
            Text("Hold the phone out in front of you and turn slowly in place, one full circle (about 15 seconds). Your body blocks the signal from behind, so the app can tell which way the devices are.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("\(session.spinReadings) readings from this hot spot").font(.caption2.monospacedDigit())
                .foregroundStyle(session.spinReadings < 8 ? .yellow : .secondary)
            HStack(spacing: 10) {
                Button { session.cancelSpin() } label: {
                    Text("Cancel").frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 12))
                }
                Button { session.finishSpin() } label: {
                    Text("Done").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(deg >= 180 ? Color.orange : Color.orange.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.black)
                }
                .disabled(deg < 180)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private var pausedCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "pause.circle.fill").font(.system(size: 40)).foregroundStyle(.orange)
            Text("Scan paused").font(.headline)
            Text(session.hasHotSpots
                 ? "Resume to get live directions to the \(session.mission.remaining.count) hot spot(s). Resume close to where you paused so positions stay lined up."
                 : "Resume and keep walking until hot spots appear.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { session.resume() } label: {
                Label("Resume", systemImage: "play.fill").font(.headline)
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(Color.blue, in: Capsule()).foregroundStyle(.white)
            }
        }
        .padding().frame(maxWidth: .infinity)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private var waiting: some View {
        VStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("No hot spots yet").font(.headline)
            Text("Still scanning. Keep walking around; directions start as soon as a hot spot is found.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding().frame(maxWidth: .infinity)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }
}
