import OSLog
import UserNotifications

/// Mitteilungen aus dem Rudel mit Bild: Der Server schickt nur, wer etwas geändert hat (`by`);
/// Name und Bild liegen auf dem Gerät (App-Gruppe).
final class NotificationService: UNNotificationServiceExtension {
    private var done: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        done = handler
        original = request.content
        let info = request.content.userInfo
        let log = Logger(subsystem: "app.thisDog.notifications", category: "rudel")
        log.notice("Mitteilung: by=\(String(describing: info["by"]), privacy: .public), Verzeichnis: \(PackDirectory.person((info["by"] as? NSNumber)?.intValue ?? -1) != nil, privacy: .public)")
        guard let by = (info["by"] as? NSNumber)?.intValue, let who = PackDirectory.person(by) else {
            handler(request.content)
            return
        }
        let pack = (info["pack"] as? NSNumber)?.intValue ?? 0
        // Apples Schnittstelle stammt aus der Zeit vor Swift Concurrency; der Handler wird genau einmal gerufen.
        nonisolated(unsafe) let finish = handler
        nonisolated(unsafe) let content = request.content
        Task {
            let updated = await PersonNotification.content(content, from: who.name, image: who.image, id: "mitglied-\(by)", conversation: "rudel-\(pack)")
            finish(updated)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let done, let original { done(original) }
    }
}
