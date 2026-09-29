import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct NativeModelDocumentPicker: UIViewControllerRepresentable {
    let onResult: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // iOS can assign downloaded .tar.bz2 files different UTIs depending on
        // provider/version. Accept generic data + folders, plus extension-derived
        // types when available, then validate the actual filename/layout ourselves.
        var accepted: [UTType] = [.data, .folder, .item]
        for ext in ["bz2", "tbz2", "tar", "onnx"] {
            if let type = UTType(filenameExtension: ext), !accepted.contains(type) {
                accepted.insert(type, at: 0)
            }
        }

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: accepted,
            asCopy: true
        )
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onResult: (Result<URL, Error>) -> Void

        init(onResult: @escaping (Result<URL, Error>) -> Void) {
            self.onResult = onResult
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onResult(.failure(NSError(
                    domain: "G2NativeModelPicker",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No file was selected."]
                )))
                return
            }

            // Selection is intentionally permissive. ModelRegistry/NativeModelArchive
            // are the source of truth for supported archives and model layouts.
            onResult(.success(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
