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
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("--ui-testing"),
                  !arguments.contains("--ui-testing-empty-library"),
                  records.isEmpty
            else { return }
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
            let isSelected = selection?.wrappedValue == record.id
            NavigationLink(value: record.id) {
                RecipeLibraryRow(record: record)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        isSelected ? RecipeTheme.focus.opacity(0.11) : RecipeTheme.surface,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                isSelected ? RecipeTheme.focus.opacity(0.9) : RecipeTheme.gridSubtle,
                                lineWidth: isSelected ? 1.5 : 0.75
                            )
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .tag(record.id)
            .listRowInsets(.init(top: 6, leading: 12, bottom: 6, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
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
                        .accessibilityLabel("\(record.unresolvedWarningCount) unresolved source warning\(record.unresolvedWarningCount == 1 ? "" : "s")")
                }
            }
            if !record.summaryText.isEmpty {
                Text(record.summaryText)
                    .font(.subheadline)
                    .foregroundStyle(RecipeTheme.secondaryInk)
                    .lineLimit(2)
            }
        }
    }
}

private struct EmptyLibraryDetail: View {
    let onImport: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var illustrationSize = 68
    @ScaledMetric(relativeTo: .body) private var contentSpacing = 24

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: contentSpacing) {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.system(size: illustrationSize, weight: .light))
                        .foregroundStyle(RecipeTheme.secondaryInk)
                        .accessibilityHidden(true)

                    VStack(spacing: 10) {
                        Text("Choose a recipe")
                            .font(.largeTitle.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilitySortPriority(3)
                        Text("The landscape timeline keeps ingredients on the left and cooking stages moving across the page.")
                            .font(.title3)
                            .foregroundStyle(RecipeTheme.secondaryInk)
                            .multilineTextAlignment(.center)
                            .accessibilitySortPriority(2)
                    }

                    Button("Import recipe", action: onImport)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilitySortPriority(1)
                }
                .frame(maxWidth: 680)
                .padding(40)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(RecipeTheme.paper.ignoresSafeArea())
        .accessibilityIdentifier("empty-library-detail")
    }
}
