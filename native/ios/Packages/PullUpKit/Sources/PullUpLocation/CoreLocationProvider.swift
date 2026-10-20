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
                // The live-updates sequence can end or throw (for example when
                // location services hiccup). While recording, start it again
                // after a short pause instead of going silent for the rest of
                // the drive. Only a permission denial or stop() ends the stream.
                var wasStationary = false
                var restartDelay: Duration = .seconds(1)
                restart: while !Task.isCancelled {
                    do {
                        for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                            if Task.isCancelled { break restart }
                            if update.authorizationDenied || update.authorizationDeniedGlobally {
                                continuation.yield(.denied)
                                break restart
                            }
                            if update.accuracyLimited {
                                continuation.yield(.accuracyReduced)
                                continue
                            }
                            if update.location != nil { restartDelay = .seconds(1) }
                            let events = LocationEvent.forUpdate(
                                location: update.location.map { LocationSample($0) },
                                stationary: update.stationary,
                                locationUnavailable: update.locationUnavailable,
                                wasStationary: wasStationary
                            )
                            wasStationary = update.stationary
                            for event in events { continuation.yield(event) }
                        }
                    } catch {
                        continuation.yield(.unavailable)
                    }
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: restartDelay)
                    restartDelay = min(restartDelay * 2, .seconds(30))
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
