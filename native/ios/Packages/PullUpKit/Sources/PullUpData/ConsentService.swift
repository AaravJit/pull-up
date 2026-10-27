import Foundation
import Supabase
import PullUpDomain

/// The terms-acceptance and minimum-age calls. A separate protocol so only a
/// backend with a server implements it: the demo has no server rules and the
/// app treats a backend without it as having nothing to accept.
public protocol ConsentService: Sendable {
    func consentStatus() async throws -> ConsentStatus
    /// Accepts `version`, which must be the current one (the server refuses
    /// an outdated version; reload the status and show the new one).
    func acceptTerms(version: String) async throws -> ConsentStatus
    /// Records only whether the person meets the minimum age.
    func recordAgeCheck(meetsMinimum: Bool) async throws -> ConsentStatus
}

extension SupabaseBackend: ConsentService {
    public func consentStatus() async throws -> ConsentStatus {
        try await client.rpc("my_consent_status").execute().value
    }

    public func acceptTerms(version: String) async throws -> ConsentStatus {
        try await client.rpc("accept_terms", params: ["p_version": version]).execute().value
    }

    public func recordAgeCheck(meetsMinimum: Bool) async throws -> ConsentStatus {
        try await client.rpc("record_age_check", params: ["p_meets_minimum": meetsMinimum]).execute().value
    }
}
