import Foundation
import Observation
import PullUpData
import PullUpDomain

/// The signed-in user's own vehicles. One shared instance backs the Garage
/// tab, the Start Drive picker, profile editing and drive history, so a car
/// added anywhere is immediately selectable everywhere.
@MainActor
@Observable
public final class GarageStore {
    public private(set) var vehicles: [Vehicle] = []
    public private(set) var isLoaded = false
    public private(set) var loadError: String?

    private let backend: any BackendService
    private var owner: UserID?

    public init(backend: any BackendService) {
        self.backend = backend
    }

    /// Vehicles in the user's chosen order, archived ones last and hidden
    /// from the picker.
    public var active: [Vehicle] {
        vehicles.filter { !$0.isArchived }.sorted { ($0.position, $0.year) < ($1.position, $1.year) }
    }

    public var archived: [Vehicle] { vehicles.filter(\.isArchived) }

    public func vehicle(_ id: UUID?) -> Vehicle? {
        guard let id else { return nil }
        return vehicles.first { $0.id == id }
    }

    public func setOwner(_ owner: UserID?) async {
        guard owner != self.owner else { return }
        self.owner = owner
        vehicles = []
        isLoaded = false
        if owner != nil { await reload() }
    }

    public func reload() async {
        guard let owner else { return }
        do {
            vehicles = try await backend.vehicles(owner: owner)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoaded = true
    }

    @discardableResult
    public func save(_ vehicle: Vehicle) async throws -> Vehicle {
        var vehicle = vehicle
        if !vehicles.contains(where: { $0.id == vehicle.id }) {
            vehicle.position = (vehicles.map(\.position).max() ?? -1) + 1
        }
        let saved = try await backend.saveVehicle(vehicle)
        if let i = vehicles.firstIndex(where: { $0.id == saved.id }) {
            vehicles[i] = saved
        } else {
            vehicles.append(saved)
        }
        return saved
    }

    public func delete(_ vehicle: Vehicle) async throws {
        try await backend.deleteVehicle(vehicle.id)
        vehicles.removeAll { $0.id == vehicle.id }
    }

    public func addPhoto(_ data: Data, to vehicle: Vehicle) async throws {
        _ = try await backend.addPhoto(vehicle: vehicle, jpegData: data)
        await reload()
    }

    /// Persists a new manual order.
    public func reorder(_ ordered: [Vehicle]) async {
        for (index, vehicle) in ordered.enumerated() where vehicle.position != index {
            var updated = vehicle
            updated.position = index
            _ = try? await save(updated)
        }
    }
}
