import SwiftUI

enum LocationLibrarySection: String, CaseIterable, Identifiable {
    case favorites
    case recents
    case routes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: "收藏".localized
        case .recents: "最近".localized
        case .routes: "路线".localized
        }
    }
}

struct LocationLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedSection: LocationLibrarySection
    @Binding var bookmarks: [LocationBookmark]
    @Binding var recents: [RecentLocation]
    @Binding var routes: [SavedWalkingRoute]
    let onSelectBookmark: (LocationBookmark) -> Void
    let onSelectRecent: (RecentLocation) -> Void
    let onSelectRoute: (SavedWalkingRoute) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("资料类型", selection: $selectedSection) {
                    ForEach(LocationLibrarySection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                content
            }
            .navigationTitle("位置资料库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                        .disabled(isCurrentSectionEmpty)
                }
            }
        }
        .tint(PikminUI.green)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .favorites:
            if bookmarks.isEmpty {
                emptyView(
                    title: "还没有收藏地点",
                    symbol: "bookmark.slash",
                    description: "在定点模式选好位置后，点击书签即可收藏。"
                )
            } else {
                List {
                    ForEach(bookmarks) { bookmark in
                        locationButton(
                            name: bookmark.name,
                            latitude: bookmark.latitude,
                            longitude: bookmark.longitude,
                            symbol: "bookmark.fill"
                        ) {
                            onSelectBookmark(bookmark)
                            dismiss()
                        }
                    }
                    .onDelete { offsets in
                        bookmarks.remove(atOffsets: offsets)
                        LocationBookmarkStore.save(bookmarks)
                    }
                }
            }
        case .recents:
            if recents.isEmpty {
                emptyView(
                    title: "还没有最近位置",
                    symbol: "clock.badge.questionmark",
                    description: "成功传送或开始移动后，位置会自动出现在这里。"
                )
            } else {
                List {
                    ForEach(recents) { recent in
                        Button {
                            onSelectRecent(recent)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                libraryIcon("clock.arrow.circlepath")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(recent.name).font(.subheadline.weight(.semibold))
                                    coordinateText(recent.latitude, recent.longitude)
                                }
                                Spacer()
                                Text(recent.lastUsedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        recents.remove(atOffsets: offsets)
                        RecentLocationStore.save(recents)
                    }
                }
            }
        case .routes:
            if routes.isEmpty {
                emptyView(
                    title: "还没有保存路线",
                    symbol: "map",
                    description: "规划、导入或手绘路线后，点击保存即可留到下次使用。"
                )
            } else {
                List {
                    ForEach(routes) { route in
                        Button {
                            onSelectRoute(route)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                libraryIcon(route.preservesExactPath ? "scribble.variable" : "figure.walk.motion")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(route.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    HStack(spacing: 6) {
                                        Text(String(format: "%d 个点".localized, route.points.count))
                                        if route.preservesExactPath { Text("原始轨迹".localized) }
                                        if route.isLoop { Text("闭环".localized) }
                                        Text(route.createdAt, format: .dateTime.year().month().day())
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                    .onDelete { offsets in
                        routes.remove(atOffsets: offsets)
                        SavedWalkingRouteStore.save(routes)
                    }
                }
            }
        }
    }

    private var isCurrentSectionEmpty: Bool {
        switch selectedSection {
        case .favorites: bookmarks.isEmpty
        case .recents: recents.isEmpty
        case .routes: routes.isEmpty
        }
    }

    private func emptyView(title: String, symbol: String, description: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(description))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func locationButton(
        name: String,
        latitude: Double,
        longitude: Double,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                libraryIcon(symbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.subheadline.weight(.semibold))
                    coordinateText(latitude, longitude)
                }
                Spacer()
            }
        }
    }

    private func libraryIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(PikminUI.deepGreen)
            .frame(width: 30, height: 30)
            .background(PikminUI.softGreen, in: Circle())
    }

    private func coordinateText(_ latitude: Double, _ longitude: Double) -> some View {
        Text(String(format: "%.5f, %.5f", latitude, longitude))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}
