import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PairingSetupView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var vpn: LocalVPNManager
    @ObservedObject private var pairing: OnDevicePairingManager
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .largeTitle) private var pinSize = 42
    let openLaunch: () -> Void
    @State private var importingPairing = false
    @State private var importFeedback: ImportFeedback?
    @State private var copiedPIN = false
    @State private var prepareWhenConnected = false

    init(model: LauncherModel, openLaunch: @escaping () -> Void) {
        self.model = model
        self.vpn = model.vpn
        self.pairing = model.pairing
        self.openLaunch = openLaunch
    }

    private var hasRecord: Bool { model.pairingFileName != nil }
    private var operationInProgress: Bool { model.isBusy || vpn.isBusy || prepareWhenConnected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WowDeviceAccessView(model: model)
                    .padding(20)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                if model.isSetupAccessReady {
                statusHeader
                if !model.isWiFiAvailable {
                    Label(LocalizedStringKey(model.wifiStatusKey), systemImage: "wifi.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let code = pairing.pinCode { pinCard(code) }
                pairingMessages
                if pairing.isSupported {
                    pairingGuide
                } else {
                    computerPairingGuide
                }
                readiness
                if pairing.isSupported { manualPairing }
                Text("setup.reuse_hint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 680)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("app.name")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { if model.isSetupAccessReady { actionBar } }
        .sheet(isPresented: $importingPairing) {
            PairingFileImporter(onCompletion: handlePairingImport)
        }
        .onChange(of: pairing.pinCode) { _, _ in copiedPIN = false }
        .onChange(of: vpn.status) { _, status in
            guard model.connectionMode == .builtIn, prepareWhenConnected else { return }
            if status == .connected {
                prepareWhenConnected = false
                prepareIfReady()
            } else if (status == .disconnected || status == .invalid) && !vpn.isBusy {
                prepareWhenConnected = false
            }
        }
        .onChange(of: model.connectionMode) { _, _ in prepareWhenConnected = false }
        .onChange(of: model.isSetupAccessReady) { _, ready in
            if !ready { prepareWhenConnected = false; importingPairing = false }
        }
        .onChange(of: model.wifiState) { _, state in
            if !state.isAvailable { prepareWhenConnected = false }
        }
        .onDisappear { prepareWhenConnected = false }
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: pairing.errorMessage != nil ? "exclamationmark.circle" : hasRecord ? "checkmark.shield.fill" : pairing.isSupported ? "iphone.and.arrow.forward" : "desktopcomputer")
                    .font(.title)
                    .foregroundStyle(pairing.errorMessage != nil ? Color.orange : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    guideText(hasRecord && !pairing.isRunning ? "guide.title.paired" : pairing.isSupported ? "guide.title.pairing" : "guide.computer.title")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    guideText(hasRecord && !pairing.isRunning ? "guide.subtitle.paired" : pairing.isSupported ? "guide.subtitle.pairing" : "guide.computer.subtitle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if pairing.isRunning {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(LocalizedStringKey(pairing.statusKey))
                        .font(.subheadline.weight(.medium))
                }
            } else if !pairing.isSupported && !hasRecord {
                Label {
                    Text("pairing.on_device.unsupported")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .foregroundStyle(.secondary)
            } else if pairing.statusKey == "pairing.on_device.cancelled" {
                Text(LocalizedStringKey(pairing.statusKey))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pinCard(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            guideText("guide.pin.step")
                .font(.headline)
            Text(verbatim: code)
                .font(.system(size: pinSize, weight: .bold, design: .monospaced))
                .tracking(3)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityLabel(Text("pairing.on_device.pin_accessibility \(code.map(String.init).joined(separator: " "))"))
            Button {
                UIPasteboard.general.setItems(
                    [[UTType.utf8PlainText.identifier: code]],
                    options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
                )
                copiedPIN = true
            } label: {
                Label {
                    guideText(copiedPIN ? "guide.pin.copied" : "guide.pin.copy")
                } icon: {
                    Image(systemName: copiedPIN ? "checkmark" : "doc.on.doc")
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            Text("pairing.on_device.pin_hint")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder private var pairingMessages: some View {
        if let error = pairing.errorMessage {
            LauncherMessage(message: error, isError: true)
        }
        if let message = pairing.notificationMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "bell.badge")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    guideText("guide.permissions.open_app_settings")
                        .frame(minHeight: 44)
                }
                guideText("guide.permissions.settings_scope")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pairingGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            guideText("guide.steps.title")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                PairingGuideRow(number: 1) {
                    guideText("guide.steps.first")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(2...7, id: \.self) { number in
                    Divider().padding(.leading, 60)
                    PairingGuideRow(number: number) {
                        Text(LocalizedStringKey("pairing.guide.step" + String(number)))
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            guideText("guide.steps.note")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if hasRecord && pairing.isSupported {
                Button {
                    Task { await pairing.start() }
                } label: {
                    guideText("guide.pair_again")
                        .frame(minHeight: 44)
                }
                .disabled(operationInProgress || pairing.isRunning || !model.isWiFiAvailable)
            }
        }
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 12) {
            guideText("guide.readiness.title")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 16) {
                DeviceConnectionModePicker(model: model)
                    .disabled(prepareWhenConnected)
                Divider()
                PairingReadinessRow(
                    title: Text("wifi.title"),
                    detail: Text(LocalizedStringKey(model.wifiStatusKey)),
                    systemImage: "wifi", isReady: model.isWiFiAvailable
                )
                Divider()
                PairingReadinessRow(
                    title: guideText("guide.readiness.record"),
                    detail: guideText(hasRecord ? "guide.readiness.record.saved" : "guide.readiness.record.missing"),
                    systemImage: "doc.badge.gearshape", isReady: hasRecord
                )
                if let name = model.pairingFileName {
                    Text(verbatim: name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(.leading, 34)
                }
                Divider()
                PairingReadinessRow(
                    title: Text(LocalizedStringKey(model.connectionMode == .external ? "connection.mode.external" : "connection.mode.builtIn")),
                    detail: Text(LocalizedStringKey(model.connectionStatusKey)),
                    systemImage: "network.badge.shield.half.filled", isReady: model.isDeviceConnectionReady
                )
                if model.connectionMode == .external {
                    Text("connection.external.instructions")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("connection.external.verification_note")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    guideText("guide.readiness.vpn.note")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let message = vpn.errorMessage {
                        LauncherMessage(message: message, isError: true)
                    }
                }
                Divider()
                PairingReadinessRow(
                    title: guideText("guide.readiness.ddi"),
                    detail: guideText(model.isPrepared ? "guide.readiness.ddi.ready" : "guide.readiness.ddi.pending"),
                    systemImage: "externaldrive.badge.checkmark", isReady: model.isPrepared
                )
                if model.isBusy { PreparationProgress(model: model) }
                if let message = model.errorMessage {
                    LauncherMessage(message: message, isError: true)
                }
                guideText("guide.readiness.ddi.note")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if hasRecord {
                    Divider()
                    Toggle("setup.developer.confirm", isOn: $model.developerModeConfirmed)
                        .font(.subheadline)
                        .disabled(operationInProgress || pairing.isRunning)
                        .accessibilityHint("setup.developer.confirm_hint")
                    Text("setup.developer.instructions")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private var computerPairingGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            guideText("guide.computer.steps.title")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Link(destination: URL(string: "https://app-shop.cn/app/106")!) {
                Label {
                    guideText("guide.computer.download")
                } icon: {
                    Image(systemName: "arrow.up.right.square")
                }
                .frame(minHeight: 44)
            }
            guideText("guide.computer.download.note")
                .font(.footnote)
                .foregroundStyle(.secondary)
            importPairingButton
            VStack(spacing: 0) {
                ForEach(1...4, id: \.self) { number in
                    if number > 1 { Divider().padding(.leading, 60) }
                    PairingGuideRow(number: number) {
                        guideText("guide.computer.step" + String(number))
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            Text("pairing.create.remote_only")
                .font(.footnote)
                .foregroundStyle(.secondary)
            guideText("guide.import.copy_note")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("pairing.privacy")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var importPairingButton: some View {
        Button(action: presentPairingImporter) {
            Label(hasRecord ? "pairing.replace" : "pairing.import", systemImage: "square.and.arrow.down")
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(operationInProgress || pairing.isRunning)
    }

    private var manualPairing: some View {
        DisclosureGroup("pairing.manual.title") {
            computerPairingGuide.padding(.top, 12)
        }
        .font(.subheadline)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private struct ImportFeedback {
        let succeeded: Bool
        let message: String
    }

    private func presentPairingImporter() {
        guard model.isSetupAccessReady else { model.startSetup(); return }
        importFeedback = nil
        importingPairing = true
    }

    private func handlePairingImport(_ outcome: PairingFileImporter.Outcome) {
        switch outcome {
        case .selected(let url):
            // The system-provided copy is temporary. Read and persist it now,
            // while the delegate callback is active, before dismissing the picker.
            let succeeded = model.importPairingFile(from: url)
            importFeedback = ImportFeedback(
                succeeded: succeeded,
                message: succeeded
                    ? (model.successMessage ?? NSLocalizedString("success.pairing_imported", comment: ""))
                    : (model.errorMessage ?? NSLocalizedString("pairing.import_failed", comment: ""))
            )
            // The fixed action bar owns this feedback. Consume the model error
            // so the root's general alert cannot compete with picker dismissal.
            if !succeeded { model.clearMessages() }
        case .failure(let error):
            importFeedback = ImportFeedback(
                succeeded: false,
                message: model.reportPairingPickerFailure(error)
            )
            model.clearMessages()
        case .cancelled:
            break
        }
        importingPairing = false
    }

    private func importResult(_ feedback: ImportFeedback) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    if feedback.succeeded {
                        guideText("guide.import.success.title")
                    } else {
                        Text("pairing.import_failed")
                    }
                } icon: {
                    Image(systemName: feedback.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(feedback.succeeded ? Color.green : Color.red)
                }
                .font(.subheadline.weight(.semibold))
                Text(feedback.message)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("common.ok") { importFeedback = nil }
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(12)
        .background((feedback.succeeded ? Color.green : Color.red).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            // Keep import feedback visible at every scroll position. A second
            // modal alert can be lost while the document picker dismisses.
            if let feedback = importFeedback { importResult(feedback) }
            Button(action: primaryAction) {
                HStack(spacing: 8) {
                    if operationInProgress && !pairing.isRunning {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: primarySymbol)
                    }
                    primaryTitle
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .disabled(primaryDisabled)
            if pairing.isRunning {
                guideText("guide.action.waiting_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !model.isWiFiAvailable {
                Text(LocalizedStringKey(model.wifiStatusKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if hasRecord && !model.developerModeConfirmed {
                guideText("guide.action.confirm_developer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 680)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private var primaryTitle: Text {
        if pairing.isRunning { return Text("pairing.on_device.cancel") }
        if model.isBusy { return Text(LocalizedStringKey(model.progressKey)) }
        if vpn.isBusy || prepareWhenConnected { return guideText("guide.action.connecting") }
        if model.isPrepared && model.isDeviceConnectionReady { return guideText("guide.action.open_apps") }
        if hasRecord {
            return guideText(model.canAttemptDeviceConnection ? "guide.action.prepare" : "guide.action.connect_prepare")
        }
        return pairing.isSupported ? Text("pairing.on_device.start") : Text("pairing.import")
    }

    private var primarySymbol: String {
        if pairing.isRunning { return "stop.circle" }
        if model.isPrepared && model.isDeviceConnectionReady { return "square.grid.2x2" }
        if hasRecord { return "bolt.shield" }
        return pairing.isSupported ? "iphone.and.arrow.forward" : "square.and.arrow.down"
    }

    private var primaryDisabled: Bool {
        if pairing.isRunning { return false }
        return operationInProgress || (hasRecord && !model.developerModeConfirmed)
            || ((hasRecord || pairing.isSupported) && !model.isWiFiAvailable)
    }

    private func primaryAction() {
        guard model.isSetupAccessReady else { model.startSetup(); return }
        if pairing.isRunning { pairing.cancel(); return }
        guard !operationInProgress else { return }
        if hasRecord || pairing.isSupported { guard model.requireWiFi() else { return } }
        if model.isPrepared && model.isDeviceConnectionReady { openLaunch(); return }
        if hasRecord {
            if model.canAttemptDeviceConnection {
                prepareIfReady()
            } else if model.connectionMode == .builtIn {
                prepareWhenConnected = true
                Task {
                    await model.connectVPN()
                    guard model.connectionMode == .builtIn else {
                        prepareWhenConnected = false
                        return
                    }
                    if vpn.isConnected && prepareWhenConnected {
                        prepareWhenConnected = false
                        prepareIfReady()
                    } else if vpn.status != .connecting && vpn.status != .reasserting {
                        prepareWhenConnected = false
                    }
                }
            }
        } else if pairing.isSupported {
            Task { await pairing.start() }
        } else {
            presentPairingImporter()
        }
    }

    private func prepareIfReady() {
        guard model.isSetupAccessReady, hasRecord, model.isWiFiAvailable, model.developerModeConfirmed, model.canAttemptDeviceConnection,
              !model.isBusy, !pairing.isRunning else { return }
        model.prepareDevice()
    }

    private func guideText(_ key: String) -> Text {
        Text(LocalizedStringKey(key), tableName: "PairingGuide")
    }
}
