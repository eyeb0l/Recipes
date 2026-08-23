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
    @State private var preferredUnits: UnitSystemPreference = .metric
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Source", selection: $kind) {
                        ForEach(ImportKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                sourceSection

                Section("Units") {
                    Picker("Units", selection: $preferredUnits) {
                        Text("As written").tag(UnitSystemPreference.source)
                        Text("Metric").tag(UnitSystemPreference.metric)
                        Text("Imperial").tag(UnitSystemPreference.imperial)
                    }
                    .pickerStyle(.segmented)
                    Text("The app keeps the original amounts. You can change display units or servings later.")
                        .font(.footnote)
                        .foregroundStyle(RecipeTheme.secondaryInk)
                }

                if !auth.isAuthenticated {
                    Section("Sign in to import") {
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
                            Text("Reading your recipe…")
                                .font(.headline)
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
                        capturedImages = images
                        captureSheet = nil
                    } onCancel: {
                        captureSheet = nil
                    }
                    .ignoresSafeArea()
                }
            }
            .onChange(of: photoItems) { _, newItems in
                Task { await loadPhotoItems(newItems) }
            }
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
                TextField("https://example.com/recipe", text: $urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("recipe-url")
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
                Text("Paste the ingredient list and full method. The app flags anything unclear for you to review.")
                    .font(.footnote)
                    .foregroundStyle(RecipeTheme.secondaryInk)
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
                                ForEach(Array(capturedImages.enumerated()), id: \.offset) { _, image in
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 90, height: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                        }
                        Label(
                            "\(capturedImages.count) page\(capturedImages.count == 1 ? "" : "s") ready",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(RecipeTheme.success)
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
        case .url:
            guard let scheme = URL(string: urlText)?.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        case .text: return pastedText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 30
        case .images: return !capturedImages.isEmpty
        }
    }

    private func importRecipe() async {
        errorMessage = nil
        do {
            let source: RecipeImportSource
            switch kind {
            case .url:
                guard let url = URL(string: urlText) else { throw APIClientError.invalidSource }
                source = .url(url)
            case .text:
                source = .text(pastedText)
            case .images:
                let data = CapturedImageProcessor.normalizedJPEGData(from: capturedImages)
                let recognized = await CookbookOCR.recognizeText(in: data)
                source = .images(data, recognizedText: recognized)
            }
            let response = try await client.importRecipe(from: source, auth: auth, preferredUnits: preferredUnits)
            try save(response.recipe)
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
        for item in items.prefix(4) {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                images.append(image)
            }
        }
        capturedImages = images
    }

    private func loadFiles(_ result: Result<[URL], Error>) {
        do {
            capturedImages = try CookbookFileImporter.images(from: result.get())
            photoItems = []
            errorMessage = nil
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
