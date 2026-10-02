import SwiftUI

/// Shared by setup and settings. Device identifiers are never rendered here.
struct WowDeviceAccessView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var pairing: OnDevicePairingManager

    init(model: LauncherModel) {
        self.model = model
        self.pairing = model.pairing
    }

    private var isChecking: Bool { model.accessStatusKey == "access.checking" }
    private var hasAccessError: Bool { model.accessStatusKey.hasPrefix("access.error.") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("access.title", tableName: "WowAccess")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            } icon: {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(Color.accentColor)
            }

            HStack(alignment: .top, spacing: 10) {
                if isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.isDeviceAccessVerified ? "checkmark.circle.fill" : (hasAccessError ? "exclamationmark.circle.fill" : "circle.dashed"))
                        .foregroundStyle(model.isDeviceAccessVerified ? Color.green : (hasAccessError ? .red : .secondary))
                        .accessibilityHidden(true)
                }
                Text(LocalizedStringKey(model.accessStatusKey), tableName: "WowAccess")
                    .font(.subheadline)
            }
            .accessibilityElement(children: .combine)

            Text("access.help", tableName: "WowAccess")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Link(destination: URL(string: "https://wow-app.store")!) {
                Label {
                    Text("access.login", tableName: "WowAccess")
                } icon: { Image(systemName: "safari") }
            }
            .font(.subheadline)

            Button {
                model.verifyDeviceAccess()
            } label: {
                Text("access.verify", tableName: "WowAccess")
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy || pairing.isRunning)

            if let error = model.accessError,
               error != NSLocalizedString(model.accessStatusKey, tableName: "WowAccess", comment: "") {
                LauncherMessage(message: error, isError: true)
            }
            if let date = model.accessCheckedAt {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text("access.date", tableName: "WowAccess")
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("access.date", tableName: "WowAccess")
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            Text("access.privacy", tableName: "WowAccess")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
