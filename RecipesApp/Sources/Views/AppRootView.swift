import RecipeCore
import SwiftData
import SwiftUI

struct AppRootView: View {
    let persistence: PersistenceController
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \RecipeRecord.updatedAt, order: .reverse) private var records: [RecipeRecord]

    var body: some View {
        @Bindable var router = router
        Group {
            if horizontalSizeClass == .compact {
                compactNavigation
            } else {
                splitNavigation
            }
        }
        .editorialSurface()
        .sheet(item: $router.presentedSheet) { sheet in
            switch sheet {
            case .importRecipe:
                ImportRecipeView()
            case .settings:
                SettingsView(persistence: persistence)
            }
        }
        .fullScreenCover(item: $router.activeCookSession) { route in
            CookModeHost(sessionID: route.id)
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("--ui-testing"), records.isEmpty else { return }
            try? modelContext.insert(RecipeRecord(recipe: SampleRecipe.espressoBrownies))
            try? modelContext.save()
        }
    }

    private var splitNavigation: some View {
        @Bindable var router = router
        return NavigationSplitView {
            RecipeLibraryList(records: records, selection: $router.selectedRecipeID)
                .navigationTitle("Recipes")
                .toolbar { libraryToolbar }
        } detail: {
            if let selected = selectedRecord {
                RecipeDetailView(record: selected)
            } else {
                EmptyLibraryDetail(onImport: { router.presentedSheet = .importRecipe })
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var compactNavigation: some View {
        NavigationStack {
            RecipeLibraryList(records: records, selection: nil)
                .navigationTitle("Recipes")
                .toolbar { libraryToolbar }
                .navigationDestination(for: String.self) { id in
                    if let record = records.first(where: { $0.id == id }) {
                        RecipeDetailView(record: record)
                    }
                }
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Import", systemImage: "plus") { router.presentedSheet = .importRecipe }
                .accessibilityIdentifier("import-recipe")
            Button("Settings", systemImage: "person.crop.circle") { router.presentedSheet = .settings }
        }
    }

    private var selectedRecord: RecipeRecord? {
        if let id = router.selectedRecipeID { return records.first { $0.id == id } }
        return records.first
    }
}

private struct RecipeLibraryList: View {
    let records: [RecipeRecord]
    let selection: Binding<String?>?
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView {
                    Label("Your cookbook is empty", systemImage: "book.closed")
                } description: {
                    Text("Import a URL, paste a recipe, scan a cookbook page, or add the bundled sample.")
                } actions: {
                    Button("Import recipe") { router.presentedSheet = .importRecipe }
                        .buttonStyle(.borderedProminent)
                    Button("Add sample") { addSample() }
                }
            } else if let selection {
                List(selection: selection) {
                    rows
                }
                .scrollContentBackground(.hidden)
            } else {
                List {
                    rows
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(RecipeTheme.paper)
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(records) { record in
            NavigationLink(value: record.id) {
                RecipeLibraryRow(record: record)
            }
            .tag(record.id)
            .listRowBackground(RecipeTheme.surface)
            .swipeActions {
                Button(role: .destructive) {
                    modelContext.delete(record)
                    try? modelContext.save()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func addSample() {
        guard !records.contains(where: { $0.id == SampleRecipe.espressoBrownies.id }) else {
            router.selectedRecipeID = SampleRecipe.espressoBrownies.id
            return
        }
        if let record = try? RecipeRecord(recipe: SampleRecipe.espressoBrownies) {
            modelContext.insert(record)
            try? modelContext.save()
            router.selectedRecipeID = record.id
        }
    }
}

private struct RecipeLibraryRow: View {
    let record: RecipeRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.title)
                    .font(.headline)
                Spacer()
                if record.unresolvedWarningCount > 0 {
                    Label("\(record.unresolvedWarningCount)", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(RecipeTheme.warning)
                }
            }
            if !record.summaryText.isEmpty {
                Text(record.summaryText)
                    .font(.subheadline)
                    .foregroundStyle(RecipeTheme.secondaryInk)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct EmptyLibraryDetail: View {
    let onImport: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Choose a recipe", systemImage: "rectangle.split.3x1")
        } description: {
            Text("The landscape timeline keeps ingredients on the left and cooking stages moving across the page.")
        } actions: {
            Button("Import recipe", action: onImport)
                .buttonStyle(.borderedProminent)
        }
    }
}

