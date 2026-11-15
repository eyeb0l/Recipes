import SwiftUI
import UIKit
import UniformTypeIdentifiers
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
            // Keep one page beyond the import limit so the form can say that extra pages were left out.
            let images = (0..<min(scan.pageCount, 5)).map { scan.imageOfPage(at: $0) }
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

enum CookbookFileImportError: LocalizedError {
    case noImportablePages
    case unreadableFile(String)
    case unsupportedFile(String)

    var errorDescription: String? {
        switch self {
        case .noImportablePages:
            "The selected files did not contain any importable pages."
        case let .unreadableFile(name):
            "The app could not read \(name)."
        case let .unsupportedFile(name):
            "\(name) is not a supported PDF or image."
        }
    }
}

@MainActor
enum CookbookFileImporter {
    static func images(
        from urls: [URL],
        maximumPageCount: Int = 4,
        maximumDimension: CGFloat = 2_048
    ) throws -> [UIImage] {
        guard maximumPageCount > 0 else { return [] }

        var imported: [UIImage] = []
        for url in urls where imported.count < maximumPageCount {
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            let extensionType = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .pdf) == true || extensionType?.conforms(to: .pdf) == true {
                let remaining = maximumPageCount - imported.count
                imported.append(contentsOf: try pdfImages(from: url, limit: remaining, maximumDimension: maximumDimension))
            } else if type?.conforms(to: .image) == true || extensionType?.conforms(to: .image) == true {
                guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                    throw CookbookFileImportError.unreadableFile(url.lastPathComponent)
                }
                imported.append(image)
            } else {
                throw CookbookFileImportError.unsupportedFile(url.lastPathComponent)
            }
        }

        guard !imported.isEmpty else { throw CookbookFileImportError.noImportablePages }
        return imported
    }

    private static func pdfImages(from url: URL, limit: Int, maximumDimension: CGFloat) throws -> [UIImage] {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else {
            throw CookbookFileImportError.unreadableFile(url.lastPathComponent)
        }

        return try (1...min(document.numberOfPages, limit)).map { pageNumber in
            guard let page = document.page(at: pageNumber) else {
                throw CookbookFileImportError.unreadableFile(url.lastPathComponent)
            }
            let bounds = page.getBoxRect(.mediaBox)
            guard bounds.width > 0, bounds.height > 0 else {
                throw CookbookFileImportError.unreadableFile(url.lastPathComponent)
            }

            let renderScale = maximumDimension / max(bounds.width, bounds.height)
            let outputSize = CGSize(
                width: max(1, (bounds.width * renderScale).rounded()),
                height: max(1, (bounds.height * renderScale).rounded())
            )
            let format = UIGraphicsImageRendererFormat()
            format.opaque = true
            format.scale = 1
            return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: outputSize))

                let graphicsContext = context.cgContext
                graphicsContext.saveGState()
                graphicsContext.translateBy(x: 0, y: outputSize.height)
                graphicsContext.scaleBy(x: 1, y: -1)
                graphicsContext.concatenate(
                    page.getDrawingTransform(
                        .mediaBox,
                        rect: CGRect(origin: .zero, size: outputSize),
                        rotate: 0,
                        preserveAspectRatio: true
                    )
                )
                graphicsContext.drawPDFPage(page)
                graphicsContext.restoreGState()
            }
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
