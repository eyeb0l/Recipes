import SwiftUI

struct RecipeExportView: View {
    let request: RecipeExportRequest
    @Environment(\.dismiss) private var dismiss
    @State private var artifacts: [RecipeExportArtifact] = []
    @State private var errorMessage: String?
    @State private var isGenerating = true

    var body: some View {
        NavigationStack {
            Group {
                if isGenerating {
                    ProgressView("Preparing files…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Couldn’t export recipe", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again", action: generate)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    exportList
                }
            }
            .navigationTitle("Export recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .editorialSurface()
        .task { generate() }
    }

    private var exportList: some View {
        List {
            Section {
                ForEach(artifacts) { artifact in
                    ShareLink(item: artifact.url) {
                        HStack(spacing: 14) {
                            Image(systemName: artifact.format.systemImage)
                                .font(.title2)
                                .foregroundStyle(RecipeTheme.focus)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(artifact.format.title)
                                    .font(.headline)
                                Text(exportDescription(for: artifact.format))
                                    .font(.subheadline)
                                    .foregroundStyle(RecipeTheme.secondaryInk)
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(RecipeTheme.secondaryInk)
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("export-\(artifact.format.rawValue)")
                }
            } header: {
                Text(request.recipe.title)
            } footer: {
                Text(
                    "Each file uses the servings and units shown on the recipe. Choose a format, then save, print, or send it from the share sheet."
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(RecipeTheme.paper)
    }

    private func exportDescription(for format: RecipeExportFormat) -> String {
        switch format {
        case .pdf:
            "A PDF of your cooking timeline"
        case .xlsx:
            "A spreadsheet with the timeline and recipe details"
        case .png:
            "A PNG image of your cooking timeline"
        }
    }

    private func generate() {
        isGenerating = true
        errorMessage = nil
        do {
            artifacts = try RecipeExporter.exportAll(request)
            isGenerating = false
        } catch {
            artifacts = []
            errorMessage = error.localizedDescription
            isGenerating = false
        }
    }
}
