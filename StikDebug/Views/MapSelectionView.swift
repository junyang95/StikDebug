//
//  MapSelectionView.swift
//  StikDebug
//
//  Created by Stephen on 11/3/25.
//

import SwiftUI
import MapKit
import UIKit
import UniformTypeIdentifiers

private struct CoordinateSnapshot: Equatable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}


enum RouteSimulationDefaults {
    static let pathSamplingDistance: CLLocationDistance = 10
    static let minimumSpeedMetersPerSecond: CLLocationSpeed = 1.0
}


extension MKPolyline {
    var coordinateArray: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: pointCount
        )
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}

private func interpolateCoordinate(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    fraction: Double
) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
        latitude: start.latitude + ((end.latitude - start.latitude) * fraction),
        longitude: start.longitude + ((end.longitude - start.longitude) * fraction)
    )
}

func sampledRouteCoordinates(
    from coordinates: [CLLocationCoordinate2D],
    targetDistance: CLLocationDistance
) -> [CLLocationCoordinate2D] {
    guard coordinates.count > 1 else { return coordinates }

    var sampled = [coordinates[0]]
    for (start, end) in zip(coordinates, coordinates.dropFirst()) {
        let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        let segmentCount = max(1, Int(ceil(distance / targetDistance)))
        for index in 1...segmentCount {
            let point = interpolateCoordinate(
                from: start,
                to: end,
                fraction: Double(index) / Double(segmentCount)
            )
            if sampled.last.map(CoordinateSnapshot.init) != CoordinateSnapshot(point) {
                sampled.append(point)
            }
        }
    }

    return sampled
}

private func distanceAlong(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
    zip(coordinates, coordinates.dropFirst()).reduce(0) { total, pair in
        total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
    }
}

private enum CoordinateImportError: LocalizedError {
    case emptyFile
    case noCoordinates

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "选择的文件是空的。".localized
        case .noCoordinates:
            return "没有找到有效坐标。支持 GPX、KML、GeoJSON、JSON、CSV，或每行一组经纬度的纯文本。".localized
        }
    }
}

private enum CoordinateImportParser {
    static let supportedContentTypes: [UTType] = [
        .plainText,
        .commaSeparatedText,
        .json,
        .xml,
        UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "kml", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "geojson", conformingTo: .json) ?? .json
    ]

    private enum CoordinateOrder {
        case latitudeLongitude
        case longitudeLatitude
    }

    static func parse(url: URL) throws -> [CLLocationCoordinate2D] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw CoordinateImportError.emptyFile }

        let fileExtension = url.pathExtension.lowercased()
        if fileExtension == "json" || fileExtension == "geojson" {
            if let coordinates = try? parseJSONCoordinates(from: data),
               !coordinates.isEmpty {
                return coordinates
            }
        }

        if fileExtension == "gpx" || fileExtension == "kml" || fileExtension == "xml" {
            let coordinates = parseXMLCoordinates(from: data)
            if !coordinates.isEmpty {
                return coordinates
            }
        }

        if let text = decodedText(from: data) {
            let coordinates = parseInline(text)
            if !coordinates.isEmpty {
                return coordinates
            }
        }

        if let coordinates = try? parseJSONCoordinates(from: data),
           !coordinates.isEmpty {
            return coordinates
        }

        let coordinates = parseXMLCoordinates(from: data)
        if !coordinates.isEmpty {
            return coordinates
        }

        throw CoordinateImportError.noCoordinates
    }

    static func parseInline(_ text: String) -> [CLLocationCoordinate2D] {
        sanitized(parseTextCoordinates(from: text))
    }

    private static func decodedText(from data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .ascii)
    }

    private static func sanitized(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for coordinate in coordinates where CLLocationCoordinate2DIsValid(coordinate) {
            if result.last.map(CoordinateSnapshot.init) == CoordinateSnapshot(coordinate) {
                continue
            }
            result.append(coordinate)
        }
        return result
    }

    private static func coordinate(
        first: Double,
        second: Double,
        order: CoordinateOrder
    ) -> CLLocationCoordinate2D? {
        let preferred: CLLocationCoordinate2D
        let fallback: CLLocationCoordinate2D

        switch order {
        case .latitudeLongitude:
            preferred = CLLocationCoordinate2D(latitude: first, longitude: second)
            fallback = CLLocationCoordinate2D(latitude: second, longitude: first)
        case .longitudeLatitude:
            preferred = CLLocationCoordinate2D(latitude: second, longitude: first)
            fallback = CLLocationCoordinate2D(latitude: first, longitude: second)
        }

        if CLLocationCoordinate2DIsValid(preferred) {
            return preferred
        }
        if CLLocationCoordinate2DIsValid(fallback) {
            return fallback
        }
        return nil
    }

    private static func parseJSONCoordinates(from data: Data) throws -> [CLLocationCoordinate2D] {
        let object = try JSONSerialization.jsonObject(with: data)
        return sanitized(coordinates(fromJSONObject: object, order: .latitudeLongitude))
    }

    private static func coordinates(
        fromJSONObject object: Any,
        order: CoordinateOrder
    ) -> [CLLocationCoordinate2D] {
        if let dictionary = object as? [String: Any] {
            if let latitude = numberValue(forAnyKey: ["latitude", "lat"], in: dictionary),
               let longitude = numberValue(forAnyKey: ["longitude", "lon", "lng"], in: dictionary),
               let coordinate = coordinate(first: latitude, second: longitude, order: .latitudeLongitude) {
                return [coordinate]
            }

            if let geometry = dictionary["geometry"] {
                return coordinates(fromJSONObject: geometry, order: order)
            }

            if let type = dictionary["type"] as? String {
                let loweredType = type.lowercased()
                if loweredType == "featurecollection",
                   let features = dictionary["features"] as? [Any] {
                    return features.flatMap { coordinates(fromJSONObject: $0, order: .longitudeLatitude) }
                }
                if loweredType == "geometrycollection",
                   let geometries = dictionary["geometries"] as? [Any] {
                    return geometries.flatMap { coordinates(fromJSONObject: $0, order: .longitudeLatitude) }
                }
                if let coordinateObject = dictionary["coordinates"] {
                    return coordinates(fromJSONObject: coordinateObject, order: .longitudeLatitude)
                }
            }

            return dictionary.values.flatMap { coordinates(fromJSONObject: $0, order: order) }
        }

        if let array = object as? [Any] {
            if array.count >= 2,
               let first = numericValue(array[0]),
               let second = numericValue(array[1]),
               let coordinate = coordinate(first: first, second: second, order: order) {
                return [coordinate]
            }

            return array.flatMap { coordinates(fromJSONObject: $0, order: order) }
        }

        return []
    }

    private static func numericValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func numberValue(forAnyKey keys: [String], in dictionary: [String: Any]) -> Double? {
        let keyedValues = Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key.lowercased(), $0.value) })
        for key in keys {
            if let value = keyedValues[key],
               let number = numericValue(value) {
                return number
            }
        }
        return nil
    }

    private static func parseXMLCoordinates(from data: Data) -> [CLLocationCoordinate2D] {
        let collector = XMLCoordinateCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return [] }
        return sanitized(collector.coordinates)
    }

    private final class XMLCoordinateCollector: NSObject, XMLParserDelegate {
        var coordinates: [CLLocationCoordinate2D] = []
        private var isCollectingKMLCoordinates = false
        private var kmlCoordinateBuffer = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = elementName.lowercased()
            if ["wpt", "trkpt", "rtept"].contains(name),
               let latitude = Double(attributeDict["lat"] ?? ""),
               let longitude = Double(attributeDict["lon"] ?? ""),
               let coordinate = CoordinateImportParser.coordinate(
                    first: latitude,
                    second: longitude,
                    order: .latitudeLongitude
               ) {
                coordinates.append(coordinate)
            } else if name == "coordinates" {
                isCollectingKMLCoordinates = true
                kmlCoordinateBuffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isCollectingKMLCoordinates {
                kmlCoordinateBuffer += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard elementName.lowercased() == "coordinates" else { return }
            coordinates.append(contentsOf: CoordinateImportParser.parseKMLCoordinateText(kmlCoordinateBuffer))
            isCollectingKMLCoordinates = false
            kmlCoordinateBuffer = ""
        }
    }

    private static func parseKMLCoordinateText(_ text: String) -> [CLLocationCoordinate2D] {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { token -> CLLocationCoordinate2D? in
                let values = token
                    .split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard values.count >= 2 else { return nil }
                return coordinate(first: values[0], second: values[1], order: .longitudeLatitude)
            }
    }

    private static func parseTextCoordinates(from text: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var headerIndices: (latitude: Int, longitude: Int)?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let fields = splitFields(trimmed)
            if headerIndices == nil,
               let detectedHeader = detectHeader(in: fields) {
                headerIndices = detectedHeader
                continue
            }

            if let headerIndices,
               fields.indices.contains(headerIndices.latitude),
               fields.indices.contains(headerIndices.longitude),
               let latitude = numbers(in: fields[headerIndices.latitude]).first,
               let longitude = numbers(in: fields[headerIndices.longitude]).first,
               let coordinate = coordinate(first: latitude, second: longitude, order: .latitudeLongitude) {
                coordinates.append(coordinate)
                continue
            }

            let values = numbers(in: trimmed)
            if values.count >= 2,
               let coordinate = coordinate(first: values[0], second: values[1], order: .latitudeLongitude) {
                coordinates.append(coordinate)
            }
        }

        return coordinates
    }

    private static func splitFields(_ line: String) -> [String] {
        line
            .split { character in
                character == "," ||
                character == ";" ||
                character == "\t"
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func detectHeader(in fields: [String]) -> (latitude: Int, longitude: Int)? {
        let lowered = fields.map { $0.lowercased() }
        guard let latitude = lowered.firstIndex(where: { $0 == "lat" || $0 == "latitude" }),
              let longitude = lowered.firstIndex(where: { $0 == "lon" || $0 == "lng" || $0 == "long" || $0 == "longitude" }) else {
            return nil
        }
        return (latitude, longitude)
    }

    private static func numbers(in text: String) -> [Double] {
        let pattern = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return Double(text[matchRange])
        }
    }
}

// MARK: - Search Completer

@MainActor
final class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = query
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

struct LocationSimulationView: View {
    @EnvironmentObject private var walkingSession: WalkingSessionController
    @EnvironmentObject private var preflight: EnvironmentPreflightService
    @Binding var selectedMode: MovementMode
    @AppStorage(MovementDefaultsKey.profile) private var profileRaw = MovementProfile.walking.rawValue
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @State private var resendTimer: Timer?
    @State private var isBusy = false
    @State private var isImportingCoordinates = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    @State private var searchText = ""
    @StateObject private var searchCompleter = LocationSearchCompleter()
    @State private var showCoordinateImporter = false
    @State private var simulatedCoordinate: CLLocationCoordinate2D?
    @State private var routeGoalKind: SessionGoalKind = .distance
    @State private var routeGoalValue = 5.0

    @StateObject private var waypointPlanner = WaypointRoutePlanner()
    @State private var savedRoutes: [SavedWalkingRoute] = []
    @State private var showSaveRoute = false
    @State private var newRouteName = ""
    @State private var showCoordinateEntry = false
    @State private var coordinateEntryText = ""
    @State private var showGPXExporter = false
    @State private var gpxDocument: GPXRouteDocument?
    @State private var gpxFilename = "Pikmin-Helper-Route"
    @State private var isDrawingRoute = false
    @State private var freehandCoordinates: [CLLocationCoordinate2D] = []

    private static let routeDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    // Bookmarks
    @State private var bookmarks: [LocationBookmark] = []
    @State private var showSaveBookmark = false
    @State private var newBookmarkName = ""
    @State private var recentLocations: [RecentLocation] = []
    @State private var showLocationLibrary = false
    @State private var librarySection: LocationLibrarySection = .recents
    @State private var selectedLocationName: String?

    private var pairingFilePath: String {
        PairingFileStore.prepareURL().path
    }

    private var pairingExists: Bool {
        FileManager.default.fileExists(atPath: pairingFilePath)
    }

    private var deviceIP: String {
        DeviceConnectionContext.targetIPAddress
    }

    private var isRouteRunning: Bool {
        walkingSession.isActive
    }

    /// 地图当前是否处于连点画路线的状态。
    private var hasWaypointContext: Bool {
        selectedMode == .route
    }

    private var profile: MovementProfile {
        MovementProfile(rawValue: profileRaw) ?? .walking
    }

    private var waypointSpeedMetersPerSecond: CLLocationSpeed {
        max(
            MovementParameters.current().speedMetersPerSecond,
            RouteSimulationDefaults.minimumSpeedMetersPerSecond
        )
    }

    private var waypointStatusText: String {
        if walkingSession.isActive {
            return waypointPlanner.isClosedLoop
                ? String(format: "正在绕圈%@，走完一圈会自动继续下一圈".localized, profile.title)
                : String(format: "正在沿路径%@，到终点后自动原路返回".localized, profile.title)
        }
        if waypointPlanner.isEmpty {
            return "在地图上点几个点，它们会按顺序连成行走路径".localized
        }
        if let name = waypointPlanner.importedName {
            return String(format: "已载入「%@」，如需自己连点请先清空".localized, name)
        }
        if waypointPlanner.waypoints.count == 1 {
            return "已放下起点，再点一个点就能生成路径".localized
        }
        if waypointPlanner.isPlanning {
            return "正在规划步行路线…".localized
        }
        let straightCount = waypointPlanner.straightLineLegCount
        if straightCount > 0 {
            return String(format: "路径已就绪，其中 %d 段没有步行路线，按直线通过".localized, straightCount)
        }
        return waypointPlanner.isClosedLoop
            ? "闭环路径已就绪，可以开始绕圈".localized
            : String(format: "路径已就绪，可以%@".localized, profile.startActionTitle)
    }

    /// 目标输入框直接标出单位，避免「5」到底是 5 公里还是 5 米。
    private var goalPlaceholder: String {
        switch routeGoalKind {
        case .steps: "步数".localized
        case .distance: "公里".localized
        case .duration: "分钟".localized
        case .manual: ""
        }
    }

    private var waypointSummaryText: String? {
        guard waypointPlanner.waypoints.count >= 2, !waypointPlanner.isPlanning else { return nil }
        let distanceText = Measurement(
            value: waypointPlanner.totalDistance / 1000,
            unit: UnitLength.kilometers
        ).formatted(.measurement(width: .abbreviated, usage: .road))
        let duration = waypointPlanner.estimatedTravelTime(
            speedMetersPerSecond: waypointSpeedMetersPerSecond
        )
        let durationText = Self.routeDurationFormatter.string(from: duration)
        let pointsText = waypointPlanner.isImported
            ? String(format: "轨迹 %d 点".localized, waypointPlanner.importedPointCount)
            : String(format: "%d 个点".localized, waypointPlanner.waypoints.count)
        if let durationText, !durationText.isEmpty {
            return String(format: "%1$@ • %2$@ • 约 %3$@".localized, pointsText, distanceText, durationText)
        }
        return "\(pointsText) • \(distanceText)"
    }

    private var searchResultsListBase: some View {
        List(searchCompleter.results.prefix(5), id: \.self) { result in
            Button {
                selectSearchResult(result)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.subheadline)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: 300)
        .scrollDisabled(true)
    }

    private var freehandPolyline: MKPolyline? {
        guard freehandCoordinates.count > 1 else { return nil }
        return freehandCoordinates.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return MKPolyline(coordinates: baseAddress, count: buffer.count)
        }
    }

    // 搜索结果做成和底部操作卡一致的不透明浮层，而不是半透明材质。
    @ViewBuilder
    private var searchResultsList: some View {
        searchResultsListBase
            .padding(.vertical, 6)
            .background(PikminUI.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 8)
            .padding(.horizontal, 16)
            .padding(.top, 10)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MapReader { proxy in
                Map(position: $position) {
                    if hasWaypointContext {
                        ForEach(waypointPlanner.legPolylines) { leg in
                            MapPolyline(leg.polyline)
                                .stroke(
                                    routeColor(for: leg),
                                    style: StrokeStyle(
                                        lineWidth: 5,
                                        lineCap: .round,
                                        dash: leg.isStraightLine ? [10, 8] : []
                                    )
                                )
                        }
                        if let freehandPolyline {
                            MapPolyline(freehandPolyline)
                                .stroke(
                                    .orange,
                                    style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                                )
                        }
                        ForEach(Array(waypointPlanner.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                            Annotation("", coordinate: waypoint.coordinate) {
                                WaypointBadge(
                                    number: index + 1,
                                    total: waypointPlanner.waypoints.count,
                                    isLoop: waypointPlanner.isClosedLoop
                                )
                            }
                        }
                        if walkingSession.isActive, let coordinate = walkingSession.currentCoordinate {
                            Marker("行走中", coordinate: coordinate)
                                .tint(.green)
                        }
                    } else if let coordinate {
                        Marker("定点", coordinate: coordinate)
                            .tint(.red)
                    }
                }
                // 平面地图，避免 3D 真实地形渲染在长时间会话中持续吃 GPU/CPU 发热。
                .mapStyle(.standard(elevation: .flat))
                .onTapGesture { point in
                    guard !isDrawingRoute else { return }
                    guard let loc = proxy.convert(point, from: .local) else { return }
                    if hasWaypointContext {
                        guard !walkingSession.isActive else { return }
                        waypointPlanner.append(loc)
                        Haptic.light()
                    } else {
                        applySelection(loc)
                    }
                }
                .mapControls {
                    MapCompass()
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            guard isDrawingRoute,
                                  let coordinate = proxy.convert(value.location, from: .local) else { return }
                            _ = FreehandPathBuilder.append(coordinate, to: &freehandCoordinates)
                        }
                        .onEnded { _ in
                            guard isDrawingRoute else { return }
                            finishFreehandRoute()
                        },
                    isEnabled: isDrawingRoute
                )
            }
                .ignoresSafeArea()
                .onChange(of: coordinate.map(CoordinateSnapshot.init)) { _, new in
                    if let new {
                        position = .region(
                            MKCoordinateRegion(
                                center: new.coordinate,
                                latitudinalMeters: 1000,
                                longitudinalMeters: 1000
                            )
                        )
                    }
                }

            VStack(spacing: 0) {
                if isDrawingRoute {
                    drawingBanner
                } else {
                    searchBar
                }

                if !isDrawingRoute, !searchCompleter.results.isEmpty {
                    searchResultsList
                }

                Spacer()

                VStack(spacing: 12) {
                    if isImportingCoordinates {
                        ProgressView("正在导入坐标…")
                            .font(.footnote)
                    }

                    if selectedMode == .route {
                        waypointControls
                    } else {
                        pinControls
                    }
                }
                .pikminControlCard()
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .padding(.top, 122)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        openLibrary(.recents)
                    } label: {
                        Label("位置资料库", systemImage: "books.vertical.fill")
                    }
                    Divider()
                    Button {
                        showCoordinateImporter = true
                    } label: {
                        Label("导入坐标或轨迹", systemImage: "square.and.arrow.down")
                    }
                    .disabled(isBusy || isRouteRunning || isImportingCoordinates)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel("位置与路线菜单")
            }
        }
        .onChange(of: selectedMode) { _, mode in
            if mode != .route {
                cancelFreehandRoute()
            }
            if mode == .fixedLocation {
                searchCompleter.update(query: searchText)
            } else if mode == .route {
                searchCompleter.results = []
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("好", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .alert("收藏地点", isPresented: $showSaveBookmark) {
            TextField("名称", text: $newBookmarkName)
            Button("保存") { addBookmark() }
            Button("取消", role: .cancel) { newBookmarkName = "" }
        } message: {
            Text("给这个位置起个名字，方便下次直接选用。")
        }
        .sheet(isPresented: $showLocationLibrary) {
            LocationLibraryView(
                selectedSection: $librarySection,
                bookmarks: $bookmarks,
                recents: $recentLocations,
                routes: $savedRoutes
            ) { bookmark in
                guard !walkingSession.isActive else { return }
                selectedMode = .fixedLocation
                applySelection(bookmark.coordinate, name: bookmark.name)
            } onSelectRecent: { recent in
                guard !walkingSession.isActive else { return }
                selectedMode = .fixedLocation
                applySelection(recent.coordinate, name: recent.name)
            } onSelectRoute: { route in
                loadRoute(route)
            }
        }
        .alert("保存路径", isPresented: $showSaveRoute) {
            TextField("名称，例如「公园一圈」", text: $newRouteName)
            Button("保存") { saveCurrentRoute() }
            Button("取消", role: .cancel) { newRouteName = "" }
        } message: {
            Text("保存后可以随时载入，不用重新点一遍。")
        }
        .sheet(isPresented: $showCoordinateEntry) {
            CoordinateEntrySheet(initialText: coordinateEntryText) { coordinate, shouldTeleport in
                applyEnteredCoordinate(coordinate, teleport: shouldTeleport)
            }
        }
        .fileImporter(
            isPresented: $showCoordinateImporter,
            allowedContentTypes: CoordinateImportParser.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            importCoordinates(result)
        }
        .fileExporter(
            isPresented: $showGPXExporter,
            document: gpxDocument,
            contentType: .gpx,
            defaultFilename: gpxFilename
        ) { result in
            switch result {
            case .success:
                Haptic.success()
            case .failure(let error):
                let cocoaError = error as NSError
                guard cocoaError.code != NSUserCancelledError else { return }
                alertTitle = "导出失败".localized
                alertMessage = error.localizedDescription
                showAlert = true
            }
        }
        .onAppear {
            loadBookmarks()
            savedRoutes = SavedWalkingRouteStore.load()
            recentLocations = RecentLocationStore.load()
        }
        .onDisappear {
            stopResendLoop()
            if backgroundTaskID != .invalid {
                BackgroundLocationManager.shared.requestStop()
            }
            endBackgroundTask()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索地点或输入经纬度", text: $searchText)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onChange(of: searchText) { _, newValue in
                    searchCompleter.update(query: newValue)
                }
                .onSubmit {
                    applyCoordinatesFromSearchText()
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchCompleter.update(query: "")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }

            Button {
                coordinateEntryText = coordinate.map {
                    String(format: "%.6f, %.6f", $0.latitude, $0.longitude)
                } ?? ""
                showCoordinateEntry = true
            } label: {
                Image(systemName: "numbers.rectangle")
                    .foregroundStyle(PikminUI.deepGreen)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("输入经纬度")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.1), radius: 12, y: 6)
        .padding(.horizontal, 16)
    }

    private var drawingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.and.outline")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("正在手绘路线")
                    .font(.subheadline.weight(.semibold))
                Text("按住地图拖动，松手完成")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消", role: .cancel, action: cancelFreehandRoute)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 6)
        .padding(.horizontal, 16)
    }

    // MARK: - Bookmarks

    private func loadBookmarks() {
        bookmarks = LocationBookmarkStore.load()
    }

    private func saveBookmarks() {
        LocationBookmarkStore.save(bookmarks)
    }

    private func addBookmark() {
        guard let coord = coordinate else { return }
        let name = newBookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = LocationBookmark(
            name: name.isEmpty ? String(format: "%.4f, %.4f", coord.latitude, coord.longitude) : name,
            latitude: coord.latitude,
            longitude: coord.longitude
        )
        bookmarks.append(bookmark)
        saveBookmarks()
        newBookmarkName = ""
    }

    // MARK: - Location

    private func selectSearchResult(_ result: MKLocalSearchCompletion) {
        searchText = ""
        searchCompleter.results = []

        let request = MKLocalSearch.Request(completion: result)
        MKLocalSearch(request: request).start { response, _ in
            if let item = response?.mapItems.first {
                if selectedMode == .route {
                    waypointPlanner.append(item.placemark.coordinate)
                    position = .region(
                        MKCoordinateRegion(
                            center: item.placemark.coordinate,
                            latitudinalMeters: 1_000,
                            longitudinalMeters: 1_000
                        )
                    )
                    Haptic.light()
                } else {
                    applySelection(item.placemark.coordinate, name: result.title)
                }
            }
        }
    }

    private func applyCoordinatesFromSearchText() {
        let importedCoordinates = CoordinateImportParser.parseInline(searchText)
        guard !importedCoordinates.isEmpty else {
            // 之前解析失败时什么都不做，用户只会觉得「按了没反应」。
            // 只要输入里带数字，就说明用户是想输坐标，给出明确提示。
            if searchText.rangeOfCharacter(from: .decimalDigits) != nil {
                alertTitle = "无法识别坐标".localized
                alertMessage = "请输入形如 35.681236, 139.767125 的经纬度，或点「输入经纬度」按钮。".localized
                showAlert = true
            }
            return
        }

        searchText = ""
        searchCompleter.results = []
        applyImportedCoordinates(importedCoordinates, sourceName: "手动输入".localized)
    }

    /// 应用手动输入的经纬度：切到定点、落点、移动地图，并可选直接传送。
    private func applyEnteredCoordinate(_ coordinate: CLLocationCoordinate2D, teleport: Bool) {
        guard !isRouteRunning else { return }
        selectedMode = .fixedLocation
        self.coordinate = coordinate
        selectedLocationName = "手动坐标".localized
        position = .region(
            MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 800,
                longitudinalMeters: 800
            )
        )
        Haptic.success()
        if teleport {
            simulate(at: coordinate)
        }
    }

    private func importCoordinates(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let sourceName = url.deletingPathExtension().lastPathComponent
            isImportingCoordinates = true

            Task {
                do {
                    let coordinates = try await Task.detached(priority: .userInitiated) {
                        try CoordinateImportParser.parse(url: url)
                    }.value

                    await MainActor.run {
                        isImportingCoordinates = false
                        applyImportedCoordinates(
                            coordinates,
                            sourceName: sourceName.isEmpty ? "导入轨迹".localized : sourceName
                        )
                    }
                } catch {
                    await MainActor.run {
                        isImportingCoordinates = false
                        showImportError(error)
                    }
                }
            }
        case .failure(let error):
            showImportError(error)
        }
    }

    private func applyImportedCoordinates(
        _ importedCoordinates: [CLLocationCoordinate2D],
        sourceName: String
    ) {
        guard !isRouteRunning else { return }

        let coordinates = importedCoordinates.filter(CLLocationCoordinate2DIsValid)
        guard let firstCoordinate = coordinates.first else {
            showImportError(CoordinateImportError.noCoordinates)
            return
        }

        if coordinates.count == 1 {
            selectedMode = .fixedLocation
            applySelection(firstCoordinate, name: sourceName)
            return
        }

        // 导入的轨迹本身就是路径，交给连点路线统一渲染和行走。
        let displayCoordinates = sampledRouteCoordinates(
            from: coordinates,
            targetDistance: RouteSimulationDefaults.pathSamplingDistance
        )
        guard waypointPlanner.loadImportedPath(displayCoordinates, name: sourceName) else {
            selectedMode = .fixedLocation
            applySelection(firstCoordinate)
            return
        }

        coordinate = nil
        selectedMode = .route
        if let rect = waypointPlanner.boundingMapRect {
            position = .rect(rect)
        }
        Haptic.success()
    }

    private func showImportError(_ error: Error) {
        alertTitle = "导入失败".localized
        alertMessage = error.localizedDescription
        showAlert = true
    }

    @ViewBuilder
    private var pinControls: some View {
        if let coord = coordinate {
            Text(String(format: "%.6f, %.6f", coord.latitude, coord.longitude))
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("恢复真实定位", action: clear)
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(!pairingExists || isBusy)

                Button("传送到此处", action: simulate)
                    .buttonStyle(.borderedProminent)
                    .disabled(!pairingExists || isBusy)

                Button {
                    showSaveBookmark = true
                } label: {
                    Image(systemName: "bookmark")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .disabled(isRouteRunning)
                .accessibilityLabel("收藏这个地点")
            }

            coordinateEntryButton

            if simulatedCoordinate != nil {
                Label(
                    String(format: "定点模拟中，位置每 %@ 秒重发一次".localized, Self.fixedResendInterval.formatted()),
                    systemImage: "location.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            }

            if !pairingExists {
                Label("尚未导入 pairing file，请先在设置页完成配对", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        } else {
            Text("点击地图选择一个位置，或直接输入经纬度")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            coordinateEntryButton
        }
    }

    /// 经纬度直传入口。放在底部卡片里，而不是只藏在顶部那个狭窄的搜索框中。
    private var coordinateEntryButton: some View {
        Button {
            coordinateEntryText = coordinate.map { String(format: "%.6f, %.6f", $0.latitude, $0.longitude) } ?? ""
            showCoordinateEntry = true
        } label: {
            Label("输入经纬度", systemImage: "numbers.rectangle")
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var waypointControls: some View {
        VStack(spacing: 10) {
            if !walkingSession.isActive, !waypointPlanner.isImported {
                Picker("路线规划", selection: $waypointPlanner.planningStyle) {
                    ForEach(RoutePlanningStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Text(waypointPlanner.planningStyle.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if isDrawingRoute {
                Label(
                    freehandCoordinates.isEmpty
                        ? "从路线起点开始拖动".localized
                        : String(format: "已采集 %d 个轨迹点".localized, freehandCoordinates.count),
                    systemImage: "hand.draw.fill"
                )
                .font(.footnote.weight(.medium))
                .foregroundStyle(.orange)
            }

            Text(waypointStatusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if waypointPlanner.isPlanning {
                ProgressView()
                    .controlSize(.small)
            } else if let waypointSummaryText {
                Text(waypointSummaryText)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            if !walkingSession.isActive {
                if waypointPlanner.isEmpty {
                    HStack {
                        Button {
                            beginFreehandRoute()
                        } label: {
                            Label("手绘路线", systemImage: "hand.draw")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(isDrawingRoute)

                        Button {
                            openLibrary(.routes)
                        } label: {
                            Label("载入路线", systemImage: "list.bullet.rectangle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(savedRoutes.isEmpty || isDrawingRoute)
                    }
                } else {
                    Toggle(isOn: $waypointPlanner.isLoop) {
                        Text(waypointPlanner.canLoop ? "闭环：终点连回起点，循环绕圈" : "闭环：至少需要 3 个点")
                            .font(.footnote)
                    }
                    .tint(.green)
                    .disabled(!waypointPlanner.canLoop)
                    .accessibilityHint("打开后走完一圈会自动继续，而不是原路折返")
                }

                HStack {
                    Picker("目标", selection: $routeGoalKind) {
                        ForEach(SessionGoalKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    if routeGoalKind != .manual {
                        TextField(goalPlaceholder, value: $routeGoalValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.decimalPad)
                            .frame(maxWidth: 100)
                    }
                }

                if !waypointPlanner.isEmpty {
                    HStack(spacing: 12) {
                        // 导入轨迹是整条载入的，逐点撤销没有意义，只能整条清空。
                        if !waypointPlanner.isImported {
                            Button {
                                waypointPlanner.removeLast()
                                Haptic.light()
                            } label: {
                                Label("撤销", systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(.bordered)
                        }

                        Button {
                            showSaveRoute = true
                        } label: {
                            Label("保存", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .disabled(waypointPlanner.waypoints.count < 2)

                        Button(action: exportCurrentRoute) {
                            Label("GPX", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!waypointPlanner.isReady)

                        Button(role: .destructive) {
                            waypointPlanner.clear()
                            Haptic.light()
                        } label: {
                            Label("清空", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.footnote)
                }
            }

            HStack(spacing: 12) {
                Button("停止") {
                    Task { await walkingSession.stop() }
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!walkingSession.isActive)

                Button(profile.startActionTitle, action: startWaypointWalk)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(
                        !pairingExists ||
                        !preflight.canStartSession ||
                        walkingSession.isActive ||
                        isBusy ||
                        !waypointPlanner.isReady
                    )

                Button("恢复真实定位", action: restoreRealLocation)
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
            }

            if let startBlockReason {
                Label(startBlockReason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if walkingSession.isActive {
                Text(String(format: "%1$d 步 · %2$.2f km".localized, walkingSession.estimatedSteps, walkingSession.distanceMeters / 1000))
                    .font(.caption.monospacedDigit())
            }
        }
    }

    /// 「开始行走」变灰时告诉用户卡在哪一步，而不是让按钮默默不可点。
    private var startBlockReason: String? {
        guard !walkingSession.isActive, !waypointPlanner.isEmpty else { return nil }
        if !pairingExists {
            return "尚未导入 pairing file，请先在设置页完成配对".localized
        }
        if !preflight.canStartSession {
            return "运行环境检查未通过，请先在设置页处理异常项".localized
        }
        return nil
    }

    private func startWaypointWalk() {
        guard pairingExists, !isBusy else { return }
        let coordinates = waypointPlanner.playbackCoordinates
        guard let firstCoordinate = coordinates.first, coordinates.count > 1 else { return }

        stopResendLoop()
        if let rect = waypointPlanner.boundingMapRect {
            position = .rect(rect)
        }

        let normalizedGoal: Double
        switch routeGoalKind {
        case .steps, .manual: normalizedGoal = routeGoalValue
        case .distance: normalizedGoal = routeGoalValue * 1000
        case .duration: normalizedGoal = routeGoalValue * 60
        }
        let movement = MovementParameters.current()
        let config = WalkingSessionConfig(
            mode: .route,
            goalKind: routeGoalKind,
            goalValue: normalizedGoal,
            speedKilometersPerHour: movement.speedKPH,
            strideMeters: movement.strideMeters,
            usesNaturalSpeedVariation: movement.usesNaturalSpeedVariation,
            startLatitude: firstCoordinate.latitude,
            startLongitude: firstCoordinate.longitude
        )
        Haptic.success()
        Task {
            await walkingSession.startRoute(
                config: config,
                coordinates: coordinates,
                isLoop: waypointPlanner.isClosedLoop
            )
        }
    }

    // MARK: - 已保存的路径

    private func saveCurrentRoute() {
        let preservesExactPath = waypointPlanner.isImported
        let coordinates = preservesExactPath
            ? waypointPlanner.sourceCoordinates
            : waypointPlanner.waypoints.map(\.coordinate)
        guard coordinates.count >= 2 else { return }
        let trimmed = newRouteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let route = SavedWalkingRoute(
            name: trimmed.isEmpty ? String(format: "路径 %d".localized, savedRoutes.count + 1) : trimmed,
            coordinates: coordinates,
            isLoop: waypointPlanner.isLoop,
            planningStyle: waypointPlanner.planningStyle,
            preservesExactPath: preservesExactPath
        )
        savedRoutes.append(route)
        SavedWalkingRouteStore.save(savedRoutes)
        newRouteName = ""
        Haptic.success()
    }

    private func exportCurrentRoute() {
        let coordinates = waypointPlanner.playbackCoordinates
        guard coordinates.count > 1 else { return }
        let fallback = String(format: "Pikmin 路线 %@".localized, Date().formatted(date: .abbreviated, time: .omitted))
        let enteredName = newRouteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = waypointPlanner.importedName ?? (enteredName.isEmpty ? fallback : enteredName)
        gpxDocument = GPXRouteDocument(name: name, coordinates: coordinates)
        gpxFilename = GPXRouteDocument.suggestedFilename(for: name)
        showGPXExporter = true
    }

    private func beginFreehandRoute() {
        guard !walkingSession.isActive else { return }
        waypointPlanner.clear()
        freehandCoordinates = []
        searchText = ""
        searchCompleter.update(query: "")
        isDrawingRoute = true
        Haptic.light()
    }

    private func finishFreehandRoute() {
        let coordinates = FreehandPathBuilder.finalized(freehandCoordinates)
        guard coordinates.count > 1 else {
            cancelFreehandRoute()
            return
        }
        _ = waypointPlanner.loadImportedPath(coordinates, name: "手绘路线".localized)
        freehandCoordinates = []
        isDrawingRoute = false
        if let rect = waypointPlanner.boundingMapRect {
            position = .rect(rect)
        }
        Haptic.success()
    }

    private func cancelFreehandRoute() {
        guard isDrawingRoute || !freehandCoordinates.isEmpty else { return }
        isDrawingRoute = false
        freehandCoordinates = []
        Haptic.light()
    }

    private func loadRoute(_ route: SavedWalkingRoute) {
        guard !walkingSession.isActive else { return }
        selectedMode = .route
        if route.preservesExactPath {
            _ = waypointPlanner.loadImportedPath(route.coordinates, name: route.name)
            waypointPlanner.isLoop = route.isLoop
        } else {
            waypointPlanner.replaceAll(
                with: route.coordinates,
                isLoop: route.isLoop,
                planningStyle: route.planningStyle
            )
        }
        if let rect = waypointPlanner.waypointsBoundingMapRect {
            position = .rect(rect)
        }
        Haptic.success()
    }

    private func openLibrary(_ section: LocationLibrarySection) {
        librarySection = section
        bookmarks = LocationBookmarkStore.load()
        recentLocations = RecentLocationStore.load()
        savedRoutes = SavedWalkingRouteStore.load()
        showLocationLibrary = true
    }

    private func simulate() {
        guard let coord = coordinate else { return }
        simulate(at: coord)
    }

    // 显式传坐标：手动输入经纬度时刚写完 @State 就要用，不依赖状态回读的时序。
    private func simulate(at coord: CLLocationCoordinate2D) {
        guard pairingExists, !isBusy else { return }
        runLocationCommand(
            errorTitle: "定点失败".localized,
            errorMessage: { code in
                String(format: "无法模拟定位（错误 %d）。请确认设备已连接、隧道正常且 DDI 已挂载。".localized, code)
            },
            operation: { locationUpdateCode(for: coord) }
        ) {
            beginBackgroundTask()
            startResendLoop(with: coord)
            recentLocations = RecentLocationStore.record(coord, name: selectedLocationName)
            BackgroundLocationManager.shared.requestStart()
            Haptic.success()
        }
    }

    private func runLocationCommand(
        errorTitle: String,
        errorMessage: @escaping (Int32) -> String,
        operation: @escaping () -> Int32,
        onSuccess: @escaping () -> Void
    ) {
        isBusy = true
        LocationSimulationCommandQueue.shared.async {
            let code = operation()
            DispatchQueue.main.async {
                isBusy = false
                if code == 0 {
                    onSuccess()
                } else {
                    alertTitle = errorTitle
                    alertMessage = errorMessage(code)
                    showAlert = true
                }
            }
        }
    }

    /// 恢复真实定位。
    ///
    /// 必须先停掉 4 秒一次的重发定时器，否则清除刚生效就又被下一次重发顶回去，
    /// 用户会以为「恢复真实定位」根本没用。
    private func clear() {
        guard !isBusy else { return }
        stopResendLoop()
        let ip = deviceIP
        let path = pairingFilePath
        runLocationCommand(
            errorTitle: "恢复失败".localized,
            errorMessage: { code in
                String(format: "无法清除模拟定位（错误 %d）。请确认设备仍然连接后重试。".localized, code)
            },
            operation: { clear_simulated_location(ip, path) }
        ) {
            endBackgroundTask()
            BackgroundLocationManager.shared.requestStop()
            BackgroundAudioManager.shared.requestStop()
            Haptic.success()
        }
    }

    /// 路线模式下的「恢复真实定位」：先停会话，再走和定点一样的清除流程。
    private func restoreRealLocation() {
        stopResendLoop()
        Task {
            await walkingSession.restoreRealLocation()
            endBackgroundTask()
            if let error = walkingSession.lastError {
                alertTitle = "恢复失败".localized
                alertMessage = error
                showAlert = true
            } else {
                Haptic.success()
            }
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { endBackgroundTask() }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // 定点重发间隔：原来 4 秒，MHNow 等实时游戏容易判定「定位过期」。
    // 改成每秒一次（与行走会话同频），让静止定位持续刷新时间戳。
    private static let fixedResendInterval: TimeInterval = 1

    private func startResendLoop(with coordinate: CLLocationCoordinate2D) {
        simulatedCoordinate = coordinate
        resendTimer?.invalidate()
        resendTimer = Timer.scheduledTimer(withTimeInterval: Self.fixedResendInterval, repeats: true) { _ in
            guard let base = simulatedCoordinate else { return }
            // 每次在原点 ±1.5m 内加随机微抖：真实 GPS 即使静止也在这个量级漂移，
            // 逐字节完全不变的坐标更像「假信号」。抖动不累积，始终围绕选定点。
            let jitterEast = Double.random(in: -1.5...1.5)
            let jitterNorth = Double.random(in: -1.5...1.5)
            let jittered = MovementMath.offset(base, eastMeters: jitterEast, northMeters: jitterNorth)
            LocationSimulationCommandQueue.shared.async {
                _ = locationUpdateCode(for: jittered)
            }
        }
    }

    private func stopResendLoop() {
        resendTimer?.invalidate()
        resendTimer = nil
        simulatedCoordinate = nil
    }

    private func applySelection(_ coordinate: CLLocationCoordinate2D, name: String? = nil) {
        guard !isRouteRunning else { return }
        self.coordinate = coordinate
        selectedLocationName = name
    }

    private func locationUpdateCode(for coordinate: CLLocationCoordinate2D) -> Int32 {
        simulate_location(deviceIP, coordinate.latitude, coordinate.longitude, pairingFilePath)
    }

    private func routeColor(for leg: RouteLegPolyline) -> Color {
        switch leg.status {
        case .straightLine: .orange.opacity(0.82)
        case .road: PikminUI.green.opacity(0.86)
        case .walking: .blue.opacity(0.82)
        case .imported: .purple.opacity(0.82)
        case .planning: .gray.opacity(0.6)
        }
    }
}

/// 经纬度直传输入页。边输边校验，明确告诉用户识别成什么，不做静默失败。
private struct CoordinateEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    let onApply: (CLLocationCoordinate2D, Bool) -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(initialText: String, onApply: @escaping (CLLocationCoordinate2D, Bool) -> Void) {
        _text = State(initialValue: initialText)
        self.onApply = onApply
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsed: CLLocationCoordinate2D? {
        CoordinateImportParser.parseInline(text).first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("35.681236, 139.767125", text: $text, axis: .vertical)
                        .font(.body.monospaced())
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($isFocused)

                    Button {
                        if let clipboard = UIPasteboard.general.string {
                            text = clipboard
                        }
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("经纬度")
                } footer: {
                    if let parsed {
                        Label(
                            String(format: "识别为 纬度 %.6f · 经度 %.6f".localized, parsed.latitude, parsed.longitude),
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    } else if trimmed.isEmpty {
                        Text("支持「纬度, 经度」，逗号或空格分隔；负数表示南纬/西经。")
                    } else {
                        Label("无法识别，请输入形如 35.681236, 139.767125", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button {
                        guard let parsed else { return }
                        onApply(parsed, true)
                        dismiss()
                    } label: {
                        Label("传送到此处", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PikminUI.green)
                    .disabled(parsed == nil)

                    Button {
                        guard let parsed else { return }
                        onApply(parsed, false)
                        dismiss()
                    } label: {
                        Label("只放置定点，不传送", systemImage: "mappin.and.ellipse")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(parsed == nil)
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("输入经纬度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { isFocused = true }
        }
    }
}

/// 地图上的编号途经点，起点和终点用颜色区分。
private struct WaypointBadge: View {
    let number: Int
    let total: Int
    let isLoop: Bool

    private var fill: Color {
        if number == 1 { return .green }
        // 闭环没有真正的终点，不要把最后一个点标成红色。
        if number == total, total > 1, !isLoop { return .red }
        return .blue
    }

    var body: some View {
        Text("\(number)")
            .font(.caption.bold().monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(fill.gradient, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 3)
            .accessibilityLabel(String(format: "途经点 %d".localized, number))
    }
}
