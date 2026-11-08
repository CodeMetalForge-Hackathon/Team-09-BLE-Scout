import Foundation

/// "Close and consistent" signals, judged over short time windows.
///
/// All readings are still kept for positioning (weak and far-away readings help pin a device
/// down). These helpers only decide what's *shown*: which devices count toward hot spots, the
/// Nearby top 5, and the steady signal strength used for warmer/colder.
enum SignalWindow {
    static let seconds = 5.0       // window length
    static let minWindows = 3      // heard in this many separate windows to count toward a hot spot
    static let minReadings = 3     // readings within the current window to count as consistent now
    static let topCount = 5        // Nearby shows this many

    static func windowIndex(_ t: TimeInterval) -> Int { Int((t / seconds).rounded(.down)) }

    /// Median strength per device over the last window, for devices heard at least `minReadings`
    /// times in it (a one-off blip isn't "consistent").
    static func consistentMedians(_ samples: ArraySlice<BLESample>, now: TimeInterval,
                                  minReadings: Int = minReadings) -> [String: Double] {
        var byDevice: [String: [Double]] = [:]
        for s in samples.reversed() {
            if now - s.t > seconds { break }
            byDevice[s.id, default: []].append(Double(s.rssi))
        }
        return byDevice.compactMapValues { rs in
            rs.count >= minReadings ? Localizer.median(rs) : nil
        }
    }
}

/// Counts in how many separate windows each device has been heard (cheap to update per reading).
struct WindowCounter {
    private var windows: [String: Set<Int>] = [:]

    mutating func add(_ id: String, at t: TimeInterval) {
        windows[id, default: []].insert(SignalWindow.windowIndex(t))
    }

    func count(_ id: String) -> Int { windows[id]?.count ?? 0 }

    /// Heard repeatedly, not just once in passing.
    func isConsistent(_ id: String, minWindows: Int = SignalWindow.minWindows) -> Bool { count(id) >= minWindows }

    mutating func reset() { windows = [:] }
}
