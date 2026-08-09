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


private enum RouteSimulationDefaults {
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

// MARK: - Bookmark Model

struct LocationBookmark: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
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

/// 地图点击的两种含义：连点画路线，或单点定位。
private enum MapTapMode: String, CaseIterable, Identifiable {
    case waypoints
    case pin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .waypoints: "路线"
        case .pin: "定点"
        }
    }
}

struct LocationSimulationView: View {
    @EnvironmentObject private var walkingSession: WalkingSessionController
    @EnvironmentObject private var preflight: EnvironmentPreflightService
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

    @State private var tapMode: MapTapMode = .waypoints
    @StateObject private var waypointPlanner = WaypointRoutePlanner()
    @State private var savedRoutes: [SavedWalkingRoute] = []
    @State private var showSavedRoutes = false
    @State private var showSaveRoute = false
    @State private var newRouteName = ""
    @State private var showCoordinateEntry = false
    @State private var coordinateEntryText = ""

    private static let routeDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    // Bookmarks
    @State private var bookmarks: [LocationBookmark] = []
    @State private var showBookmarks = false
    @State private var showSaveBookmark = false
    @State private var newBookmarkName = ""

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
        tapMode == .waypoints
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
                                    leg.isStraightLine ? .orange.opacity(0.8) : .blue.opacity(0.8),
                                    style: StrokeStyle(
                                        lineWidth: 5,
                                        lineCap: .round,
                                        dash: leg.isStraightLine ? [10, 8] : []
                                    )
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
                if !searchCompleter.results.isEmpty {
                    searchResultsList
                }

                Spacer()

                VStack(spacing: 12) {
                    if isImportingCoordinates {
                        ProgressView("正在导入坐标…")
                            .font(.footnote)
                    }

                    if !walkingSession.isActive {
                        Picker("地图点击模式", selection: $tapMode) {
                            ForEach(MapTapMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if tapMode == .waypoints {
                        waypointControls
                    } else {
                        pinControls
                    }
                }
                .pikminControlCard()
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    showBookmarks = true
                } label: {
                    Image(systemName: "bookmark.fill")
                }
                .accessibilityLabel("地点收藏")

                Button {
                    showSavedRoutes = true
                } label: {
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                }
                .disabled(isBusy || isRouteRunning)
                .accessibilityLabel("已保存的路径")

                Button {
                    showCoordinateImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(isBusy || isRouteRunning || isImportingCoordinates)
                .accessibilityLabel("导入坐标文件")
            }
            ToolbarItem(placement: .topBarTrailing) {
                TextField("搜索地点…", text: $searchText)
                    .padding(.leading, 6)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onChange(of: searchText) { _, newValue in
                        searchCompleter.update(query: newValue)
                    }
                    .onSubmit {
                        applyCoordinatesFromSearchText()
                    }
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
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(bookmarks: $bookmarks) { bookmark in
                applySelection(bookmark.coordinate)
                showBookmarks = false
            } onDelete: { offsets in
                bookmarks.remove(atOffsets: offsets)
                saveBookmarks()
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
        .sheet(isPresented: $showSavedRoutes) {
            SavedRoutesView(routes: $savedRoutes) { route in
                loadRoute(route)
                showSavedRoutes = false
            } onDelete: { offsets in
                savedRoutes.remove(atOffsets: offsets)
                SavedWalkingRouteStore.save(savedRoutes)
            }
        }
        .fileImporter(
            isPresented: $showCoordinateImporter,
            allowedContentTypes: CoordinateImportParser.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            importCoordinates(result)
        }
        .onAppear {
            loadBookmarks()
            savedRoutes = SavedWalkingRouteStore.load()
        }
        .onDisappear {
            stopResendLoop()
            if backgroundTaskID != .invalid {
                BackgroundLocationManager.shared.requestStop()
            }
            endBackgroundTask()
        }
    }

    // MARK: - Bookmarks

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: "locationBookmarks"),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: "locationBookmarks")
        }
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
                applySelection(item.placemark.coordinate)
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
        tapMode = .pin
        self.coordinate = coordinate
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
            tapMode = .pin
            applySelection(firstCoordinate)
            return
        }

        // 导入的轨迹本身就是路径，交给连点路线统一渲染和行走。
        let displayCoordinates = sampledRouteCoordinates(
            from: coordinates,
            targetDistance: RouteSimulationDefaults.pathSamplingDistance
        )
        guard waypointPlanner.loadImportedPath(displayCoordinates, name: sourceName) else {
            tapMode = .pin
            applySelection(firstCoordinate)
            return
        }

        coordinate = nil
        tapMode = .waypoints
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
                    Button {
                        showSavedRoutes = true
                    } label: {
                        Label("载入已保存的路径", systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(savedRoutes.isEmpty)
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
        let coordinates = waypointPlanner.waypoints.map(\.coordinate)
        guard coordinates.count >= 2 else { return }
        let trimmed = newRouteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let route = SavedWalkingRoute(
            name: trimmed.isEmpty ? String(format: "路径 %d".localized, savedRoutes.count + 1) : trimmed,
            coordinates: coordinates,
            isLoop: waypointPlanner.isLoop
        )
        savedRoutes.append(route)
        SavedWalkingRouteStore.save(savedRoutes)
        newRouteName = ""
        Haptic.success()
    }

    private func loadRoute(_ route: SavedWalkingRoute) {
        guard !walkingSession.isActive else { return }
        tapMode = .waypoints
        waypointPlanner.replaceAll(with: route.coordinates, isLoop: route.isLoop)
        if let rect = waypointPlanner.waypointsBoundingMapRect {
            position = .rect(rect)
        }
        Haptic.success()
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

    private func applySelection(_ coordinate: CLLocationCoordinate2D) {
        guard !isRouteRunning else { return }
        self.coordinate = coordinate
    }

    private func locationUpdateCode(for coordinate: CLLocationCoordinate2D) -> Int32 {
        simulate_location(deviceIP, coordinate.latitude, coordinate.longitude, pairingFilePath)
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

private struct SavedRoutesView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var routes: [SavedWalkingRoute]
    let onSelect: (SavedWalkingRoute) -> Void
    let onDelete: (IndexSet) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if routes.isEmpty {
                    ContentUnavailableView(
                        "还没有保存的路径",
                        systemImage: "map",
                        description: Text("在地图上点几个点连成路径后，点「保存」即可留到下次直接用。")
                    )
                } else {
                    List {
                        ForEach(routes) { route in
                            Button {
                                onSelect(route)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(route.name)
                                        .font(.body)
                                    HStack(spacing: 6) {
                                        Text(String(format: "%d 个点".localized, route.points.count))
                                        if route.isLoop {
                                            Label("闭环", systemImage: "arrow.triangle.capsulepath")
                                        }
                                        Text(route.createdAt, format: .dateTime.year().month().day())
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .tint(.primary)
                        }
                        .onDelete(perform: onDelete)
                    }
                }
            }
            .navigationTitle("已保存的路径")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
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


struct BookmarksView: View {
    @Binding var bookmarks: [LocationBookmark]
    let onSelect: (LocationBookmark) -> Void
    let onDelete: (IndexSet) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if bookmarks.isEmpty {
                    ContentUnavailableView(
                        "还没有收藏地点",
                        systemImage: "bookmark.slash",
                        description: Text("切换到「定点」，在地图上选好位置后点书签图标即可收藏。")
                    )
                } else {
                    List {
                        ForEach(bookmarks) { bookmark in
                            Button {
                                onSelect(bookmark)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.name)
                                        .foregroundStyle(.primary)
                                    Text(String(format: "%.6f, %.6f", bookmark.latitude, bookmark.longitude))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: onDelete)
                    }
                }
            }
            .navigationTitle("地点收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !bookmarks.isEmpty {
                    EditButton()
                }
            }
        }
    }
}
