import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        // I-10 will decrypt here. Until then, preserve the generic relay alert.
        contentHandler(request.content)
    }
}
