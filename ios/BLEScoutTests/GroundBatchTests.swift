import XCTest
@testable import BLEScout

/// The phone's batch must match what groundstation/station/server.py reads.
final class GroundBatchTests: XCTestCase {
    func testBatchUsesTheServersFieldNames() throws {
        let b = GroundBatch(
            phoneId: "p1", name: "Alex", sentAt: 1000, uptimeAtSend: 50, sessionStart: 900,
            running: true, screen: "mission",
            pose: Pose(t: 49, x: 1, y: 2, heading: 0.5),
            poses: [Pose(t: 48, x: 0.5, y: 1.5, heading: 0.4)],
            samples: [BLESample(t: 48.5, id: "d1", name: nil, rssi: -70)],
            hotSpots: [.init(id: "A", x: 3, y: 4, count: 2, roughCount: 1, names: ["a", "b"], spread: 0.8, uncertainty: 1.2)],
            missionTarget: .init(x: 3, y: 4, names: ["a", "b"]),
            stats: ["named": 2, "unnamed": 5])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(b)) as? [String: Any])
        for key in ["v", "phoneId", "name", "sentAt", "uptimeAtSend", "sessionStart", "running", "screen",
                    "pose", "poses", "samples", "hotSpots", "missionTarget", "stats"] {
            XCTAssertNotNil(json[key], "missing \(key)")
        }
        XCTAssertEqual(json["v"] as? Int, 1)
        let spot = try XCTUnwrap((json["hotSpots"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(spot.keys), ["id", "x", "y", "count", "roughCount", "names", "spread", "uncertainty"])
        let pose = try XCTUnwrap(json["pose"] as? [String: Any])
        XCTAssertEqual(Set(pose.keys), ["t", "x", "y", "heading"])
        let sample = try XCTUnwrap((json["samples"] as? [[String: Any]])?.first)
        XCTAssertTrue(Set(sample.keys).isSuperset(of: ["t", "id", "rssi"]))
    }
}
