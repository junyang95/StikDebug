import CoreLocation
import Testing
@testable import StikDebug

private struct PairingStoreFixture {
    let fileManager = FileManager.default
    let rootURL: URL
    let locations: PairingFileStore.Locations

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairingFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        let storageDirectory = rootURL
            .appendingPathComponent("ApplicationSupport/Pairing", isDirectory: true)
        let documentsDirectory = rootURL.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documentsDirectory,
            withIntermediateDirectories: true
        )
        locations = PairingFileStore.Locations(
            directoryURL: storageDirectory,
            destinationURL: storageDirectory.appendingPathComponent("rp_pairing_file.plist"),
            documentCandidateURLs: [
                documentsDirectory.appendingPathComponent("pairingFile.plist"),
                documentsDirectory.appendingPathComponent("rp_pairing_file.plist")
            ],
            legacyInternalURLs: [storageDirectory.appendingPathComponent("pairingFile.plist")]
        )
    }

    var validator: PairingFileStore.Validator {
        { url in
            (try? String(contentsOf: url, encoding: .utf8))?.hasPrefix("VALID-") == true
        }
    }

    func write(_ value: String, to url: URL, modifiedAt: Date? = nil) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url, options: .atomic)
        if let modifiedAt {
            try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
    }

    func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func cleanUp() {
        try? fileManager.removeItem(at: rootURL)
    }
}

struct PikminHelperTests {
    @Test
    func reconnectPolicyIsBoundedAndBacksOff() {
        let delays = SessionReconnectPolicy.retryDelaysSeconds

        #expect(!delays.isEmpty)
        #expect(SessionReconnectPolicy.maximumAttempts == delays.count)
        #expect(delays == delays.sorted())
        #expect(delays.last == 8)
    }

    @Test(arguments: [
        (completed: false, forceShow: false, pairingFileExists: false, expected: true),
        (completed: true, forceShow: false, pairingFileExists: false, expected: false),
        (completed: false, forceShow: false, pairingFileExists: true, expected: false),
        (completed: true, forceShow: true, pairingFileExists: true, expected: true)
    ])
    func setupGateChoosesTheExpectedEntryPoint(
        completed: Bool,
        forceShow: Bool,
        pairingFileExists: Bool,
        expected: Bool
    ) {
        #expect(SetupGate.shouldPresent(
            completed: completed,
            forceShow: forceShow,
            pairingFileExists: pairingFileExists
        ) == expected)
    }

    @Test
    func destinationMovesExpectedDistanceNorth() {
        let start = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let end = MovementMath.destination(
            from: start,
            distance: 100,
            bearingDegrees: 0
        )
        let measured = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))

        #expect(abs(measured - 100) < 0.5)
        #expect(end.latitude > start.latitude)
    }

    @Test
    func destinationMovesExpectedBearingEast() {
        let start = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let end = MovementMath.destination(
            from: start,
            distance: 100,
            bearingDegrees: 90
        )

        #expect(end.longitude > start.longitude)
        #expect(abs(end.latitude - start.latitude) < 0.0001)
    }

    @Test
    func jitterOffsetStaysWithinConfiguredRadius() {
        let start = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let offset = MovementMath.offset(start, eastMeters: 1.8, northMeters: 2.0)
        let measured = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: offset.latitude, longitude: offset.longitude))

        #expect(measured < 3)
        #expect(measured > 2)
    }

    @Test
    func defaultWalkingMathMatchesPlan() {
        let config = WalkingSessionConfig(
            startLatitude: 31.2304,
            startLongitude: 121.4737
        )
        let stepsPerKilometer = Int(1_000 / config.strideMeters)

        #expect(abs(config.speedMetersPerSecond - 1.3889) < 0.001)
        #expect(stepsPerKilometer == 1_333)
    }

    @Test
    func walkingPacesResolvePresetAndCustomSpeeds() {
        #expect(WalkingPace.matching(speedKilometersPerHour: 3.5) == .stroll)
        #expect(WalkingPace.matching(speedKilometersPerHour: 5.0) == .natural)
        #expect(WalkingPace.matching(speedKilometersPerHour: 6.5) == .brisk)
        #expect(WalkingPace.matching(speedKilometersPerHour: 7.0) == .custom)
    }

    @Test
    func naturalSpeedVariationIsSmoothAndBounded() {
        let start = NaturalSpeedVariation.multiplier(
            from: -0.06,
            to: 0.06,
            progress: 0,
            maximumFraction: 0.06
        )
        let middle = NaturalSpeedVariation.multiplier(
            from: -0.06,
            to: 0.06,
            progress: 0.5,
            maximumFraction: 0.06
        )
        let end = NaturalSpeedVariation.multiplier(
            from: -0.06,
            to: 0.06,
            progress: 1,
            maximumFraction: 0.06
        )

        #expect(abs(start - 0.94) < 0.0001)
        #expect(abs(middle - 1.0) < 0.0001)
        #expect(abs(end - 1.06) < 0.0001)
    }

    @Test
    func recentLocationsDeduplicateAndKeepNewestFirst() throws {
        let suiteName = "RecentLocationStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let shanghai = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let nearby = MovementMath.offset(shanghai, eastMeters: 8, northMeters: 4)
        let tokyo = CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671)

        _ = RecentLocationStore.record(
            shanghai,
            name: "上海",
            at: Date(timeIntervalSince1970: 100),
            in: defaults
        )
        _ = RecentLocationStore.record(
            tokyo,
            name: "东京",
            at: Date(timeIntervalSince1970: 200),
            in: defaults
        )
        let result = RecentLocationStore.record(
            nearby,
            name: nil,
            at: Date(timeIntervalSince1970: 300),
            in: defaults
        )

        #expect(result.count == 2)
        #expect(result[0].name == "上海")
        #expect(result[0].lastUsedAt == Date(timeIntervalSince1970: 300))
        #expect(result[1].name == "东京")
    }

    @Test
    func routePlanningStylesKeepWalkingAsDefault() {
        #expect(RoutePlanningStyle.footpaths.transportType == .walking)
        #expect(RoutePlanningStyle.roads.transportType == .automobile)

        let route = SavedWalkingRoute(
            name: "道路路线",
            coordinates: [
                CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
                CLLocationCoordinate2D(latitude: 31.2314, longitude: 121.4747)
            ],
            isLoop: false,
            planningStyle: .roads
        )
        #expect(route.planningStyle == .roads)
    }

    @Test
    func importingDocumentSourceStagesBeforeRemovingIt() throws {
        let fixture = try PairingStoreFixture()
        defer { fixture.cleanUp() }
        try fixture.write("VALID-old", to: fixture.locations.destinationURL)
        let documentSource = fixture.locations.documentCandidateURLs[0]
        try fixture.write("VALID-new", to: documentSource)

        try PairingFileStore.replace(
            with: documentSource,
            fileManager: fixture.fileManager,
            locations: fixture.locations,
            validator: fixture.validator
        )

        #expect(try fixture.read(fixture.locations.destinationURL) == "VALID-new")
        #expect(!fixture.fileManager.fileExists(atPath: documentSource.path))
    }

    @Test
    func invalidDocumentCandidatePreservesKnownGoodFile() throws {
        let fixture = try PairingStoreFixture()
        defer { fixture.cleanUp() }
        try fixture.write("VALID-known-good", to: fixture.locations.destinationURL)
        let documentSource = fixture.locations.documentCandidateURLs[0]
        try fixture.write("BROKEN-new", to: documentSource)

        let result = try PairingFileStore.synchronizeFromDocuments(
            fileManager: fixture.fileManager,
            locations: fixture.locations,
            validator: fixture.validator
        )

        #expect(result == .rejected)
        #expect(try fixture.read(fixture.locations.destinationURL) == "VALID-known-good")
        #expect(fixture.fileManager.fileExists(atPath: documentSource.path))
    }

    @Test
    func synchronizationChoosesNewestValidCandidate() throws {
        let fixture = try PairingStoreFixture()
        defer { fixture.cleanUp() }
        let newerSource = fixture.locations.documentCandidateURLs[0]
        let olderSource = fixture.locations.documentCandidateURLs[1]
        try fixture.write(
            "VALID-older",
            to: olderSource,
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        try fixture.write(
            "VALID-newer",
            to: newerSource,
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let result = try PairingFileStore.synchronizeFromDocuments(
            fileManager: fixture.fileManager,
            locations: fixture.locations,
            validator: fixture.validator
        )

        #expect(result == .updated)
        #expect(try fixture.read(fixture.locations.destinationURL) == "VALID-newer")
        #expect(!fixture.fileManager.fileExists(atPath: newerSource.path))
        #expect(!fixture.fileManager.fileExists(atPath: olderSource.path))
    }

    @Test
    func synchronizationFallsBackToOlderValidCandidate() throws {
        let fixture = try PairingStoreFixture()
        defer { fixture.cleanUp() }
        let newerSource = fixture.locations.documentCandidateURLs[0]
        let olderSource = fixture.locations.documentCandidateURLs[1]
        try fixture.write(
            "BROKEN-newer",
            to: newerSource,
            modifiedAt: Date(timeIntervalSince1970: 200)
        )
        try fixture.write(
            "VALID-older",
            to: olderSource,
            modifiedAt: Date(timeIntervalSince1970: 100)
        )

        let result = try PairingFileStore.synchronizeFromDocuments(
            fileManager: fixture.fileManager,
            locations: fixture.locations,
            validator: fixture.validator
        )

        #expect(result == .updated)
        #expect(try fixture.read(fixture.locations.destinationURL) == "VALID-older")
    }

    @Test
    func prepareURLDoesNotConsumeDocumentDelivery() throws {
        let fixture = try PairingStoreFixture()
        defer { fixture.cleanUp() }
        let documentSource = fixture.locations.documentCandidateURLs[0]
        try fixture.write("VALID-delivery", to: documentSource)

        _ = PairingFileStore.prepareURL(
            fileManager: fixture.fileManager,
            locations: fixture.locations,
            validator: fixture.validator
        )

        #expect(fixture.fileManager.fileExists(atPath: documentSource.path))
        #expect(!fixture.fileManager.fileExists(atPath: fixture.locations.destinationURL.path))
    }

    @Test
    func stateSignatureDetectsSameSizeSameTimestampRewrite() throws {
        let fixture = try PairingStoreFixture()
        defer { fixture.cleanUp() }
        let fixedDate = Date(timeIntervalSince1970: 1_000)
        try fixture.write("VALID-AAAA", to: fixture.locations.destinationURL, modifiedAt: fixedDate)
        let firstSignature = PairingFileStore.stateSignature(
            fileManager: fixture.fileManager,
            locations: fixture.locations
        )

        try fixture.write("VALID-BBBB", to: fixture.locations.destinationURL, modifiedAt: fixedDate)
        let secondSignature = PairingFileStore.stateSignature(
            fileManager: fixture.fileManager,
            locations: fixture.locations
        )

        #expect(firstSignature != secondSignature)
    }
}
