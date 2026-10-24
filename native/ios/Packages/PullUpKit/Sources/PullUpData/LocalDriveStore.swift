import Foundation
import PullUpDomain
import Supabase

/// A drive on this device: either still recording (crash-recovery copy) or
/// finished and waiting to upload. Raw samples never leave the device except
/// to the owner-only `drive_tracks` table.
public struct DriveDraft: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var ownerID: UserID?
    /// `nil` = guest drive, not associated with a garage vehicle.
    public var vehicleID: UUID?
    /// The vehicle as it was when recording started, so a drive resumed
    /// offline (garage not loaded) still shows which car it is. Optional so
    /// drafts saved by older builds still decode.
    public var vehicle: Vehicle?
    public var startedAt: Date
    public var endedAt: Date?
    public var samples: [LocationSample]
    /// When iOS paused updates because the phone was still, so a replay
    /// (recovery, retried upload) treats those silences as stops, not lost
    /// signal. Optional so drafts saved by older builds still decode.
    public var stationaryPauses: [Date]?
    public var title: String
    public var audience: Audience
    /// When the server refused this drive for good (its data, not the
    /// connection). It's then kept but not retried on its own. Optional so
    /// drafts saved by older builds still decode.
    public var rejectedAt: Date?

    public init(id: UUID = UUID(), ownerID: UserID?, vehicleID: UUID?, startedAt: Date, endedAt: Date? = nil,
                samples: [LocationSample] = [], title: String = "", audience: Audience = .private) {
        self.id = id
        self.ownerID = ownerID
        self.vehicleID = vehicleID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.samples = samples
        self.title = title
        self.audience = audience
    }

    public var isFinished: Bool { endedAt != nil }
    public var isRejected: Bool { rejectedAt != nil }

    /// Whether the server refused an upload for good, so sending the same
    /// drive again can never work: Postgres data exceptions (class 22, such
    /// as a track that's too large) and integrity violations (class 23, such
    /// as the distance bounds check). A duplicate key (23505) only means an
    /// earlier attempt got there first, so that's retried like a lost
    /// connection.
    public static func isPermanentRejection(_ error: any Error) -> Bool {
        guard let code = (error as? any SQLStateError)?.sqlState, code != "23505" else { return false }
        return code.hasPrefix("22") || code.hasPrefix("23")
    }
}

/// A server error that carries a Postgres error code (SQLSTATE).
public protocol SQLStateError: Error {
    var sqlState: String? { get }
}

extension PostgrestError: SQLStateError {
    public var sqlState: String? { code }
}

/// Persists drafts as one JSON file each. Writes are atomic and the files use
/// `completeUntilFirstUserAuthentication` protection so a recording that
/// continues while the phone is locked can still be saved.
public actor LocalDriveStore {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) {
        self.directory = directory
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    public static func standard() -> LocalDriveStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LocalDriveStore(directory: base.appendingPathComponent("Drives", isDirectory: true))
    }

    private func ensureDirectory() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true // location history doesn't belong in iCloud backups
        var dir = directory
        try? dir.setResourceValues(values)
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    public func save(_ draft: DriveDraft) throws {
        try ensureDirectory()
        let data = try encoder.encode(draft)
        #if os(iOS)
        try data.write(to: url(for: draft.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url(for: draft.id), options: [.atomic])
        #endif
    }

    public func load(_ id: UUID) -> DriveDraft? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? decoder.decode(DriveDraft.self, from: data)
    }

    public func all() -> [DriveDraft] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(DriveDraft.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Finished drives not yet confirmed by the server, other than those it
    /// refused.
    public func pendingUploads() -> [DriveDraft] { all().filter { $0.isFinished && !$0.isRejected } }

    /// Finished drives the server refused. Kept until the person deletes
    /// them or asks to try again.
    public func rejectedUploads() -> [DriveDraft] { all().filter { $0.isFinished && $0.isRejected } }

    /// Marks a finished drive as refused by the server, or clears the mark
    /// (`nil`) so it's retried. Does nothing if the drive is gone.
    public func markRejected(_ id: UUID, at date: Date?) throws {
        guard var draft = load(id), draft.isFinished else { return }
        draft.rejectedAt = date
        try save(draft)
    }

    /// A recording that never finished, e.g. the app was killed mid-drive.
    public func interrupted() -> DriveDraft? { all().last { !$0.isFinished } }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Removes every draft recorded by `owner`, finished or not.
    public func deleteAll(owner: UserID) {
        for draft in all() where draft.ownerID == owner { delete(draft.id) }
    }
}
