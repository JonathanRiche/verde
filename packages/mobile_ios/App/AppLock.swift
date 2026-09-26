import SwiftUI
import LocalAuthentication
import Observation

struct LockSettings: Codable, Equatable {
    var enabled = false
    var timeout: TimeInterval = 60
    var privacy = true
}

@MainActor protocol DeviceAuthenticating { func authenticate() async -> Bool }
@MainActor final class DeviceAuthentication: DeviceAuthenticating {
    func authenticate() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Verde with Face ID, Touch ID, or your device passcode.")) == true
    }
}

@MainActor @Observable
final class AppLock {
    private(set) var settings = LockSettings()
    private(set) var loaded = false
    private(set) var locked = true
    private(set) var busy = false
    var inactive = true
    var notice: String?
    private var backgroundAt: TimeInterval?
    private let storage: SecureStorage
    private let auth: DeviceAuthenticating
    private let now: () -> TimeInterval
    private let key = "ios/1/app-lock"
    var covered: Bool { !loaded || locked || (inactive && settings.privacy) }
    init(storage: SecureStorage = KeychainStorage(), auth: DeviceAuthenticating? = nil, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.storage = storage; self.auth = auth ?? DeviceAuthentication(); self.now = now
    }
    func load() {
        do {
            let data = try storage.get(key)
            let saved = try data.map { try JSONDecoder().decode(LockSettings.self, from: $0) } ?? LockSettings()
            guard [0, 60, 300, 900].contains(saved.timeout) else { throw StorageError(code: .io) }
            settings = saved; loaded = true; locked = saved.enabled; notice = nil
        } catch { loaded = false; locked = true; notice = "Unlock your phone and retry loading security settings." }
    }
    func phase(_ phase: ScenePhase) {
        inactive = phase != .active
        if phase == .background {
            if backgroundAt == nil { backgroundAt = now() }
            if settings.enabled && settings.timeout == 0 { locked = true }
        } else if phase == .active {
            if let start = backgroundAt, settings.enabled, now() - start >= settings.timeout { locked = true }
            backgroundAt = nil
        }
    }
    func unlock() async {
        guard !busy else { return }
        if !loaded { load(); return }
        busy = true; notice = nil
        defer { busy = false }
        if await auth.authenticate() { locked = false }
        else { notice = "Couldn't unlock. Make sure this phone has a device passcode, then try Face ID, Touch ID, or the passcode again." }
    }
    func update(_ next: LockSettings) async {
        guard loaded, !busy, [0, 60, 300, 900].contains(next.timeout) else { return }
        busy = true; notice = nil
        defer { busy = false }
        // Prove the device can unlock before enabling; disabling also requires its owner.
        if next.enabled != settings.enabled, !(await auth.authenticate()) {
            notice = "Set up a device passcode in Settings, then authenticate to change app lock."; return
        }
        do { try storage.put(key, value: JSONEncoder().encode(next)); settings = next; if !next.enabled { locked = false } }
        catch { notice = "Couldn't save security settings. Your previous settings still apply." }
    }
}

private struct LockCover: View {
    let lock: AppLock
    var body: some View {
        ZStack {
            VerdeTheme.background.ignoresSafeArea()
            VStack(spacing: 24) {
                VerdeWordmark()
                if !lock.inactive {
                    Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(VerdeTheme.accent)
                    Text(lock.loaded ? "Verde is locked" : "Security settings unavailable").font(VerdeTheme.display())
                    if let notice = lock.notice { Text(notice).multilineTextAlignment(.center).font(VerdeTheme.ui(13)) }
                    Button(lock.loaded ? "Unlock" : "Retry") { Task { await lock.unlock() } }.buttonStyle(.borderedProminent).disabled(lock.busy)
                }
            }.padding(32)
        }.tint(VerdeTheme.accent).foregroundStyle(VerdeTheme.text).accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
    }
}

/// A separate scene window covers presented sheets and share controllers too.
/// It is never made key, so the normal window regains focus when it disappears.
struct SecurityShield: UIViewRepresentable {
    let lock: AppLock
    let covered: Bool
    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) {
        view.lock = lock; view.covered = covered; view.refresh()
    }
    static func dismantleUIView(_ view: Anchor, coordinator: ()) { view.shield?.isHidden = true; view.shield = nil }
    final class Anchor: UIView {
        var lock: AppLock?
        var covered = true
        var shield: UIWindow?
        override func didMoveToWindow() { super.didMoveToWindow(); refresh() }
        func refresh() {
            guard let lock, let scene = window?.windowScene else { return }
            if covered {
                if shield == nil {
                    let overlay = UIWindow(windowScene: scene)
                    overlay.windowLevel = .alert + 1
                    overlay.accessibilityViewIsModal = true
                    shield = overlay
                }
                shield?.rootViewController = UIHostingController(rootView: LockCover(lock: lock))
                shield?.isHidden = false
            } else { shield?.isHidden = true; shield = nil }
        }
    }
}

struct SecuritySettings: View {
    let lock: AppLock
    var body: some View {
        Section("Security") {
            Toggle("Require Face ID or passcode", isOn: Binding(get: { lock.settings.enabled }, set: { enabled in var next = lock.settings; next.enabled = enabled; Task { await lock.update(next) } }))
            Picker("Lock after backgrounding", selection: Binding(get: { lock.settings.timeout }, set: { timeout in var next = lock.settings; next.timeout = timeout; Task { await lock.update(next) } })) {
                Text("Immediately").tag(0.0); Text("1 minute").tag(60.0); Text("5 minutes").tag(300.0); Text("15 minutes").tag(900.0)
            }.disabled(!lock.settings.enabled)
            Toggle("Hide in app switcher", isOn: Binding(get: { lock.settings.privacy }, set: { privacy in var next = lock.settings; next.privacy = privacy; Task { await lock.update(next) } }))
            if let notice = lock.notice { Text(notice).font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.warning) }
        }.disabled(lock.busy || !lock.loaded)
    }
}
