import AuthenticationServices
import PhotosUI
import RecipeCore
import SwiftData
import SwiftUI
import UIKit

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
    @Environment(\.modelContext) private var modelContext
    @State private var client = RecipeImportClient()
    @State private var kind: ImportKind = .url
    @State private var urlText = ""
    @State private var pastedText = ""
    @State private var capturedImages: [UIImage] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var captureSheet: CaptureSheet?
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

                Section("Display preference") {
                    Picker("Units", selection: $preferredUnits) {
                        Text("As written").tag(UnitSystemPreference.source)
                        Text("Metric").tag(UnitSystemPreference.metric)
                        Text("Imperial").tag(UnitSystemPreference.imperial)
                    }
                    .pickerStyle(.segmented)
                    Text("The source quantities remain canonical. You can switch units or serving size at any time.")
                        .font(.footnote)
                        .foregroundStyle(RecipeTheme.secondaryInk)
                }

                if !auth.isAuthenticated {
                    Section("Sign in to import") {
                        Text("Sign in with Apple authenticates the private import proxy. Your recipes remain in your iCloud library.")
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
                            Text("Reading the recipe…")
                                .font(.headline)
                            Text("The chart is rendered only after the canonical recipe passes validation.")
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
                Text("The service first looks for structured recipe data, then falls back to cleaned recipe prose.")
                    .font(.footnote)
                    .foregroundStyle(RecipeTheme.secondaryInk)
            }
        case .text:
            Section("Recipe text") {
                TextEditor(text: $pastedText)
                    .frame(minHeight: 220)
                    .font(.body)
                    .accessibilityIdentifier("recipe-text")
                Text("Include both the ingredient list and the full method. Ambiguities will be preserved as warnings.")
                    .font(.footnote)
                    .foregroundStyle(RecipeTheme.secondaryInk)
            }
        case .images:
            Section("Cookbook pages") {
                HStack {
                    Button("Scan pages", systemImage: "doc.viewfinder") { captureSheet = .scanner }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("scan-pages")
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
                        Label("Choose photos", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("choose-photos")
                }
                if capturedImages.isEmpty {
                    Text("Scan or choose up to four pages. Photos are normalized on device and discarded after extraction.")
                        .font(.footnote)
                        .foregroundStyle(RecipeTheme.secondaryInk)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(Array(capturedImages.enumerated()), id: \.offset) { _, image in
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 90, height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    Text("\(capturedImages.count) page\(capturedImages.count == 1 ? "" : "s") ready")
                        .font(.footnote)
                        .foregroundStyle(RecipeTheme.secondaryInk)
                }
            }
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
}
