import Foundation
import Testing
import PullUpDomain

@Suite("Messaging")
struct MessagingTests {
    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test func inboxEntryDecodesFromRPC() throws {
        let json = """
        {"conversation_id":"5b1e7b62-5f0d-4b44-9d5e-0f7a1c2b3d4e","peer_id":"0b6f3e3e-9c1d-4b6a-8f6e-2a1d3c4b5e6f",
         "peer_username":"maya.s15","peer_display_name":"Maya","peer_avatar_path":null,"state":"request","muted":false,
         "last_message_at":"2026-10-17T01:02:03Z","last_message_preview":"Photo","last_message_from_me":false,
         "unread_count":2,"peer_read_at":null}
        """
        let entry = try decoder.decode(InboxEntry.self, from: Data(json.utf8))
        #expect(entry.peer.username == "maya.s15")
        #expect(entry.state == .request)
        #expect(entry.unreadCount == 2)
        #expect(entry.peerReadAt == nil)
        #expect(entry.lastMessageAt != nil)
    }

    @Test func messageDecodesWithSharedObjectAndReactions() throws {
        let json = """
        {"id":"8c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f","conversation_id":"5b1e7b62-5f0d-4b44-9d5e-0f7a1c2b3d4e",
         "sender_id":"0b6f3e3e-9c1d-4b6a-8f6e-2a1d3c4b5e6f","body":"","media_path":null,"media_width":null,"media_height":null,
         "shared_kind":"vehicle","shared_id":"7d0f4a5e-1b7a-4f0e-9a51-3f1c2d6a7b80","created_at":"2026-10-17T01:02:03Z",
         "unsent_at":null,"reactions":[{"user_id":"0b6f3e3e-9c1d-4b6a-8f6e-2a1d3c4b5e6f","emoji":"🔥"},
         {"user_id":"1c6f3e3e-9c1d-4b6a-8f6e-2a1d3c4b5e6f","emoji":"🔥"},{"user_id":"2d6f3e3e-9c1d-4b6a-8f6e-2a1d3c4b5e6f","emoji":"👍"}]}
        """
        let message = try decoder.decode(DirectMessage.self, from: Data(json.utf8))
        #expect(message.shared == SharedRef(kind: .vehicle, id: UUID(uuidString: "7d0f4a5e-1b7a-4f0e-9a51-3f1c2d6a7b80")!))
        #expect(message.reactionCounts.map(\.emoji) == ["🔥", "👍"])
        #expect(message.reactionCounts.first?.count == 2)
        #expect(!message.isUnsent)
    }

    @Test func unavailableSharedPreviewCarriesNothing() throws {
        let json = """
        {"kind":"drive","id":"7d0f4a5e-1b7a-4f0e-9a51-3f1c2d6a7b80","available":false}
        """
        let preview = try decoder.decode(SharedPreview.self, from: Data(json.utf8))
        #expect(preview.available == false)
        #expect(preview.title == nil)
        #expect(preview.ownerID == nil)
    }

    @Test func sharedPreviewToleratesUnknownEnumValues() throws {
        let json = """
        {"kind":"vehicle","id":"7d0f4a5e-1b7a-4f0e-9a51-3f1c2d6a7b80","available":true,"title":"2001 Suzuki GSX-R750",
         "vehicle_kind":"hovercraft","body_style":"sport","identity_color":"plaid"}
        """
        let preview = try decoder.decode(SharedPreview.self, from: Data(json.utf8))
        #expect(preview.vehicleKind == nil)
        #expect(preview.bodyStyle == .sport)
        #expect(preview.identityColor == nil)
    }

    @Test func composerRules() {
        #expect(!MessageRules.canSend(body: "   \n", hasAttachment: false))
        #expect(MessageRules.canSend(body: "", hasAttachment: true))
        #expect(MessageRules.canSend(body: " Sac Nights? ", hasAttachment: false))
        #expect(!MessageRules.canSend(body: String(repeating: "a", count: 2001), hasAttachment: false))
        #expect(MessageRules.remaining("short") == nil)
        #expect(MessageRules.remaining(String(repeating: "a", count: 1900)) == 100)
    }

    @Test func messagingDefaultsLetPeopleReachYouThroughRequests() {
        let settings = PrivacySettings()
        #expect(settings.messagesFrom == .everyone)
        #expect(settings.dmReadReceipts)
        #expect(MessageRules.reactions.count == 7)
    }
}
