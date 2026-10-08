import Foundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

/*
 * I-10 notification handling. The extension decrypts and routes (`userInfo["verde"]`); the app
 * registers categories, decides foreground presentation, forwards pushes to the host's core
 * (`push_received`) and turns taps and actions into navigation plus a hand-off to the chat.
 * Approve/Deny/Reply open the app (after Face ID/passcode): the core only talks to a host while
 * the app is in the foreground, and an approval needs the open thread's `call_id`.
 */

/// One notification interaction, parsed from the extension's routing dictionary.
struct PushTarget: Equatable, Sendable {
    enum Action: Equatable, Sendable { case open, approve, deny, reply(String) }

    static let maxID = 256

    var hostID: String
    var workspaceID: String?
    var threadID: String?
    var turnID: String?
    var kind: String
    var action: Action

    /// `host/workspace/thread`, also the notification's `threadIdentifier`.
    var threadKey: String? {
        guard let workspaceID, let threadID else { return nil }
        return [hostID, workspaceID, threadID].joined(separator: "/")
    }

    /// nil for anything the extension didn't decrypt (the generic placeholder) or that is malformed.
    static func parse(_ userInfo: [AnyHashable: Any], action identifier: String, text: String? = nil) -> PushTarget? {
        guard let route = userInfo[PushUserInfo.root] as? [String: Any] else { return nil }
        func id(_ key: String) -> String? {
            guard let value = route[key] as? String, !value.isEmpty, value.utf8.count <= maxID,
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
            return value
        }
        guard let host = id(PushUserInfo.host), let kind = id(PushUserInfo.kind) else { return nil }
        var target = PushTarget(hostID: host, workspaceID: id(PushUserInfo.workspace), threadID: id(PushUserInfo.thread),
                                turnID: id(PushUserInfo.turn), kind: kind, action: .open)
        if target.workspaceID == nil || target.threadID == nil { target.workspaceID = nil; target.threadID = nil }
        guard target.threadKey != nil else { return target }
        switch identifier {
        case PushCategory.approveAction: target.action = .approve
        case PushCategory.denyAction: target.action = .deny
        case PushCategory.replyAction:
            let reply = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty { target.action = .reply(reply) }
        default: break
        }
        return target
    }

    static func categories() -> Set<UNNotificationCategory> {
        let approve = UNNotificationAction(identifier: PushCategory.approveAction, title: "Approve",
                                           options: [.authenticationRequired, .foreground])
        let deny = UNNotificationAction(identifier: PushCategory.denyAction, title: "Deny",
                                        options: [.authenticationRequired, .destructive, .foreground])
        let reply = UNTextInputNotificationAction(identifier: PushCategory.replyAction, title: "Reply",
                                                  options: [.authenticationRequired, .foreground],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Reply to the agent")
        return [
            UNNotificationCategory(identifier: PushCategory.approval, actions: [approve, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: PushCategory.reply, actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: PushCategory.open, actions: [], intentIdentifiers: []),
        ]
    }
}

/// The chat on screen, readable from the notification delegate's thread.
final class VisibleThread: @unchecked Sendable {
    static let shared = VisibleThread()
    private let lock = NSLock()
    private var key: String?
    var current: String? { lock.lock(); defer { lock.unlock() }; return key }
    func set(_ value: String?) { lock.lock(); key = value; lock.unlock() }
}

/// Notification interactions waiting for the UI, and forwarding to the host cores.
@MainActor @Observable
final class PushInbox {
    static let shared = PushInbox()
    private(set) var pending: PushTarget?
    /// Forwards a delivered push to its host's core (`push_received`).
    @ObservationIgnored var forward: ((PushTarget) -> Void)?

    func received(_ target: PushTarget) { forward?(target) }
    func open(_ target: PushTarget) { pending = target }
    func take() -> PushTarget? {
        defer { pending = nil }
        return pending
    }
}

/// Foreground presentation: a push for the chat already on screen is not shown again.
func presentationOptions(for target: PushTarget?, visible: String?) -> UNNotificationPresentationOptions {
    if let key = target?.threadKey, key == visible { return [] }
    return [.banner, .list, .sound]
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let target = PushTarget.parse(notification.request.content.userInfo, action: UNNotificationDefaultActionIdentifier)
        if let target { Task { @MainActor in PushInbox.shared.received(target) } }
        completionHandler(presentationOptions(for: target, visible: VisibleThread.shared.current))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let text = (response as? UNTextInputNotificationResponse)?.userText
        if response.actionIdentifier != UNNotificationDismissActionIdentifier,
           let target = PushTarget.parse(response.notification.request.content.userInfo, action: response.actionIdentifier, text: text) {
            Task { @MainActor in
                PushInbox.shared.received(target)
                PushInbox.shared.open(target)
            }
        }
        completionHandler()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set by `VerdeApp` before launch completes.
    @MainActor static var registry: PushRegistry?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The delegate must be set before launch returns to receive the launching action.
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationDelegate.shared
        center.setNotificationCategories(PushTarget.categories())
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.registry?.deviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Retried on the next launch or foreground; the error is not logged.
    }
}

// MARK: - Chat hand-off

extension Notification.Name {
    /// A notification hand-off is waiting for the chat that may already be on screen.
    static let verdeChatHandoff = Notification.Name("dev.verdeai.app.chatHandoff")
}

/// Approve/Deny from a notification, waiting for its chat screen.
enum ApprovalHandoff {
    struct Request: Equatable {
        var decision: ApprovalDecision
        var turnID: String?
    }
    private static var pending: [String: Request] = [:]
    private static func key(_ host: String?, _ workspace: String, _ thread: String) -> String {
        (host ?? "") + "\u{0}" + workspace + "\u{0}" + thread
    }
    static func put(host: String?, workspace: String, thread: String, _ request: Request) { pending[key(host, workspace, thread)] = request }
    static func take(host: String?, workspace: String, thread: String) -> Request? { pending.removeValue(forKey: key(host, workspace, thread)) }
    static func clear() { pending.removeAll() }
}

extension TranscriptModel {
    /// The push payload has no `call_id`: wait for this (now focused) thread's approval and answer
    /// it only when it belongs to the notified turn. Returns whether a decision was sent.
    func decideFromNotification(_ request: ApprovalHandoff.Request, wait: Duration = .seconds(60)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: wait)
        while !closed, ContinuousClock.now < deadline {
            if let view = thread {
                if let approval = view.approval {
                    guard request.turnID == nil || approval.turn_id == request.turnID else { return false }
                    if approval.resolution != "pending" { return approvals.decide(approval, request.decision) }
                } else if !view.stale, let turn = request.turnID, view.turn?.turn_id != turn {
                    return false // That turn moved on: answered elsewhere or finished.
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

// MARK: - Settings

struct NotificationSettingsSection: View {
    let registry: PushRegistry
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section("Notifications") {
            if !registry.available {
                Text("Push notifications aren't available in this build.").font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.muted)
            } else {
                switch registry.authorization {
                case .authorized:
                    LabeledContent("Notifications", value: "On")
                case .notDetermined:
                    Button("Turn on notifications") { Task { await registry.requestPermission() } }
                case .denied:
                    Button("Allow notifications in iOS Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                }
                Text("Get notified when an agent needs approval or input, or finishes. Content is end-to-end encrypted from your host.")
                    .font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
            }
        }
        .task { await registry.refresh() }
    }
}
