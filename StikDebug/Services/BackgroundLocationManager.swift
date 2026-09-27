//
//  BackgroundLocationManager.swift
//  StikDebug
//

import CoreLocation

final class BackgroundLocationManager: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundLocationManager()

    private let locationManager = CLLocationManager()
    private var isRunning = false
    private var persistentEnabled = false
    private var activityCount = 0

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.distanceFilter = CLLocationDistanceMax
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        persistentEnabled = true
        refreshRunningState()
    }

    func stop() {
        persistentEnabled = false
        refreshRunningState()
    }

    func requestStart() {
        activityCount += 1
        refreshRunningState()
    }

    func requestStop() {
        activityCount = max(activityCount - 1, 0)
        refreshRunningState()
    }

    private func refreshRunningState() {
        let shouldRun = persistentEnabled || (activityCount > 0 && UserDefaults.standard.bool(forKey: "keepAliveLocation"))
        guard shouldRun != isRunning else { return }

        isRunning = shouldRun
        guard shouldRun else {
            locationManager.stopUpdatingLocation()
            return
        }

        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            locationManager.startUpdatingLocation()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        case .denied, .restricted:
            restoreAudioFallback()
        @unknown default:
            restoreAudioFallback()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isRunning else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            restoreAudioFallback()
        case .notDetermined:
            return
        @unknown default:
            restoreAudioFallback()
        }
    }

    private func restoreAudioFallback() {
        persistentEnabled = false
        isRunning = activityCount > 0 && UserDefaults.standard.bool(forKey: "keepAliveLocation")
        UserDefaults.standard.set(true, forKey: "keepAliveAudio")
        BackgroundAudioManager.shared.start()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location fixes may fail (e.g. no GPS indoors) — that's fine.
        // The manager just needs to be running, not actually fix a location.
    }
}
