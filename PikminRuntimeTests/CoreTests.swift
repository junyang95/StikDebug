import CoreLocation
import Foundation
import Testing
@testable import PikminRuntime

struct CoordinateTests {
    @Test func hongKongScreenshotCoordinatesRoundTrip() {
        let map = CLLocationCoordinate2D(latitude: 22.2918, longitude: 114.179)
        let gps = MapCoordinateSystem.gcj02.fromMap(map)
        #expect(gps.latitude > 22.294 && gps.latitude < 22.295)
        #expect(gps.longitude > 114.174 && gps.longitude < 114.175)
        let restored = MapCoordinateSystem.gcj02.toMap(gps)
        #expect(abs(restored.latitude - map.latitude) < 1e-8)
        #expect(abs(restored.longitude - map.longitude) < 1e-8)
    }
    @Test func standardMapKeepsManualGPSExact() {
        let gps = CLLocationCoordinate2D(latitude: 22.2918, longitude: 114.179)
        #expect(MapCoordinateSystem.wgs84.toMap(gps).latitude == gps.latitude)
        #expect(MapCoordinateSystem.wgs84.fromMap(gps).longitude == gps.longitude)
    }
    @Test func shanghaiMatchesKnownTransform() {
        let gps = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let p = MapCoordinateSystem.gcj02.toMap(gps)
        #expect(abs(p.latitude - 31.2284577376) < 1e-7)
        #expect(abs(p.longitude - 121.4782230593) < 1e-7)
    }
    @Test func overseasDestinationsAreUnchanged() {
        for p in [CLLocationCoordinate2D(latitude: 25.033, longitude: 121.5654),
                  CLLocationCoordinate2D(latitude: 35.681, longitude: 139.767),
                  CLLocationCoordinate2D(latitude: 37.775, longitude: -122.419)] {
            #expect(MapCoordinateSystem.gcj02.toMap(p).latitude == p.latitude)
            #expect(MapCoordinateSystem.gcj02.fromMap(p).longitude == p.longitude)
        }
    }
}

struct GuidePolicyTests {
    @Test func unpairedIOS27PresentsGuideOncePerLaunch() {
        #expect(PairingGuidePolicy.shouldPresent(isSupported: true, hasValidPairing: false, presentedThisLaunch: false))
        #expect(!PairingGuidePolicy.shouldPresent(isSupported: true, hasValidPairing: false, presentedThisLaunch: true))
    }
    @Test func pairedAndOlderDevicesDoNotGetAutomaticGuide() {
        #expect(!PairingGuidePolicy.shouldPresent(isSupported: true, hasValidPairing: true, presentedThisLaunch: false))
        #expect(!PairingGuidePolicy.shouldPresent(isSupported: false, hasValidPairing: false, presentedThisLaunch: false))
    }
}
