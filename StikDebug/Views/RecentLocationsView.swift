import SwiftUI

struct RecentLocationsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var locations: [RecentLocation]
    let onSelect: (RecentLocation) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if locations.isEmpty {
                    ContentUnavailableView(
                        "还没有最近位置",
                        systemImage: "clock.badge.questionmark",
                        description: Text("成功传送、开始摇杆或路线后，位置会自动保存在这里。")
                    )
                } else {
                    List {
                        ForEach(locations) { location in
                            Button {
                                onSelect(location)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(PikminUI.deepGreen)
                                        .frame(width: 28, height: 28)
                                        .background(PikminUI.softGreen, in: Circle())
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(location.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(String(
                                            format: "%.5f, %.5f",
                                            location.latitude,
                                            location.longitude
                                        ))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(location.lastUsedAt, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            locations.remove(atOffsets: offsets)
                            RecentLocationStore.save(locations)
                        }
                    }
                }
            }
            .navigationTitle("最近位置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                if !locations.isEmpty {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        EditButton()
                        Button("清空", role: .destructive) {
                            locations = []
                            RecentLocationStore.clear()
                        }
                    }
                }
            }
        }
        .tint(PikminUI.green)
    }
}
