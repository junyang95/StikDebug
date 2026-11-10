import CoreLocation
import SwiftUI
import UIKit

/// Shares the existing coordinate form with the batch route editor. Applying a
/// batch only previews the route; movement starts from the normal route controls.
struct CoordinateEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let speedKilometersPerHour: Double
    let prefersRoute: Bool
    let onApply: (CLLocationCoordinate2D, Bool) -> Void
    let onApplyRoute: ([CLLocationCoordinate2D]) -> Void

    @State private var text: String
    @State private var parsed: CoordinatePasteResult
    @FocusState private var isFocused: Bool

    init(
        initialText: String,
        speedKilometersPerHour: Double,
        prefersRoute: Bool = false,
        onApply: @escaping (CLLocationCoordinate2D, Bool) -> Void,
        onApplyRoute: @escaping ([CLLocationCoordinate2D]) -> Void
    ) {
        _text = State(initialValue: initialText)
        _parsed = State(initialValue: CoordinatePasteParser.parse(initialText))
        self.speedKilometersPerHour = speedKilometersPerHour
        self.prefersRoute = prefersRoute
        self.onApply = onApply
        self.onApplyRoute = onApplyRoute
    }

    private var inputText: Binding<String> {
        Binding(get: { text }, set: updateText)
    }

    private func updateText(_ value: String) {
        text = value
        parsed = CoordinatePasteParser.parse(value)
    }

    private var isRouteEntry: Bool { prefersRoute || parsed.nonemptyLineCount > 1 }

    private var estimatedDuration: String? {
        guard speedKilometersPerHour.isFinite, speedKilometersPerHour > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        let seconds = parsed.totalDistance / (speedKilometersPerHour / 3.6)
        return formatter.string(from: max(60, seconds))
    }

    var body: some View {
        NavigationStack {
            Form {
                inputSection

                if !parsed.issues.isEmpty || parsed.exceedsLimit {
                    validationSection
                }

                if isRouteEntry {
                    if parsed.canCreateRoute { routeSummary }
                    routeActions
                    if parsed.isValid { coordinatePreview }
                } else {
                    singleCoordinateActions
                }
            }
            .navigationTitle(isRouteEntry ? "批量粘贴坐标".localized : "输入经纬度".localized)
            .navigationBarTitleDisplayMode(.inline)
            .tint(PikminUI.green)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { isFocused = false }
                }
            }
            .onAppear { isFocused = text.isEmpty }
        }
    }

    private var inputSection: some View {
        Section {
            TextField("25.097467, 121.712822", text: inputText, axis: .vertical)
                .font(.body.monospaced())
                .lineLimit(isRouteEntry ? (typeSize.isAccessibilitySize ? 3...4 : 3...8) : 1...3)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isFocused)
                .accessibilityLabel("经纬度，每行一组")

            Button {
                if let clipboard = UIPasteboard.general.string {
                    updateText(clipboard)
                    isFocused = false
                }
            } label: {
                Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    .frame(minHeight: 44)
            }
        } header: {
            Text("经纬度")
        } footer: {
            if parsed.canApplyCoordinate, !isRouteEntry, let coordinate = parsed.coordinates.first {
                Label(
                    String(format: "识别为 纬度 %.6f · 经度 %.6f".localized,
                           coordinate.latitude, coordinate.longitude),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(PikminUI.green)
            } else {
                Text("每行一组「纬度, 经度」，也可用空格分隔；多个坐标会按粘贴顺序连接。")
            }
        }
    }

    private var validationSection: some View {
        Section {
            if let message = parsed.limitMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(parsed.issues) { issue in
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("请修正坐标")
        } footer: {
            Text("修正所有错误行后才能使用，避免遗漏途经点。")
        }
    }

    private var routeSummary: some View {
        Section {
            Label(String(format: "已识别 %d 个坐标".localized, parsed.coordinates.count),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(PikminUI.green)

            LabeledContent("路线距离") {
                Text(Measurement(value: parsed.totalDistance / 1000, unit: UnitLength.kilometers)
                    .formatted(.measurement(width: .abbreviated, usage: .road)))
                    .monospacedDigit()
            }
            LabeledContent("移动速度") {
                Text(String(format: "%.1f km/h", speedKilometersPerHour))
                    .monospacedDigit()
            }
            if let estimatedDuration {
                LabeledContent("预计时长") {
                    Text(estimatedDuration).monospacedDigit()
                }
            }
        } header: {
            Text("路线预览")
        } footer: {
            Text("从第一个点开始，按设定速度依次直线移动；默认到最后一个点停止并保持位置。")
        }
    }

    private var routeActions: some View {
        Section {
            Button {
                guard parsed.canCreateRoute else { return }
                onApplyRoute(parsed.coordinates)
                dismiss()
            } label: {
                Label("预览路线", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(PikminUI.actionGreen)
            .disabled(!parsed.canCreateRoute)
        } footer: {
            if parsed.isValid, !parsed.canCreateRoute {
                Text("路线至少需要两个不同的坐标。")
            } else {
                Text("确认地图上的路线后，再点击开始。")
            }
        }
        .listRowBackground(Color.clear)
    }

    private var coordinatePreview: some View {
        Section {
            ForEach(Array(parsed.coordinates.enumerated()), id: \.offset) { index, coordinate in
                Group {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) {
                            coordinateBadge(index + 1)
                            coordinateValue(coordinate.latitude)
                            coordinateValue(coordinate.longitude)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            coordinateBadge(index + 1)
                            Text(String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
                                .font(.body.monospaced())
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("移动顺序")
        }
    }

    private func coordinateBadge(_ number: Int) -> some View {
        Text(number.formatted())
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(PikminUI.deepGreen)
            .frame(minWidth: 28, minHeight: 28)
            .background(PikminUI.softGreen, in: Circle())
    }

    private func coordinateValue(_ value: Double) -> some View {
        Text(String(format: "%.6f", value))
            .font(.body.monospaced())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var singleCoordinateActions: some View {
        Section {
            Button {
                guard parsed.canApplyCoordinate, let coordinate = parsed.coordinates.first else { return }
                onApply(coordinate, true)
                dismiss()
            } label: {
                Label("传送到此处", systemImage: "location.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(PikminUI.actionGreen)
            .disabled(!parsed.canApplyCoordinate)

            Button {
                guard parsed.canApplyCoordinate, let coordinate = parsed.coordinates.first else { return }
                onApply(coordinate, false)
                dismiss()
            } label: {
                Label("只放置定点，不传送", systemImage: "mappin.and.ellipse")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!parsed.canApplyCoordinate)
        }
        .listRowBackground(Color.clear)
    }
}
