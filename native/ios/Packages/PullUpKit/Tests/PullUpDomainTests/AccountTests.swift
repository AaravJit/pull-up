import Testing
import PullUpDomain

@Suite("Accounts")
struct AccountTests {
    @Test(arguments: ["rx7_kenji", "gsx.r750", "abc", "a1b2c3"])
    func validUsernames(_ name: String) {
        #expect(UsernameRules.localProblem(name) == nil)
    }

    @Test(arguments: ["ab", ".dan", "dan.", "dan__r", "dan._r", "dan r", "DAN!", String(repeating: "a", count: 31)])
    func formatProblems(_ name: String) {
        #expect(UsernameRules.localProblem(name) == .format)
    }

    @Test(arguments: ["admin", "support", "pullup", "pullup_crew", "pull.up.team", "driver_0123456789"])
    func reservedNames(_ name: String) {
        #expect(UsernameRules.localProblem(name) == .reserved)
    }

    @Test func normalisesCaseAndSpaces() {
        #expect(UsernameRules.normalize("  RX7_Kenji ") == "rx7_kenji")
        #expect(UsernameRules.localProblem("  RX7_Kenji ") == nil)
    }

    @Test func recognisesPlaceholderNames() {
        #expect(UsernameRules.isPlaceholder("driver_3f9a1c22e0"))
        #expect(!UsernameRules.isPlaceholder("driver_kenji"))
        #expect(!UsernameRules.isPlaceholder("rx7_kenji"))
    }

    @Test func suggestsFromAppleName() {
        #expect(UsernameRules.suggestion(from: "Kenji Mori") == "kenji_mori")
        #expect(UsernameRules.suggestion(from: "Zoë O'Brien") == "zoe_o_brien")
        #expect(UsernameRules.suggestion(from: "") == "")
        #expect(UsernameRules.suggestion(from: "Al") == "")
    }

    @Test func detectsHideMyEmail() {
        #expect(AccountState.isPrivateRelay("abc123@privaterelay.appleid.com"))
        #expect(AccountState.isPrivateRelay("ABC@PrivateRelay.AppleID.com"))
        #expect(!AccountState.isPrivateRelay("kenji@example.com"))
        #expect(!AccountState.isPrivateRelay(nil))
    }
}
