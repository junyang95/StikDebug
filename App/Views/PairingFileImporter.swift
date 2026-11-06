import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One-time pairing import. UIKit supplies a copy in the app's temporary
/// storage; the completion must consume that copy synchronously.
@MainActor
struct PairingFileImporter: UIViewControllerRepresentable {
    enum Outcome {
        case selected(URL)
        case cancelled
        case failure(Error)
    }

    private enum PickerError: Error {
        case missingSelection
    }

    let onCompletion: (Outcome) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onCompletion = onCompletion
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onCompletion: (Outcome) -> Void
        private var completed = false

        init(onCompletion: @escaping (Outcome) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first, urls.count == 1 else {
                finish(.failure(PickerError.missingSelection))
                return
            }
            finish(.selected(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(.cancelled)
        }

        private func finish(_ outcome: Outcome) {
            guard !completed else { return }
            completed = true
            onCompletion(outcome)
        }
    }
}
