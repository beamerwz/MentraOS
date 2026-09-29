import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct NativeModelDocumentPicker: UIViewControllerRepresentable {
    let onResult: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // iOS Files can classify .tar.bz2 inconsistently. .item deliberately allows
        // the downloaded archive to remain selectable; ModelRegistry validates it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onResult: (Result<URL, Error>) -> Void
        init(onResult: @escaping (Result<URL, Error>) -> Void) { self.onResult = onResult }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onResult(.failure(NSError(domain: "G2NativeModelPicker", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No file was selected."])))
                return
            }
            onResult(.success(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
