import SwiftUI

/// Full labels get a vertical arrangement when the available width cannot fit them.
struct AdaptiveActionStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder var content: Content

    var body: some View {
        if typeSize.isAccessibilitySize {
            vertical
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { content }
                    .fixedSize(horizontal: true, vertical: false)
                vertical
            }
        }
    }

    private var vertical: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AdaptiveControlGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var minimumWidth: CGFloat = 112
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: minimumWidth), spacing: 8)], spacing: 8) {
            content
        }
    }
}

extension View {
    func accessibleControl() -> some View {
        frame(minHeight: 44)
            .contentShape(Rectangle())
    }
    func adaptivePicker() -> some View { modifier(AdaptivePickerStyle()) }
}

private struct AdaptivePickerStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize { content.pickerStyle(.menu) }
        else { content.pickerStyle(.segmented) }
    }
}

/// Shrinks to content on normal screens and scrolls only when space runs out.
/// A fixed upper bound alone would make ViewThatFits fill the entire map height.
private struct HeightLimitedScrollView<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
                            if abs((contentHeight ?? 0) - height) > 0.5 { contentHeight = height }
                        }
                    }
                }
        }
        .frame(height: min(contentHeight ?? maximumHeight, maximumHeight))
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
    }
}

/// Geometry uses the actual window, so iPad split view follows the same narrow layout as iPhone.
struct MapWorkspace<MapContent: View, Tools: View, Options: View, Actions: View>: View {
    let title: LocalizedStringKey
    var showsPanel = true
    @ViewBuilder var map: MapContent
    @ViewBuilder var tools: Tools
    @ViewBuilder var options: Options
    @ViewBuilder var actions: Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: Bool?
    @State private var toolsHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760
                || (geometry.size.width >= 620 && geometry.size.height < 420)
            let sideWidth = min(380, geometry.size.width * 0.43)
            let isExpanded = expanded ?? wide
            let optionsHeight = max(80, min(300, geometry.size.height * 0.40))
            if wide {
                HStack(spacing: 0) {
                    mapArea
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(title).font(.headline)
                            actions
                            Divider()
                            options
                        }
                        .padding(18)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .frame(width: sideWidth)
                    .background(PikminUI.cardBackground)
                }
            } else {
                ZStack(alignment: .bottom) {
                    mapArea
                    if showsPanel {
                        // Reserve the measured search/banner height plus card insets and a 12-point gap.
                        HeightLimitedScrollView(maximumHeight: max(44, geometry.size.height - toolsHeight - 64)) {
                            panel(isExpanded: isExpanded, optionsHeight: optionsHeight)
                        }
                        .pikminControlCard()
                        .frame(maxWidth: 540)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                }
            }
        }
    }

    private func panel(isExpanded: Bool, optionsHeight: CGFloat) -> some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { expanded = !isExpanded }
            } label: {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "已展开" : "已收起")
            .accessibilityHint("展开或收起操作选项，主要操作始终保留")
            .accessibilityIdentifier("map.options.toggle")
            if isExpanded {
                HeightLimitedScrollView(maximumHeight: optionsHeight) { options }
            }
            actions
        }
    }

    private var mapArea: some View {
        ZStack(alignment: .top) {
            map
            tools
                .frame(maxWidth: 540)
                .background {
                    GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
                            if abs(toolsHeight - height) > 0.5 { toolsHeight = height }
                        }
                    }
                }
                .padding(.top, 10)
        }
    }
}

struct RouteActionBar: View {
    let startTitle: String
    let isActive: Bool
    let canStart: Bool
    let canRestore: Bool
    let start: () -> Void
    let stop: () -> Void
    let restore: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            if isActive {
                Button(action: stop) {
                    Label("停止行走", systemImage: "stop.fill")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(PikminUI.actionGreen)
            } else {
                Button(action: start) {
                    Label(startTitle, systemImage: "play.fill")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(PikminUI.actionGreen)
                .disabled(!canStart)
            }
            Button(role: .destructive, action: restore) {
                Text("恢复真实定位").frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(!canRestore)
        }
    }
}
