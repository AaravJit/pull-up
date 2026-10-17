#if os(iOS)
import CoreLocation
import Foundation
import PullUpDomain

/// Core Location source for real drives.
///
/// * Uses `CLLocationUpdate.liveUpdates(.automotiveNavigation)`, which gives
///   the best accuracy the hardware offers and lets iOS pause when the car
///   is stationary to save battery.
/// * Holds a `CLBackgroundActivitySession` only while recording. With
///   When-In-Use permission plus the `location` background mode, iOS keeps
///   delivering updates after the app leaves the foreground and shows the
///   blue location indicator, so the user always knows recording is on.
///   "Always" permission is never requested.
@MainActor
public final class CoreLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private var serviceSession: CLServiceSession?
    private var updatesTask: Task<Void, Never>?
    private var authorizationWaiters: [CheckedContinuation<LocationPermission, Never>] = []

    public override init() {
        super.init()
        manager.delegate = self
    }

    public var permission: LocationPermission {
        switch manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorizedWhenInUse, .authorizedAlways:
            manager.accuracyAuthorization == .reducedAccuracy ? .reducedAccuracy : .authorized
        @unknown default: .denied
        }
    }

    public func requestPermission() async -> LocationPermission {
        guard manager.authorizationStatus == .notDetermined else { return permission }
        return await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.manager.authorizationStatus != .notDetermined else { return }
            let result = self.permission
            let waiters = self.authorizationWaiters
            self.authorizationWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: result) }
        }
    }

    public func start() -> AsyncStream<LocationEvent> {
        stop()
        serviceSession = CLServiceSession(authorization: .whenInUse, fullAccuracyPurposeKey: "DriveTelemetry")
        backgroundSession = CLBackgroundActivitySession()
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                do {
                    var wasStationary = false
                    for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                        if Task.isCancelled { break }
                        if update.authorizationDenied || update.authorizationDeniedGlobally {
                            continuation.yield(.denied)
                            break
                        }
                        if update.accuracyLimited {
                            continuation.yield(.accuracyReduced)
                            continue
                        }
                        if update.stationary != wasStationary {
                            wasStationary = update.stationary
                            continuation.yield(.stationary(wasStationary))
                        }
                        if let location = update.location {
                            continuation.yield(.sample(LocationSample(location)))
                        } else if update.locationUnavailable {
                            continuation.yield(.unavailable)
                        }
                    }
                } catch {
                    continuation.yield(.unavailable)
                }
                continuation.finish()
            }
            self.updatesTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        serviceSession?.invalidate()
        serviceSession = nil
    }
}

extension LocationSample {
    init(_ location: CLLocation) {
        self.init(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            speed: location.speed,
            speedAccuracy: location.speedAccuracy,
            course: location.course
        )
    }
}
#endif
