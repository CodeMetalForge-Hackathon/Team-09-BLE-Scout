import Foundation

/// Turns (where the phone was, what it heard) into device positions, a heat map and clusters.
///
/// Per device, readings are grouped into small spatial bins along your walk (so walking
/// the same spot twice doesn't over-count it), then the log-distance path-loss model
///     rssi = P0 - 10 * n * log10(distance)
/// is fitted by grid search. P0 (signal at 1 m) has a closed form per cell, so only
/// (x, y) is searched. Each device's fit becomes a probability map; the heat map is
/// their sum. Clusters are devices whose best positions are within `link` metres.
struct LocalizerParams {
    var n = 2.5               // path-loss exponent: ~2 open space, 2.5-3.5 cluttered indoors
    var sigmaDB = 4.0         // expected RSSI noise per bin
    var cell = 0.3            // grid resolution, metres
    var bin = 0.5             // spatial bin for readings along your path, metres
    var minBins = 3           // a proper fit needs readings from at least this many spots...
    var minSpan = 1.0         // ...spread over at least this distance (otherwise: rough placement)
    var maxIndependent = 12.0 // tempers over-confidence: RSSI errors aren't independent
    var link = 1.5            // devices closer than this share a cluster
    var maxRadius = 2.5       // fits less certain than this are labelled "uncertain" (still placed)
    var margin = 4.0          // search this far beyond the area you walked
}

enum Localizer {
    static let p0Range = -80.0 ... -35.0
    static let minDist = 0.3

    static func analyze(samples: [BLESample], poses: [Pose], params p: LocalizerParams = .init()) -> AnalysisResult {
        guard poses.count >= 2 else { return AnalysisResult(devices: [], clusters: [], heat: nil) }

        // 1. Bin readings per device by where you were when you heard them.
        struct BinKey: Hashable { let ix: Int, iy: Int }
        struct Bin { var sx = 0.0, sy = 0.0, rssi: [Int] = [] }
        var bins: [String: [BinKey: Bin]] = [:]
        var names: [String: String] = [:]
        let lookup = PoseLookup(poses)
        for s in samples {
            guard let pos = lookup.position(at: s.t) else { continue }
            if let name = s.name { names[s.id] = name }
            let key = BinKey(ix: Int((pos.x / p.bin).rounded(.down)), iy: Int((pos.y / p.bin).rounded(.down)))
            var b = bins[s.id, default: [:]][key, default: Bin()]
            b.sx += pos.x; b.sy += pos.y; b.rssi.append(s.rssi)
            bins[s.id, default: [:]][key] = b
        }

        // 2. Search grid over the walked area plus a margin.
        let xsP = poses.map(\.x), ysP = poses.map(\.y)
        let minX = xsP.min()! - p.margin, maxX = xsP.max()! + p.margin
        let minY = ysP.min()! - p.margin, maxY = ysP.max()! + p.margin
        let nx = max(1, Int(((maxX - minX) / p.cell).rounded(.up)))
        let ny = max(1, Int(((maxY - minY) / p.cell).rounded(.up)))
        let gx = (0..<nx).map { minX + (Double($0) + 0.5) * p.cell }
        let gy = (0..<ny).map { minY + (Double($0) + 0.5) * p.cell }
        var heat = [Double](repeating: 0, count: nx * ny)

        var devices: [DeviceFix] = []
        for (id, devBins) in bins {
            let obs = devBins.values.map { b in
                (x: b.sx / Double(b.rssi.count), y: b.sy / Double(b.rssi.count), r: median(b.rssi.map(Double.init)))
            }
            let rssi = obs.map(\.r).sorted()
            let med = median(rssi)
            let isNamed = names[id] != nil
            let name = names[id] ?? "Unnamed · \(id.prefix(4))"
            let ox = obs.map(\.x), oy = obs.map(\.y)
            let span = max((ox.max() ?? 0) - (ox.min() ?? 0), (oy.max() ?? 0) - (oy.min() ?? 0))

            let p10 = percentile(rssi, 0.1), p90 = percentile(rssi, 0.9)
            if (p10 > -58 && span > 2.5) || (p90 - p10 < 7 && med > -65 && span > 3) {
                // Stays loud wherever you walk: it's travelling with you.
                devices.append(DeviceFix(id: id, name: name, status: .carried, readings: obs.count, medianRSSI: med, named: isNamed))
                continue
            }
            if obs.count < p.minBins || span < p.minSpan {
                // Too little to fit a position, but we still want it on the map: place it near where
                // it was loudest, with a radius from how far away that loudness suggests it was.
                let top = obs.sorted { $0.r > $1.r }.prefix(3)
                let w = top.map { pow(10, $0.r / 10) }, wsum = w.reduce(0, +)
                let x = zip(top, w).map { $0.x * $1 }.reduce(0, +) / wsum
                let y = zip(top, w).map { $0.y * $1 }.reduce(0, +) / wsum
                let loudest = top.first?.r ?? -90
                let dist = pow(10, (-59 - loudest) / (10 * p.n)) // rough distance from the loudest spot
                devices.append(DeviceFix(id: id, name: name, status: .approximate, x: x, y: y,
                                         radius: min(max(dist, 1.0), 8.0),
                                         readings: obs.count, medianRSSI: med, named: isNamed))
                continue
            }

            // Mean squared error of the best-fitting model at every grid cell.
            var mse = [Double](repeating: 0, count: nx * ny)
            var loss = [Double](repeating: 0, count: obs.count)
            var minMSE = Double.infinity
            var bestP0 = [Double](repeating: 0, count: nx * ny)
            for j in 0..<ny {
                for i in 0..<nx {
                    var sum = 0.0
                    for (k, o) in obs.enumerated() {
                        let d = max(((gx[i] - o.x) * (gx[i] - o.x) + (gy[j] - o.y) * (gy[j] - o.y)).squareRoot(), minDist)
                        loss[k] = 10 * p.n * log10(d)
                        sum += o.r + loss[k]
                    }
                    let p0 = min(max(sum / Double(obs.count), p0Range.lowerBound), p0Range.upperBound)
                    var e = 0.0
                    for (k, o) in obs.enumerated() {
                        let r = o.r - (p0 - loss[k])
                        e += r * r
                    }
                    let c = j * nx + i
                    mse[c] = e / Double(obs.count)
                    bestP0[c] = p0
                    minMSE = min(minMSE, mse[c])
                }
            }

            let kEff = min(Double(obs.count), p.maxIndependent)
            var prob = mse.map { exp(-0.5 * kEff * ($0 - minMSE) / (p.sigmaDB * p.sigmaDB)) }
            let total = prob.reduce(0, +)
            for c in prob.indices { prob[c] /= total; heat[c] += prob[c] }

            let best = prob.indices.max { prob[$0] < prob[$1] }!
            // radius of the smallest region holding 68% of the probability
            var acc = 0.0, cells = 0
            for v in prob.sorted(by: >) { acc += v; cells += 1; if acc >= 0.68 { break } }
            let radius = (Double(cells) * p.cell * p.cell / .pi).squareRoot()

            devices.append(DeviceFix(
                id: id, name: name, status: radius <= p.maxRadius ? .located : .uncertain,
                x: gx[best % nx], y: gy[best / nx], radius: radius,
                readings: obs.count, medianRSSI: med, named: isNamed))
        }

        let clusters = makeClusters(devices.filter { $0.status.isPlaced }, link: p.link)
        let grid = HeatGrid(x0: minX, y0: minY, cell: p.cell, nx: nx, ny: ny,
                            values: heat, maxValue: heat.max() ?? 0)
        return AnalysisResult(devices: devices.sorted { $0.name < $1.name }, clusters: clusters, heat: grid)
    }

    // MARK: - Persistence across analyses

    /// Keep each device's most confident position from the whole session.
    ///
    /// As you walk away from a device, its fit picks up many weak, noisy far-away readings
    /// and can turn "uncertain", which made hot spots vanish. So a new fix only replaces
    /// the remembered one if it is about as confident (or better); otherwise the remembered
    /// position stands. A device that turns out to be carried by you is dropped.
    static func mergeFixes(_ previous: [String: DeviceFix], with latest: [DeviceFix]) -> [String: DeviceFix] {
        var out = previous
        for f in latest {
            guard let old = previous[f.id] else { out[f.id] = f; continue }
            if f.status == .carried || old.status == .carried {
                out[f.id] = f                       // carried status always follows the latest evidence
            } else if f.status.rank > old.status.rank {
                out[f.id] = f                       // better kind of fix (e.g. rough -> proper fit)
            } else if f.status.rank == old.status.rank {
                // same kind: take the new one unless it's clearly less precise
                if f.radius <= old.radius * 1.25 || f.status == .approximate { out[f.id] = f }
                else { out[f.id]?.name = f.name; out[f.id]?.named = f.named || old.named }
            } else {
                // worse kind of fix: keep the position we had, but pick up a name if one arrived since
                out[f.id]?.name = f.name
                out[f.id]?.named = f.named || old.named
            }
        }
        return out
    }

    /// Heat map built from remembered fixes: each device spreads one unit of "presence" as a
    /// Gaussian with its confidence radius. Unlike the live fit, this doesn't fade as you leave.
    static func heat(from fixes: [DeviceFix], poses: [Pose], cell: Double = 0.3, margin: Double = 2.0) -> HeatGrid? {
        let used = fixes.filter { $0.status.isPlaced }
        let xs = poses.map(\.x) + used.map(\.x), ys = poses.map(\.y) + used.map(\.y)
        guard let minX0 = xs.min(), let maxX0 = xs.max(), let minY0 = ys.min(), let maxY0 = ys.max() else { return nil }
        let minX = minX0 - margin, minY = minY0 - margin
        let nx = max(1, Int(((maxX0 + margin - minX) / cell).rounded(.up)))
        let ny = max(1, Int(((maxY0 + margin - minY) / cell).rounded(.up)))
        var v = [Double](repeating: 0, count: nx * ny)
        for f in used {
            let sigma = max(f.radius, 0.5)
            let weight = f.status == .located ? 1.0 : 0.5 // rough/uncertain ones count, but less
            let reach = Int((3 * sigma / cell).rounded(.up))
            let ci = Int(((f.x - minX) / cell).rounded(.down)), cj = Int(((f.y - minY) / cell).rounded(.down))
            let norm = weight / (2 * .pi * sigma * sigma) * cell * cell
            for j in max(0, cj - reach)...min(ny - 1, cj + reach) {
                for i in max(0, ci - reach)...min(nx - 1, ci + reach) {
                    let dx = minX + (Double(i) + 0.5) * cell - f.x, dy = minY + (Double(j) + 0.5) * cell - f.y
                    v[j * nx + i] += norm * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
                }
            }
        }
        return HeatGrid(x0: minX, y0: minY, cell: cell, nx: nx, ny: ny, values: v, maxValue: v.max() ?? 0)
    }

    /// Single-linkage grouping: any two devices within `link` metres end up together.
    static func makeClusters(_ devs: [DeviceFix], link: Double) -> [Cluster] {
        var parent = Array(devs.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for a in devs.indices {
            for b in devs.indices where b > a {
                if hypot(devs[a].x - devs[b].x, devs[a].y - devs[b].y) <= link { parent[find(a)] = find(b) }
            }
        }
        let groups = Dictionary(grouping: devs.indices, by: find).values.map { $0.map { devs[$0] } }
        var clusters = groups.map { m -> (x: Double, y: Double, m: [DeviceFix]) in
            (m.map(\.x).reduce(0, +) / Double(m.count), m.map(\.y).reduce(0, +) / Double(m.count), m)
        }
        clusters.sort { $0.m.count != $1.m.count ? $0.m.count > $1.m.count : hypot($0.x, $0.y) < hypot($1.x, $1.y) }
        return clusters.enumerated().map { i, c in
            let reach = c.m.map { hypot($0.x - c.x, $0.y - c.y) }.max() ?? 0
            return Cluster(
                id: i < 26 ? String(UnicodeScalar(65 + i)!) : "Z\(i)",
                x: c.x, y: c.y,
                names: c.m.map(\.name).sorted(),
                deviceIDs: c.m.map(\.id),
                spread: max(reach + 0.3, 0.6),
                uncertainty: median(c.m.map(\.radius)))
        }
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let pos = q * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }
}

/// Position at an arbitrary time, interpolated between the nearest poses.
struct PoseLookup {
    let poses: [Pose]
    init(_ poses: [Pose]) { self.poses = poses }

    func position(at t: TimeInterval) -> (x: Double, y: Double)? {
        guard let first = poses.first, let last = poses.last, t >= first.t, t <= last.t else { return nil }
        var lo = 0, hi = poses.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if poses[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = poses[lo], b = poses[hi]
        if b.t - a.t > 1.5 { return nil } // tracking gap: don't guess
        let f = b.t == a.t ? 0 : (t - a.t) / (b.t - a.t)
        return (a.x + f * (b.x - a.x), a.y + f * (b.y - a.y))
    }
}
