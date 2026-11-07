import ARKit
import Foundation

/// Tracks the phone's position relative to where tracking started, using ARKit
/// (camera + motion sensors). Works for any walking route.
final class PoseTracker: NSObject, ARSessionDelegate {
    let session = ARSession()
    var onPose: ((Pose) -> Void)?
    var onStatus: ((String) -> Void)?
    private var lastT: TimeInterval = 0

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity // origin = phone at start; -Z = the way it faced
        session.delegate = self
        lastT = 0
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() { session.pause() }

    /// Continue after pause() without resetting: the world origin (your start point) is kept.
    func resume() {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        session.delegate = self
        lastT = 0
        session.run(config) // no .resetTracking
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frame.timestamp - lastT >= 0.1 else { return } // 10 Hz is plenty
        if case .notAvailable = frame.camera.trackingState { return }
        lastT = frame.timestamp
        let m = frame.camera.transform
        // World -> map: x stays x (right), map y = -world z (ahead).
        // The camera looks along its -Z axis; project that onto the floor for heading.
        let fx = Double(-m.columns.2.x), fy = Double(m.columns.2.z)
        onPose?(Pose(t: frame.timestamp, x: Double(m.columns.3.x), y: Double(-m.columns.3.z),
                     heading: atan2(fx, fy)))
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal: onStatus?("Tracking")
        case .notAvailable: onStatus?("Tracking unavailable")
        case .limited(let reason):
            switch reason {
            case .initializing: onStatus?("Starting… move the phone slowly")
            case .excessiveMotion: onStatus?("Slow down")
            case .insufficientFeatures: onStatus?("Point the camera at something textured (not a blank wall)")
            case .relocalizing: onStatus?("Re-finding position…")
            @unknown default: onStatus?("Tracking limited")
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onStatus?("Tracking failed: \(error.localizedDescription)")
    }
}
