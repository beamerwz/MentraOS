import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct NativeModelDocumentPicker: UIViewControllerRepresentable {
    let onResult: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var types: [UTType] = [.data, .archive, .folder]
        if let bz2 = UTType(filenameExtension: "bz2") {
            types.append(bz2)
        }
        if let tbz2 = UTType(filenameExtension: "tbz2") {
            types.append(tbz2)
        }
        if let tar = UTType(filenameExtension: "tar") {
            types.append(tar)
        }

        // Open in-place. ModelRegistry already holds the security-scoped URL
        // while streaming/extracting, so a ~500 MB model is not copied twice.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: Array(Set(types)),
            asCopy: false
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
            onResult(.success(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
