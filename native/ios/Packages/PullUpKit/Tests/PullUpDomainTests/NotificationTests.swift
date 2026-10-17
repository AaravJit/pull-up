import Foundation
import Testing
import PullUpDomain

@Suite("Notification preferences and push routes")
struct NotificationTests {
    @Test func defaultsPushEverythingWithoutMessageText() {
        let prefs = NotificationPreferences()
        for category in NotificationPreferences.Category.allCases { #expect(prefs[category]) }
        #expect(!prefs.messagePreviews)
    }

    @Test func everyKindHasASwitch() {
        let kinds: [AppNotification.Kind] = [
            .follow, .followRequest, .like, .comment, .meetRSVP, .meetUpdated, .meetCancelled, .meetStartingSoon,
            .driveValidated, .message, .messageRequest,
        ]
        for kind in kinds { #expect(NotificationPreferences.Category(kind: kind) != nil) }
    }

    @Test func switchesMatchTheServer() {
        var prefs = NotificationPreferences()
        prefs.likesComments = false
        prefs.messages = false
        #expect(!prefs.pushes(.like))
        #expect(!prefs.pushes(.comment))
        #expect(!prefs.pushes(.message))
        #expect(prefs.pushes(.messageRequest))
        #expect(prefs.pushes(.follow))
    }

    @Test func decodesTheServerRowAndFillsGaps() throws {
        let json = #"{"messages":false,"message_requests":true,"likes_comments":true,"message_previews":true}"#
        let prefs = try JSONDecoder().decode(NotificationPreferences.self, from: Data(json.utf8))
        #expect(!prefs.messages)
        #expect(prefs.messagePreviews)
        #expect(prefs.meets)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs)) as? [String: Bool]
        #expect(encoded?["message_previews"] == true)
        #expect(encoded?["likes_comments"] == true)
    }

    @Test func messagePushesOpenTheirConversation() {
        let id = UUID()
        #expect(PushRoute(kind: "message", conversationID: id.uuidString) == .conversation(id, isRequest: false))
        #expect(PushRoute(kind: "message_request", conversationID: id.uuidString) == .conversation(id, isRequest: true))
    }

    @Test func anythingElseOpensActivity() {
        #expect(PushRoute(kind: "like", conversationID: nil) == .activity)
        #expect(PushRoute(kind: "message", conversationID: "not-a-uuid") == .activity)
        #expect(PushRoute(kind: "something_new", conversationID: nil) == .activity)
        #expect(PushRoute(kind: nil, conversationID: UUID().uuidString) == nil)
    }
}
