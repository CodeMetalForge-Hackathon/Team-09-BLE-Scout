import SwiftUI

/// Top-down map. Up = the way you faced when you pressed Start.
struct MapView: View {
    let poses: [Pose]
    let current: Pose?
    let result: AnalysisResult?
    var mission: MissionPlanner? = nil

    // Zoom & pan: pinch to zoom, drag to pan, double-tap (or ⤢) to fit everything again.
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private func clampZoom(_ z: CGFloat) -> CGFloat { min(max(z, 0.5), 20) }

    var body: some View {
        canvas
            .gesture(SimultaneousGesture(
                MagnificationGesture()
                    .updating($pinch) { v, s, _ in s = v }
                    .onEnded { v in zoom = clampZoom(zoom * v) },
                DragGesture(minimumDistance: 4)
                    .updating($drag) { v, s, _ in s = v.translation }
                    .onEnded { v in pan.width += v.translation.width; pan.height += v.translation.height }
            ))
            .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.25)) { zoom = 1; pan = .zero } }
            .overlay(alignment: .bottomTrailing) { zoomButtons }
    }

    private var zoomButtons: some View {
        VStack(spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.2)) { zoom = clampZoom(zoom * 1.5) } } label: { Image(systemName: "plus") }
            Button { withAnimation(.easeOut(duration: 0.2)) { zoom = clampZoom(zoom / 1.5) } } label: { Image(systemName: "minus") }
            Button { withAnimation(.easeOut(duration: 0.25)) { zoom = 1; pan = .zero } } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .buttonStyle(.plain)
        .frame(width: 40)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
        .padding(10)
        .padding(.bottom, 64) // clear of the "Plan mission" button
    }

    private var canvas: some View {
        let z = clampZoom(zoom * pinch)
        let off = CGSize(width: pan.width + drag.width, height: pan.height + drag.height)
        return Canvas { ctx, size in
            let clusters = result?.clusters ?? []
            // Fit everything we know about (path, clusters, start) with some padding.
            let targets = mission?.targets ?? []
            var xs = poses.map(\.x) + clusters.map(\.x) + targets.map(\.x) + [0]
            var ys = poses.map(\.y) + clusters.map(\.y) + targets.map(\.y) + [0]
            xs += [xs.min()! - 1.5, xs.max()! + 1.5]
            ys += [ys.min()! - 1.5, ys.max()! + 1.5]
            let minX = xs.min()!, maxX = max(xs.max()!, minX + 4)
            let minY = ys.min()!, maxY = max(ys.max()!, minY + 4)
            let kb = min(size.width / (maxX - minX), size.height / (maxY - minY))
            let ox = (size.width - (maxX - minX) * kb) / 2, oy = (size.height - (maxY - minY) * kb) / 2
            let k = kb * z  // points per metre after zoom
            func P(_ x: Double, _ y: Double) -> CGPoint {
                // auto-fit, then zoom about the centre and pan
                let bx = ox + (x - minX) * kb, by = size.height - oy - (y - minY) * kb
                return CGPoint(x: size.width / 2 + (bx - size.width / 2) * z + off.width,
                               y: size.height / 2 + (by - size.height / 2) * z + off.height)
            }

            // 1 m grid (extended when zoomed out or panned)
            let gpad = (z < 1 || off != .zero) ? 30.0 : 0
            var grid = Path()
            for gx in stride(from: floor(minX - gpad), through: maxX + gpad, by: 1) { grid.move(to: P(gx, minY - gpad)); grid.addLine(to: P(gx, maxY + gpad)) }
            for gy in stride(from: floor(minY - gpad), through: maxY + gpad, by: 1) { grid.move(to: P(minX - gpad, gy)); grid.addLine(to: P(maxX + gpad, gy)) }
            ctx.stroke(grid, with: .color(.white.opacity(0.06)), lineWidth: 1)

            // heat map
            if let h = result?.heat, h.maxValue > 0 {
                let cw = h.cell * k + 0.5
                for j in 0..<h.ny {
                    for i in 0..<h.nx {
                        let v = h.values[j * h.nx + i] / h.maxValue
                        guard v > 0.05 else { continue }
                        let p = P(h.x0 + Double(i) * h.cell, h.y0 + Double(j + 1) * h.cell)
                        ctx.fill(Path(CGRect(x: p.x, y: p.y, width: cw, height: cw)), with: .color(Self.heat(v)))
                    }
                }
            }

            // walked path
            if poses.count > 1 {
                var path = Path()
                path.move(to: P(poses[0].x, poses[0].y))
                for p in poses.enumerated() where p.offset % 3 == 0 { path.addLine(to: P(p.element.x, p.element.y)) }
                ctx.stroke(path, with: .color(.cyan.opacity(0.7)), lineWidth: 1.5)
            }

            // located devices
            // every placed device: solid = confident fit, hollow = rough or uncertain
            for d in result?.devices ?? [] where d.status.isPlaced {
                let p = P(d.x, d.y)
                let dot = Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                if d.status == .located {
                    ctx.fill(dot, with: .color(.white))
                } else {
                    ctx.stroke(dot, with: .color(.white.opacity(0.6)), lineWidth: 1.2)
                }
            }

            // mission targets: numbered in visiting order, current one highlighted, route to it
            if let mission {
                let order = mission.remaining
                if let cur = mission.current, let me = current {
                    var route = Path()
                    route.move(to: P(me.x, me.y)); route.addLine(to: P(cur.goalX, cur.goalY))
                    ctx.stroke(route, with: .color(.orange), style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                }
                for t in targets {
                    let p = P(t.x, t.y), r = max(t.arrivalRadius * k, 16)
                    let isCurrent = t.id == mission.current?.id
                    let color: Color = t.status == .cleared ? .green : t.external ? .purple : isCurrent ? .orange : .red
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(color), lineWidth: isCurrent ? 4 : 2)
                    let label = t.status == .cleared ? "✓" : "\((order.firstIndex { $0.id == t.id } ?? 0) + 1)"
                    ctx.draw(Text(label).font(.system(size: isCurrent ? 18 : 14, weight: .heavy)).foregroundColor(color),
                             at: p)
                    if t.pinned && t.status != .cleared {
                        // pinpointed spot from a spin
                        ctx.draw(Text("★").font(.system(size: 22, weight: .bold)).foregroundColor(.yellow),
                                 at: P(t.goalX, t.goalY))
                    }
                    ctx.draw(Text("\(t.count) dev").font(.system(size: 11, weight: .semibold)).foregroundColor(color.opacity(0.8)),
                             at: CGPoint(x: p.x + r + 4, y: p.y), anchor: .leading)
                }
            }

            // clusters (scan view)
            for c in clusters where mission == nil {
                let p = P(c.x, c.y), r = max(c.spread * k, 14)
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(.red), lineWidth: 2.5)
                ctx.draw(Text("\(c.id) · \(c.count)").font(.system(size: 14, weight: .bold)).foregroundColor(.red),
                         at: CGPoint(x: p.x + r + 4, y: p.y - 8), anchor: .leading)
            }

            // start
            let s = P(0, 0)
            ctx.fill(Path(roundedRect: CGRect(x: s.x - 6, y: s.y - 6, width: 12, height: 12), cornerRadius: 2), with: .color(.green))
            ctx.draw(Text("START").font(.system(size: 10, weight: .semibold)).foregroundColor(.green),
                     at: CGPoint(x: s.x, y: s.y + 14))

            // you
            if let c = current {
                let p = P(c.x, c.y)
                var arrow = Path()
                arrow.move(to: CGPoint(x: 0, y: -13)); arrow.addLine(to: CGPoint(x: 8, y: 9))
                arrow.addLine(to: CGPoint(x: 0, y: 4)); arrow.addLine(to: CGPoint(x: -8, y: 9)); arrow.closeSubpath()
                let t = CGAffineTransform(translationX: p.x, y: p.y).rotated(by: c.heading)
                ctx.fill(arrow.applying(t), with: .color(.blue))
                ctx.stroke(arrow.applying(t), with: .color(.white), lineWidth: 2)
            }

            // scale bar: pick a length that's 40-160 points at the current zoom
            let metres = [0.25, 0.5, 1, 2, 5, 10, 20, 50].first { $0 * k >= 40 } ?? 50
            let len = metres * k
            let bar = Path { $0.move(to: CGPoint(x: 12, y: size.height - 12)); $0.addLine(to: CGPoint(x: 12 + len, y: size.height - 12)) }
            ctx.stroke(bar, with: .color(.white.opacity(0.7)), lineWidth: 2)
            ctx.draw(Text(metres < 1 ? String(format: "%.0f cm", metres * 100) : String(format: "%g m", metres))
                        .font(.caption2).foregroundColor(.white.opacity(0.7)),
                     at: CGPoint(x: 12 + len / 2, y: size.height - 22))
        }
        .background(Color(white: 0.07))
    }

    static func heat(_ v: Double) -> Color {
        // dark blue -> red -> orange -> yellow
        let stops: [(Double, Double, Double, Double)] = [(0.16, 0.24, 0.55, 0.45), (0.86, 0.27, 0.24, 0.7),
                                                         (1.0, 0.67, 0.16, 0.8), (1.0, 0.94, 0.55, 0.9)]
        let f = min(max(v, 0), 1) * Double(stops.count - 1)
        let i = min(Int(f), stops.count - 2), u = f - Double(i)
        let a = stops[i], b = stops[i + 1]
        return Color(red: a.0 + (b.0 - a.0) * u, green: a.1 + (b.1 - a.1) * u,
                     blue: a.2 + (b.2 - a.2) * u, opacity: a.3 + (b.3 - a.3) * u)
    }
}
