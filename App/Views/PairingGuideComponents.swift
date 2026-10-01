import SwiftUI

/// Checkmarks are used only for states reported by the app, never for manual
/// actions in Settings that the app cannot observe.
struct PairingReadinessRow: View {
    let title: Text
    let detail: Text
    let systemImage: String
    let isReady: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(isReady ? Color.green : Color.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                title.font(.subheadline.weight(.semibold))
                detail.font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if isReady {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
