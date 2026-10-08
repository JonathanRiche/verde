import UserNotifications

/// Decrypts the relay's sealed payload with the core (`vc_push_open`) using the per-host push
/// keys from the shared Keychain group, and replaces the generic placeholder alert. Any failure
/// leaves the placeholder ("A Verde chat needs attention") exactly as delivered. Nothing is logged.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        handler = contentHandler
        original = request.content
        let content = PushContentBuilder.content(for: request.content) { SharedKeychain.pushRecords() }
        deliver(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let original { deliver(original) }
    }

    private func deliver(_ content: UNNotificationContent) {
        guard let handler else { return }
        self.handler = nil
        original = nil
        handler(content)
    }
}
