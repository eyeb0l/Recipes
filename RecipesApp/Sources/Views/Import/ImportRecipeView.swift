import AuthenticationServices
import PhotosUI
import RecipeCore
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ImportRecipeView: View {
    private enum ImportKind: String, CaseIterable, Identifiable {
        case url = "URL"
        case text = "Paste text"
        case images = "Scan pages"
        var id: String { rawValue }
    }

    private enum CaptureSheet: String, Identifiable {
        case scanner
        var id: String { rawValue }
    }

    @Environment(AuthSession.self) private var auth
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.modelContext) private var modelContext
    @State private var client = RecipeImportClient()
    @State private var kind: ImportKind = .url
    @State private var urlText = ""
    @State private var pastedText = ""
    @State private var capturedImages: [UIImage] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var captureSheet: CaptureSheet?
    @State private var isFileImporterPresented = false
    @AppStorage(AppPreferenceKey.unitSystem) private var preferredUnits: UnitSystemPreference = .metric
    @State private var errorMessage: String?
    @State private var pageNotice: String?
    /// Reused when the same import is retried so the service can join in-flight work.
    @State private var attemptKey: String?
    @State private var ignoresNextPhotoChange = false

    /// The server needs this much pasted text before it will attempt an extraction.
    static let minimumPastedTextLength = 40
    static let maximumPageCount = 4

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    Picker("Source", selection: $kind) {
                        ForEach(ImportKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                sourceSection

                Section("Units") {
                    Picker("Units", selection: $preferredUnits) {
                        ForEach(UnitSystemPreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("The app keeps the original amounts. You can change display units or servings later. \(UnitSystemPreference.explanation)")
                        .font(.footnote)
                        .foregroundStyle(RecipeTheme.secondaryInk)
                }

                if !auth.isAuthenticated {
                    Section("Sign in to import") {
                        if case let .failed(message) = auth.state {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(RecipeTheme.warning)
                        }
                        Text("Sign in with Apple to import recipes. The app saves them to your recipe library.")
                            .font(.footnote)
                        SignInWithAppleButton(.continue) { _ in
                        } onCompletion: { result in
                            Task { await auth.handle(result: result) }
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 46)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(RecipeTheme.warning)
                    }
                }
                }
                .listRowBackground(RecipeTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(RecipeTheme.paper)
            .navigationTitle("Import recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Make timeline") { Task { await importRecipe() } }
                        .disabled(!canImport || client.state == .importing || !auth.isAuthenticated)
                        .accessibilityIdentifier("make-timeline")
                }
            }
            .overlay {
                if client.state == .importing {
                    ZStack {
                        RecipeTheme.paper.opacity(0.86).ignoresSafeArea()
                        VStack(spacing: 14) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(RecipeTheme.focus)
                            Text(progressTitle)
                                .font(RecipeTheme.display(.title3))
                            Text("The app checks the ingredients and steps before saving your recipe.")
                                .font(.footnote)
                                .foregroundStyle(RecipeTheme.secondaryInk)
                                .multilineTextAlignment(.center)
                        }
                        .padding(28)
                    }
                }
            }
            .sheet(item: $captureSheet) { sheet in
                switch sheet {
                case .scanner:
                    DocumentScannerView { images in
                        setCapturedImages(images, clearingPhotoSelection: true)
                        captureSheet = nil
                    } onCancel: {
                        captureSheet = nil
                    }
                    .ignoresSafeArea()
                }
            }
            .onChange(of: photoItems) { _, newItems in
                if ignoresNextPhotoChange {
                    // Clearing the picker after a scan or Files import must not wipe those pages.
                    ignoresNextPhotoChange = false
                    return
                }
                Task { await loadPhotoItems(newItems) }
            }
            .onChange(of: importFingerprint) { attemptKey = nil }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.pdf, .image],
                allowsMultipleSelection: true,
                onCompletion: loadFiles
            )
        }
        .editorialSurface()
    }

    @ViewBuilder
    private var sourceSection: some View {
        switch kind {
        case .url:
            Section("Recipe URL") {
                HStack(spacing: 10) {
                    TextField("https://example.com/recipe", text: $urlText)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit {
                            guard canImport, auth.isAuthenticated, client.state != .importing else { return }
                            Task { await importRecipe() }
                        }
                        .accessibilityIdentifier("recipe-url")
                    PasteButton(payloadType: String.self) { strings in
                        guard let pasted = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                        urlText = pasted
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                }
                Text("The importer reads recipe data from the page. If it can't find any, it reads the recipe text.")
                    .font(.footnote)
                    .foregroundStyle(RecipeTheme.secondaryInk)
            }
        case .text:
            Section("Recipe text") {
                TextEditor(text: $pastedText)
                    .frame(minHeight: 220)
                    .font(.body)
                    .accessibilityIdentifier("recipe-text")
                HStack(alignment: .firstTextBaseline) {
                    Text("Paste the ingredient list and full method. The app flags anything unclear for you to review.")
                        .font(.footnote)
                        .foregroundStyle(RecipeTheme.secondaryInk)
                    Spacer(minLength: 8)
                    PasteButton(payloadType: String.self) { strings in
                        guard let pasted = strings.first else { return }
                        pastedText = pasted
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                }
                if pastedTextIsTooShort {
                    Text("Add a little more: the recipe needs at least \(Self.minimumPastedTextLength) characters.")
                        .font(.footnote)
                        .foregroundStyle(RecipeTheme.warning)
                }
            }
        case .images:
            Section("Cookbook pages") {
                VStack(alignment: .leading, spacing: 14) {
                    pageCaptureActions
                    Divider()
                    if capturedImages.isEmpty {
                        pageImportPrivacyNote
                    } else {
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(Array(capturedImages.enumerated()), id: \.offset) { index, image in
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 90, height: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .overlay(alignment: .topTrailing) {
                                            Button("Remove page \(index + 1)", systemImage: "xmark.circle.fill") {
                                                removePage(at: index)
                                            }
                                            .labelStyle(.iconOnly)
                                            .font(.title3)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.55))
                                            .buttonStyle(.borderless)
                                            .padding(4)
                                        }
                                        .accessibilityLabel("Page \(index + 1)")
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        Label(
                            "\(capturedImages.count) page\(capturedImages.count == 1 ? "" : "s") ready",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(RecipeTheme.success)
                        if let pageNotice {
                            Text(pageNotice)
                                .font(.footnote)
                                .foregroundStyle(RecipeTheme.warning)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var pageCaptureActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                scanPagesAction
                choosePhotosAction
                chooseFilesAction
            }
        } else {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    scanPagesAction
                    choosePhotosAction
                }
                chooseFilesAction
            }
        }
    }

    private var scanPagesAction: some View {
        Button { captureSheet = .scanner } label: {
            PageImportActionLabel(
                title: "Scan pages",
                detail: "Use camera",
                systemImage: "doc.viewfinder",
                isCompact: !dynamicTypeSize.isAccessibilitySize
            )
        }
        .buttonStyle(.borderless)
        .accessibilityHint("Use the document camera")
        .accessibilityIdentifier("scan-pages")
    }

    private var choosePhotosAction: some View {
        let isCompact = !dynamicTypeSize.isAccessibilitySize
        return PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
            PageImportActionLabel(
                title: "Choose photos",
                detail: "Photo Library",
                systemImage: "photo.on.rectangle",
                isCompact: isCompact
            )
        }
        .buttonStyle(.borderless)
        .accessibilityHint("Choose up to four images from Photos")
        .accessibilityIdentifier("choose-photos")
    }

    private var chooseFilesAction: some View {
        Button { isFileImporterPresented = true } label: {
            PageImportActionLabel(
                title: "Choose from Files",
                detail: "PDF or image",
                systemImage: "folder",
                isCompact: false
            )
        }
        .buttonStyle(.borderless)
        .accessibilityHint("Choose up to four PDF pages or images")
        .accessibilityIdentifier("choose-files")
    }

    private var pageImportPrivacyNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.shield")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RecipeTheme.focusText)
                .frame(width: 18)
            Text("Up to four pages. Images are prepared on this device and discarded by the import service after extraction.")
                .font(.footnote)
                .foregroundStyle(RecipeTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canImport: Bool {
        switch kind {
        case .url: return Self.normalizedRecipeURL(from: urlText) != nil
        case .text: return pastedText.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minimumPastedTextLength
        case .images: return !capturedImages.isEmpty
        }
    }

    private var pastedTextIsTooShort: Bool {
        let count = pastedText.trimmingCharacters(in: .whitespacesAndNewlines).count
        return count > 0 && count < Self.minimumPastedTextLength
    }

    private var progressTitle: String {
        switch kind {
        case .url: "Reading the recipe page…"
        case .text: "Reading your recipe…"
        case .images: capturedImages.count == 1 ? "Reading your page…" : "Reading your pages…"
        }
    }

    /// Changes whenever the content to import changes, so a retry of the same content keeps its key.
    private var importFingerprint: String {
        let content = switch kind {
        case .url: "url:\(urlText)"
        case .text: "text:\(pastedText)"
        case .images: "images:\(capturedImages.map { ObjectIdentifier($0).hashValue })"
        }
        return "\(preferredUnits.rawValue)|\(content)"
    }

    /// Accepts pasted links with surrounding whitespace or without a scheme, such as "example.com/recipe".
    static func normalizedRecipeURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), host.contains(".")
        else { return nil }
        return url
    }

    private func setCapturedImages(_ images: [UIImage], clearingPhotoSelection: Bool) {
        capturedImages = Array(images.prefix(Self.maximumPageCount))
        pageNotice = images.count > Self.maximumPageCount
            ? "Only the first \(Self.maximumPageCount) pages will be read."
            : nil
        errorMessage = nil
        if clearingPhotoSelection, !photoItems.isEmpty {
            ignoresNextPhotoChange = true
            photoItems = []
        }
    }

    private func removePage(at index: Int) {
        guard capturedImages.indices.contains(index) else { return }
        capturedImages.remove(at: index)
        pageNotice = nil
        if !photoItems.isEmpty {
            ignoresNextPhotoChange = true
            photoItems = []
        }
    }

    private func importRecipe() async {
        errorMessage = nil
        do {
            let source: RecipeImportSource
            switch kind {
            case .url:
                guard let url = Self.normalizedRecipeURL(from: urlText) else { throw APIClientError.invalidSource }
                source = .url(url)
            case .text:
                source = .text(pastedText)
            case .images:
                let data = CapturedImageProcessor.normalizedJPEGData(from: capturedImages)
                let recognized = await CookbookOCR.recognizeText(in: data)
                source = .images(data, recognizedText: recognized)
            }
            let key = attemptKey ?? UUID().uuidString
            attemptKey = key
            let response = try await client.importRecipe(
                from: source,
                auth: auth,
                preferredUnits: preferredUnits,
                idempotencyKey: key
            )
            try save(response.recipe)
            attemptKey = nil
            router.selectedRecipeID = response.recipe.id
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(_ recipe: RecipeV1) throws {
        let descriptor = FetchDescriptor<RecipeRecord>()
        if let existing = try modelContext.fetch(descriptor).first(where: { $0.id == recipe.id }) {
            try existing.update(with: recipe)
        } else {
            modelContext.insert(try RecipeRecord(recipe: recipe))
        }
        try modelContext.save()
    }

    private func loadPhotoItems(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        var unreadable = 0
        for item in items.prefix(Self.maximumPageCount) {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                images.append(image)
            } else {
                unreadable += 1
            }
        }
        // A newer selection may have replaced this one while photos were loading.
        guard items == photoItems else { return }
        setCapturedImages(images, clearingPhotoSelection: false)
        if unreadable > 0 {
            errorMessage = unreadable == 1
                ? "One photo couldn't be opened. Try choosing it again or use a different photo."
                : "\(unreadable) photos couldn't be opened. Try choosing them again or use different photos."
        }
    }

    private func loadFiles(_ result: Result<[URL], Error>) {
        do {
            setCapturedImages(try CookbookFileImporter.images(from: result.get()), clearingPhotoSelection: true)
        } catch CocoaError.userCancelled {
            // Leaving the picker should not surface an error.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PageImportActionLabel: View {
    let title: String
    let detail: String
    let systemImage: String
    let isCompact: Bool

    var body: some View {
        Group {
            if isCompact {
                VStack(spacing: 7) {
                    PageImportActionIcon(systemImage: systemImage)
                    VStack(spacing: 1) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(RecipeTheme.secondaryInk)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 82, alignment: .center)
            } else {
                HStack(spacing: 11) {
                    PageImportActionIcon(systemImage: systemImage)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(RecipeTheme.secondaryInk)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(RecipeTheme.secondaryInk.opacity(0.72))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 13)
                .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .background(RecipeTheme.stage.opacity(0.58), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(RecipeTheme.gridSubtle, lineWidth: 1)
        }
    }
}

private struct PageImportActionIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(RecipeTheme.focusText)
            .frame(width: 32, height: 32)
            .background(RecipeTheme.focus.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}
