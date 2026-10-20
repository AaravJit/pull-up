import Foundation
import PullUpDomain

/// A drive on this device: either still recording (crash-recovery copy) or
/// finished and waiting to upload. Raw samples never leave the device except
/// to the owner-only `drive_tracks` table.
public struct DriveDraft: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var ownerID: UserID?
    /// `nil` = guest drive, not associated with a garage vehicle.
    public var vehicleID: UUID?
    public var startedAt: Date
    public var endedAt: Date?
    public var samples: [LocationSample]
    /// When iOS paused updates because the phone was still, so a replay
    /// (recovery, retried upload) treats those silences as stops, not lost
    /// signal. Optional so drafts saved by older builds still decode.
    public var stationaryPauses: [Date]?
    public var title: String
    public var audience: Audience

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

    /// Finished drives not yet confirmed by the server.
    public func pendingUploads() -> [DriveDraft] { all().filter(\.isFinished) }

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
