import Observation
import SwiftUI
import UIKit

/// What the Live pill shows, shared by the call bar over the app and the Companion sheet.
@MainActor @Observable
final class LivePillState {
    var captionsShown = true
    /// The Companion sheet shows the full Live view instead of the conversation.
    var expanded = false
    /// Asks an open Companion sheet to close its own sheets (and then open voice settings).
    private(set) var sheetRequest: LiveSheetRequest?

    func closeSheetChildren() { sheetRequest = LiveSheetRequest(id: (sheetRequest?.id ?? 0) + 1, voiceSettings: false) }
    func openVoiceSettings() { sheetRequest = LiveSheetRequest(id: (sheetRequest?.id ?? 0) + 1, voiceSettings: true) }
}

struct LiveSheetRequest: Equatable, Sendable {
    let id: Int
    let voiceSettings: Bool
}

/// Where a tap on the call bar leads.
enum LiveBarTarget: Sendable { case fullView, voiceSettings }

/// What the target opens over once nothing else covers it.
enum LiveBarBase: Sendable {
    /// Already showing; nothing more to do.
    case handled
    /// The app's main content (the Companion sheet or settings is presented next).
    case app
    /// The open Companion sheet.
    case companionSheet
}

/// The call bar: the pill and captions while a call connects or runs, or why it stopped.
struct LiveCallBarContent: View {
    let live: LiveVoice
    let companion: CompanionModel
    @Bindable var pill: LivePillState
    let open: (LiveBarTarget) -> Void
    /// The bar's frame in its window, for touches and the space reserved for it.
    let onFrame: (CGRect) -> Void

    var body: some View {
        let entry = companion.active
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if live.active {
                    LivePill(live: live, character: entry?.character ?? .sprout, name: entry?.name ?? "Companion",
                             captionsShown: $pill.captionsShown, expand: { open(.fullView) },
                             openSettings: { open(.voiceSettings) })
                } else if let failure = live.failure {
                    LiveFailureBar(message: failure, retry: { Task { await live.start() } }, close: { live.dismissFailure() })
                }
            }
            .padding(.top, 4)
            .background(GeometryReader { proxy in
                Color.clear.onChange(of: proxy.frame(in: .global), initial: true) { _, frame in onFrame(frame) }
            })
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.keyboard)
        .preferredColorScheme(AppearanceSettings.shared.scheme)
        .tint(VerdeTheme.accent)
        .foregroundStyle(VerdeTheme.text)
        .font(VerdeTheme.ui())
        .onChange(of: live.failure) { _, failure in
            if let failure { UIAccessibility.post(notification: .announcement, argument: "Live voice stopped. \(failure)") }
        }
    }
}

/// A call that failed: the reason, Try again and Close.
private struct LiveFailureBar: View {
    let message: String
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(VerdeTheme.warning)
                .padding(.leading, 8)
                .accessibilityHidden(true)
            Text(message).font(VerdeTheme.ui(13)).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button(action: retry) {
                Text("Try again").font(VerdeTheme.ui(13, bold: true)).padding(.horizontal, 10).frame(minHeight: 40)
                    .background(VerdeTheme.accent.opacity(0.19), in: Capsule())
                    .overlay(Capsule().stroke(VerdeTheme.accent))
            }
            .buttonStyle(.plain)
            .foregroundStyle(VerdeTheme.accent)
            .accessibilityHint("Starts the live conversation again.")
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(VerdeTheme.muted)
                    .frame(width: 40, height: 40)
                    .background(VerdeTheme.panel, in: Circle())
                    .overlay(Circle().stroke(VerdeTheme.border))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(6)
        .background(VerdeTheme.alternate, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(VerdeTheme.border))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        .frame(maxWidth: 420)
        .padding(.horizontal, 12)
    }
}

/*
 * Shows the call bar in its own window over everything in the app (sheets, alerts, menus) and
 * under the lock shield (`.alert + 1`); it hides while the shield covers the app. The window is
 * never key, so the keyboard and focus stay in the app, and only the bar itself takes touches.
 * While a call runs, the app's content and any presented sheet it would cover start below it.
 */
struct LiveCallBar: UIViewRepresentable {
    let live: LiveVoice
    let companion: CompanionModel
    let pill: LivePillState
    /// A call is connecting, live or failed.
    let call: Bool
    /// The lock shield covers the app.
    let covered: Bool
    /// Closes what the app tracks over the target and reports what it opens over.
    let prepare: (LiveBarTarget) -> LiveBarBase
    /// Opens the target once nothing covers its base.
    let present: (LiveBarTarget, LiveBarBase) -> Void

    func makeUIView(context: Context) -> Anchor { Anchor() }

    func updateUIView(_ view: Anchor, context: Context) {
        view.prepare = prepare
        view.present = present
        view.content = LiveCallBarContent(live: live, companion: companion, pill: pill,
                                          open: { [weak view] target in view?.open(target) },
                                          onFrame: { [weak view] frame in view?.barMoved(frame) })
        view.call = call
        view.covered = covered
        view.refresh()
    }

    static func dismantleUIView(_ view: Anchor, coordinator: ()) { view.tearDown() }

    final class Anchor: UIView {
        /// Space between the bar and the content under it.
        static let gap: CGFloat = 6

        var content: LiveCallBarContent?
        var call = false
        var covered = true
        var prepare: ((LiveBarTarget) -> LiveBarBase)?
        var present: ((LiveBarTarget, LiveBarBase) -> Void)?
        private var bar: LiveCallBarWindow?
        private var controller: UIHostingController<LiveCallBarContent>?
        private let insets = LiveBarInsets()
        private var settle: Task<Void, Never>?

        override func didMoveToWindow() { super.didMoveToWindow(); refresh() }

        func refresh() {
            guard let content, let host = window, let scene = host.windowScene else { return }
            insets.host = host
            if call {
                if let controller {
                    controller.rootView = content
                } else {
                    let overlay = LiveCallBarWindow(windowScene: scene)
                    // Above the app window and everything it presents; the lock shield is higher.
                    overlay.windowLevel = .normal + 1
                    overlay.backgroundColor = .clear
                    overlay.accessibilityViewIsModal = false
                    let controller = UIHostingController(rootView: content)
                    controller.view.backgroundColor = .clear
                    overlay.rootViewController = controller
                    bar = overlay
                    self.controller = controller
                }
                // Never makeKey: the app window keeps the keyboard and focus.
                bar?.isHidden = covered
                insets.enabled = true
            } else {
                controller?.rootView = content
                bar?.isHidden = true
                bar?.touchRect = .null
                insets.enabled = false
            }
        }

        func barMoved(_ frame: CGRect) {
            bar?.touchRect = frame
            insets.barBottom = frame.height > 0 ? frame.maxY + Self.gap : 0
        }

        /// Opens the full view or voice settings: closes what the app tracks over it, waits for
        /// those sheets to go, then presents. Something the app doesn't track (a picker or share
        /// sheet) is left alone, since dismissing it from UIKit can leave SwiftUI's presentation
        /// state out of step; the bar's own controls keep working over it meanwhile.
        func open(_ target: LiveBarTarget) {
            guard let base = prepare?(target), base != .handled else { return }
            settle?.cancel()
            settle = Task { [weak self] in
                for _ in 0..<30 {
                    guard let self, let root = self.window?.rootViewController else { return }
                    let presenting: UIViewController? = base == .companionSheet ? root.presentedViewController : root
                    // The Companion sheet closed meanwhile.
                    guard let presenter = presenting else { return }
                    guard presenter.presentedViewController != nil else {
                        self.present?(target, base)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                    if Task.isCancelled { return }
                }
            }
        }

        func tearDown() {
            settle?.cancel()
            insets.enabled = false
            bar?.isHidden = true
            bar = nil
            controller = nil
        }
    }
}

/// A window that takes touches only on the call bar and never becomes key.
final class LiveCallBarWindow: UIWindow {
    /// The bar in window coordinates; touches anywhere else go to the app below.
    var touchRect: CGRect = .null

    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard touchRect.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/*
 * Reserves the call bar's height so it covers nothing: the app window's root controller and each
 * presented controller the bar overlaps get extra top safe area. Only this class's own share is
 * added and removed. Presentations and sheet detents change without a public callback, so it
 * re-checks a few times a second while a call runs. Changes land outside SwiftUI's view updates.
 */
@MainActor
final class LiveBarInsets {
    private struct Reserved {
        weak var controller: UIViewController?
        var top: CGFloat
    }

    weak var host: UIWindow?
    /// A call is showing the bar (also while the lock shield hides it, so nothing jumps).
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            poll?.cancel()
            poll = nil
            if enabled {
                poll = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self else { return }
                        self.apply()
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            } else {
                // Strong: a dismantled bar still hands the space back.
                Task { if !self.enabled { self.restore() } }
            }
        }
    }
    /// The bar's bottom plus the gap, in window coordinates; 0 before it has been measured.
    var barBottom: CGFloat = 0 { didSet { if barBottom != oldValue { apply() } } }
    private var applied: [ObjectIdentifier: Reserved] = [:]
    private var poll: Task<Void, Never>?

    private func apply() {
        guard enabled, barBottom > 0, let host, let root = host.rootViewController else { return }
        let safeTop = host.safeAreaInsets.top
        var seen = Set<ObjectIdentifier>()
        var next: UIViewController? = root
        while let controller = next {
            let id = ObjectIdentifier(controller)
            var need: CGFloat = 0
            if controller === root {
                // Its view fills the window; presenting a sheet may scale it back, which shouldn't count.
                need = max(0, barBottom - safeTop)
            } else if controller.presentedViewController != nil, let kept = applied[id], kept.controller === controller {
                // A sheet with another stacked on it is pushed back; keep what it had.
                need = kept.top
            } else if !(controller is UIAlertController), let view = controller.viewIfLoaded, view.window === host {
                // Alerts sit centered and don't move their content for the safe area.
                let top = view.convert(view.bounds, to: nil).minY
                need = max(0, barBottom - max(top, safeTop))
            }
            reserve(controller, need)
            seen.insert(id)
            next = controller.presentedViewController
        }
        for (id, entry) in applied where !seen.contains(id) {
            entry.controller?.additionalSafeAreaInsets.top -= entry.top
            applied[id] = nil
        }
    }

    private func restore() {
        for entry in applied.values { entry.controller?.additionalSafeAreaInsets.top -= entry.top }
        applied = [:]
    }

    private func reserve(_ controller: UIViewController, _ top: CGFloat) {
        let id = ObjectIdentifier(controller)
        let old = applied[id].flatMap { $0.controller === controller ? $0.top : nil } ?? 0
        guard abs(top - old) >= 0.5 else { return }
        controller.additionalSafeAreaInsets.top += top - old
        applied[id] = top > 0 ? Reserved(controller: controller, top: top) : nil
    }
}
