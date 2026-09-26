import SwiftUI
import VisionKit
import AVFoundation

struct PairingView: View {
    @Bindable var model: PairingModel
    var onClose: (() -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @State private var link = ""
    @State private var manualHost = ""
    @State private var grant = ""
    @State private var code = ""
    @State private var scanning = false
    @State private var cameraError: String?

    var body: some View {
        NavigationStack {
            Form {
                if let proposal = model.row?.trust_proposal {
                    Section("Confirm host") {
                        Text("Only trust a host you recognize. A changed identity or key requires your approval again.")
                        Text(proposal.origin).font(.headline)
                        if let runtime = proposal.runtime_id { LabeledContent("Runtime", value: runtime) }
                        Text("SHA-256 key fingerprint").font(.caption)
                        Text(proposal.spki_sha256).font(.system(.caption, design: .monospaced))
                        Button("Trust and pair") { Task { await model.trust(proposal, accept: true) } }
                            .disabled(model.submitting).accessibilityIdentifier("trustHost")
                        Button("Don't trust", role: .cancel) { Task { await model.trust(proposal, accept: false) } }
                            .disabled(model.submitting)
                    }
                } else if model.paired {
                    Section("Paired") {
                        Label("Host saved securely", systemImage: "checkmark.shield")
                        Text(model.row?.phase == "ready" ? "Connected to your Verde host." : "Pairing is saved. Connecting to your host…")
                        if let origin = model.row?.https_url { Text(origin) }
                        if let scopes = model.row?.scopes, !scopes.isEmpty {
                            Text("Permissions: " + scopes.joined(separator: ", ")).font(.caption)
                        }
                    }
                } else {
                    Section {
                        Text("Run Tailscale on this phone and your host. Create a pairing grant in Verde on your computer, then scan or paste it here.")
                    }
                    Section("Pair a host") {
                        TextField("Device name", text: $model.deviceLabel)
                            .accessibilityIdentifier("deviceLabel")
                        Button { Task { await scan() } } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                            .disabled(model.busy)
                        SecureField("Pairing link", text: $link)
                            .textContentType(.none).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .privacySensitive().accessibilityIdentifier("pairingLink")
                        PasteButton(payloadType: String.self) { values in
                            guard let first = values.first, !model.busy else { return }
                            clearSecrets()
                            Task { await model.receive(first) }
                        }.disabled(model.busy)
                        Button("Continue with link") {
                            let input = link
                            clearSecrets()
                            Task { await model.receive(input) }
                        }.disabled(link.isEmpty || model.busy).accessibilityIdentifier("submitPairingLink")
                    }.disabled(model.fatal)
                    Section("Enter details manually") {
                        TextField("HTTPS host address", text: $manualHost).keyboardType(.URL)
                        SecureField("Grant ID", text: $grant).privacySensitive()
                        SecureField("Pair code", text: $code).privacySensitive()
                        Button("Continue with details") {
                            let input = PairingInput.manual(host: manualHost, grant: grant, code: code)
                            clearSecrets()
                            Task { await model.receive(input) }
                        }.disabled(manualHost.isEmpty || grant.isEmpty || code.isEmpty || model.busy)
                    }.textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(model.fatal)
                    if model.busy && model.errorText == nil {
                        Section { ProgressView("Connecting and pairing…") }
                    }
                }
                if let error = model.errorText {
                    Section("Connection needs attention") {
                        Text(error).accessibilityIdentifier("pairingError")
                        if model.error?.retryable == true {
                            Button("Retry") { Task { await model.retry() } }.disabled(model.submitting)
                        }
                    }
                }
                if model.row?.update_required == true { Text("Update Verde on your phone or host to continue.") }
                if let cameraError {
                    Section("Camera unavailable") {
                        Text(cameraError)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }
            }
            .blur(radius: scenePhase == .active ? 0 : 12)
            .privacySensitive()
            .navigationTitle("Pair with Verde")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) { Button("Back to hosts", action: onClose) }
                }
            }
            .task { await model.start() }
            .onChange(of: scenePhase) { _, phase in
                // Lifecycle signals are app-wide (RootView); this screen only hides secrets.
                if phase == .background { scanning = false; clearSecrets() }
            }
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    PairingScanner { value in
                        scanning = false
                        clearSecrets()
                        Task { await model.receive(value) }
                    } failed: {
                        scanning = false
                        cameraError = "Scanning stopped. Try again or paste the pairing link."
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Scan pairing code")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
                }
            }
        }
    }

    private func clearSecrets() { link = ""; grant = ""; code = ""; manualHost = "" }
    private func scan() async {
        cameraError = nil
        guard DataScannerViewController.isSupported else {
            cameraError = "QR scanning is unavailable on this device. Paste a link or enter the pairing details."; return
        }
        let permission: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: permission = true
        case .notDetermined: permission = await AVCaptureDevice.requestAccess(for: .video)
        default: permission = false
        }
        guard permission, DataScannerViewController.isAvailable else {
            cameraError = "Allow camera access in Settings, or paste a link or enter the pairing details."; return
        }
        scanning = true
    }
}

private struct PairingScanner: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    let failed: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned, failed: failed) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        guard !controller.isScanning, !context.coordinator.finished else { return }
        do { try controller.startScanning() }
        catch { context.coordinator.fail() }
    }
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let scanned: (String) -> Void
        let failed: () -> Void
        var finished = false
        init(scanned: @escaping (String) -> Void, failed: @escaping () -> Void) { self.scanned = scanned; self.failed = failed }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !finished else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
                    finished = true
                    dataScanner.stopScanning()
                    DispatchQueue.main.async { self.scanned(value) }
                    return
                }
            }
        }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) { fail() }
        func fail() {
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async { self.failed() }
        }
    }
}
