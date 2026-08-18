import SwiftUI
import UIKit
import Vision
import VisionKit

struct DocumentScannerView: UIViewControllerRepresentable {
    let onCompletion: ([UIImage]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onCompletion: ([UIImage]) -> Void
        let onCancel: () -> Void

        init(onCompletion: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onCompletion = onCompletion
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<min(scan.pageCount, 4)).map { scan.imageOfPage(at: $0) }
            onCompletion(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onCancel()
        }
    }
}

@MainActor
enum CapturedImageProcessor {
    static func normalizedJPEGData(from images: [UIImage], maximumDimension: CGFloat = 2_048) -> [Data] {
        images.prefix(4).compactMap { image in
            let size = image.size
            let scale = min(1, maximumDimension / max(size.width, size.height))
            let outputSize = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
            let format = UIGraphicsImageRendererFormat()
            format.opaque = true
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
            let normalized = renderer.image { _ in
                UIColor.white.setFill()
                UIRectFill(CGRect(origin: .zero, size: outputSize))
                image.draw(in: CGRect(origin: .zero, size: outputSize))
            }
            return normalized.jpegData(compressionQuality: 0.82)
        }
    }
}

enum CookbookOCR {
    static func recognizeText(in imageData: [Data]) async -> String? {
        await Task.detached(priority: .utility) {
            var pages: [String] = []
            for data in imageData {
                guard let image = UIImage(data: data)?.cgImage else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: image)
                try? handler.perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                if !text.isEmpty { pages.append(text) }
            }
            return pages.isEmpty ? nil : pages.joined(separator: "\n\n--- Page ---\n\n")
        }.value
    }
}
