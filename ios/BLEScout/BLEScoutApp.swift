import SwiftUI

@main
struct BLEScoutApp: App {
    @StateObject private var session = ScanSession()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(session)
        }
    }
}
