import SwiftUI
import VerdeClient

enum ClientCore {
    // vc_version returns static storage; copy it into Swift and never free it.
    static var version: String { String(cString: vc_version()) }
}

@main
struct VerdeApp: App {
    @State private var pairing = PairingModel.live(deviceLabel: UIDevice.current.name)
    var body: some Scene {
        WindowGroup { PairingView(model: pairing) }
    }
}
