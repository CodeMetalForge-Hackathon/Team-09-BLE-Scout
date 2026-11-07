import XCTest
@testable import BLEScout

final class SpinTests: XCTestCase {
    /// Readings while turning a full circle, with a body-shadow dip of `swing` dB facing away from `bearing`.
    private func spin(bearing: Double, swing: Double, devices: [String: Double] = ["a": -60],
                      turn: Double = 2 * .pi, noise: Double = 3, seed: UInt64 = 5) -> [SpinReading] {
        var rng = SeededRandom(seed: seed)
        var out: [SpinReading] = []
        for i in 0..<120 {
            let h = Double(i) / 120 * turn - .pi
            for (id, base) in devices {
                out.append(SpinReading(heading: h, device: id,
                                       rssi: base + swing * cos(h - bearing) + rng.gauss() * noise))
            }
        }
        return out
    }

    func testFindsDirectionOfDevice() {
        for deg in [0.0, 60, 135, -90, 170] {
            let b = deg * .pi / 180
            let r = try! XCTUnwrap(SpinLocator.estimate(spin(bearing: b, swing: 6)))
            var err = abs(r.bearing - b).truncatingRemainder(dividingBy: 2 * .pi)
            if err > .pi { err = 2 * .pi - err }
            XCTAssertLessThan(err * 180 / .pi, 15, "bearing \(deg)°")
            XCTAssertEqual(r.confidence, .high)
        }
    }

    func testCombinesDevicesWithDifferentPower() {
        let b = 45 * Double.pi / 180
        let r = try! XCTUnwrap(SpinLocator.estimate(spin(bearing: b, swing: 4, devices: ["loud": -50, "quiet": -75])))
        XCTAssertLessThan(abs(r.bearing - b) * 180 / .pi, 15)
    }

    func testFlatSignalIsLowConfidence() {
        let r = try! XCTUnwrap(SpinLocator.estimate(spin(bearing: 0, swing: 0, noise: 1)))
        XCTAssertEqual(r.confidence, .low)
    }

    func testRefusesHalfASpin() {
        XCTAssertNil(SpinLocator.estimate(spin(bearing: 0, swing: 6, turn: .pi * 0.4)))
    }
}
