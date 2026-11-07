import ARKit
import SceneKit
import SwiftUI

/// Camera view with a floating pin for each cluster, placed where it was estimated.
struct ARCameraView: UIViewRepresentable {
    let session: ARSession
    let clusters: [Cluster]

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = true
        view.scene = SCNScene()
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        context.coordinator.sync(clusters, in: view.scene.rootNode)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var pins: [String: SCNNode] = [:]
        private var labels: [String: String] = [:]

        func sync(_ clusters: [Cluster], in root: SCNNode) {
            let ids = Set(clusters.map(\.id))
            for (id, node) in pins where !ids.contains(id) {
                node.removeFromParentNode(); pins[id] = nil; labels[id] = nil
            }
            for c in clusters {
                let label = "\(c.id) · \(c.count)"
                let node = pins[c.id] ?? {
                    let n = Self.makePin()
                    root.addChildNode(n)
                    pins[c.id] = n
                    return n
                }()
                if labels[c.id] != label {
                    Self.setLabel(label, on: node)
                    labels[c.id] = label
                }
                // map (x right, y ahead) -> world (x, up, -z); pin sits ~0.5 m below where you held the phone at start
                node.position = SCNVector3(Float(c.x), -0.5, Float(-c.y))
            }
        }

        private static func makePin() -> SCNNode {
            let node = SCNNode()
            let sphere = SCNSphere(radius: 0.1)
            sphere.firstMaterial?.diffuse.contents = UIColor.systemRed
            sphere.firstMaterial?.emission.contents = UIColor.systemRed
            node.addChildNode(SCNNode(geometry: sphere))
            let stick = SCNCylinder(radius: 0.01, height: 0.9)
            stick.firstMaterial?.diffuse.contents = UIColor.systemRed.withAlphaComponent(0.6)
            let stickNode = SCNNode(geometry: stick)
            stickNode.position = SCNVector3(0, -0.45, 0)
            node.addChildNode(stickNode)
            return node
        }

        private static func setLabel(_ text: String, on node: SCNNode) {
            node.childNode(withName: "label", recursively: false)?.removeFromParentNode()
            let t = SCNText(string: text, extrusionDepth: 0.5)
            t.font = .systemFont(ofSize: 10, weight: .bold)
            t.firstMaterial?.diffuse.contents = UIColor.white
            t.firstMaterial?.isDoubleSided = true
            let label = SCNNode(geometry: t)
            label.name = "label"
            label.scale = SCNVector3(0.02, 0.02, 0.02)
            let (min, max) = t.boundingBox
            label.pivot = SCNMatrix4MakeTranslation((max.x - min.x) / 2 + min.x, 0, 0)
            label.position = SCNVector3(0, 0.15, 0)
            label.constraints = [SCNBillboardConstraint()]
            node.addChildNode(label)
        }
    }
}
