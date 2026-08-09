import SwiftData
import SwiftUI

struct SessionHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WalkingSessionRecord.startedAt, order: .reverse) private var records: [WalkingSessionRecord]

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ContentUnavailableView("暂无行走记录", systemImage: "leaf", description: Text("完成一次行走会话后会显示在这里。"))
                } else {
                    List {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(record.mode.title, systemImage: "figure.walk")
                                        .font(.headline)
                                    Spacer()
                                    Text(record.startedAt, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text(String(format: "%.2f km", record.distanceMeters / 1000))
                                    Text("·")
                                    Text(String(format: "%d 步".localized, record.estimatedSteps))
                                    Text("·")
                                    Text(Duration.seconds(record.durationSeconds).formatted(.time(pattern: .minuteSecond)))
                                }
                                .font(.subheadline)
                                Text(String(format: "健康写入 %1$d 步 · %2$@".localized, record.healthStepsWritten, record.terminationReason))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("历史")
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(records[index]) }
        try? modelContext.save()
    }
}
