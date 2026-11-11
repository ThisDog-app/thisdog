import Intents
import UserNotifications

/// Macht aus einer Mitteilung die Mitteilung einer Person (wie in Nachrichten): mit ihrem Bild links groß.
enum PersonNotification {
    static func content(_ content: UNNotificationContent, from name: String, image: Data?, id: String, conversation: String) async -> UNNotificationContent {
        var parts = PersonNameComponents()
        parts.givenName = name
        let person = INPerson(personHandle: INPersonHandle(value: id, type: .unknown), nameComponents: parts, displayName: name,
                              image: image.map { INImage(imageData: $0) }, contactIdentifier: nil, customIdentifier: id)
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: content.body,
                                         speakableGroupName: nil, conversationIdentifier: conversation, serviceName: nil,
                                         sender: person, attachments: nil)
        if let image { intent.setImage(INImage(imageData: image), forParameterNamed: \.sender) }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try? await interaction.donate()
        return (try? content.updating(from: intent)) ?? content
    }
}
