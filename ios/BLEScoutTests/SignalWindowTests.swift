import XCTest
@testable import BLEScout

final class SignalWindowTests: XCTestCase {
    private func s(_ t: Double, _ id: String, _ rssi: Int) -> BLESample { BLESample(t: t, id: id, name: id, rssi: rssi) }

    func testMedianOverLastFiveSecondsIgnoresBlipsAndOldReadings() {
        let samples = [
            s(1, "old", -40), s(2, "old", -40), s(3, "old", -40),          // > 5 s ago: ignored
            s(8, "steady", -60), s(9, "steady", -90), s(10, "steady", -62), s(11, "steady", -61), // one outlier
            s(10, "blip", -45),                                             // heard once: not consistent
            s(9, "pair", -70), s(11, "pair", -72),                          // twice
        ]
        let m = SignalWindow.consistentMedians(samples[...], now: 11.5)
        XCTAssertEqual(Set(m.keys), ["steady"])
        XCTAssertEqual(m["steady"] ?? 0, -61.5, accuracy: 1e-9, "median shrugs off the -90 outlier")
        // looser rule for the mission target's meter
        XCTAssertNotNil(SignalWindow.consistentMedians(samples[...], now: 11.5, minReadings: 2)["pair"])
    }

    func testDeviceMustBeHeardInThreeSeparateWindows() {
        var c = WindowCounter()
        for t in [0.5, 1.0, 1.5, 2.0] { c.add("burst", at: t) }        // many readings, one window
        for t in [0.5, 6.0, 11.0] { c.add("regular", at: t) }          // three windows
        XCTAssertEqual(c.count("burst"), 1)
        XCTAssertFalse(c.isConsistent("burst"))
        XCTAssertTrue(c.isConsistent("regular"))
        XCTAssertFalse(c.isConsistent("never-heard"))
    }
}
