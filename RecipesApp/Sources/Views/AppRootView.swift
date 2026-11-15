import RecipeCore
import SwiftData
import SwiftUI

enum LibrarySort: String, CaseIterable, Identifiable {
    case recentlyUpdated
    case recentlyAdded
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyUpdated: "Recently updated"
        case .recentlyAdded: "Recently added"
        case .title: "Title"
        }
    }
}

struct AppRootView: View {
    let persistence: PersistenceController
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \RecipeRecord.updatedAt, order: .reverse) private var records: [RecipeRecord]

    var body: some View {
        @Bindable var router = router
        // One split view for every width: it collapses to a stack when compact, so the open recipe
        // and its state survive folding iPhone Duo, rotating, or resizing the window.
        NavigationSplitView {
            RecipeLibrary(records: records, selection: $router.selectedRecipeID)
                .navigationTitle("Recipes")
                // An inline title shares the sidebar's bar with four buttons and truncates to "Re…".
                .navigationBarTitleDisplayMode(.large)
                .toolbar { libraryToolbar }
        } detail: {
            if let selected = selectedRecord {
                RecipeDetailView(record: selected)
                    .id(selected.id)
            } else {
                EmptyLibraryDetail(onImport: { router.presentedSheet = .importRecipe })
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: records.map(\.id), initial: true) { _, ids in
            reconcileSelection(with: ids)
        }
        .onChange(of: horizontalSizeClass) {
            reconcileSelection(with: records.map(\.id))
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
            var sample = SampleRecipe.espressoBrownies
            if arguments.contains("--ui-testing-malformed-yield") {
                sample.recipeYield = RecipeYield(
                    servings: Decimal(string: "0.009")!,
                    label: "9 squares"
                )
            }
            try? modelContext.insert(RecipeRecord(recipe: sample))
            try? modelContext.save()
        }
    }

    private func reconcileSelection(with ids: [String]) {
        if let selected = router.selectedRecipeID, !ids.contains(selected) {
            router.selectedRecipeID = nil
        }
        // Side by side, keep the sidebar highlight in step with the recipe shown in the detail column.
        // Collapsed, a selection pushes the recipe, so leave the library showing until one is chosen.
        if horizontalSizeClass == .regular, router.selectedRecipeID == nil {
            router.selectedRecipeID = ids.first
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarPinnedTrailing) {
            Button("Import", systemImage: "plus") { router.presentedSheet = .importRecipe }
                .accessibilityIdentifier("import-recipe")
        }
        ToolbarItem(placement: .topBarLeading) {
            Button("Settings", systemImage: "gearshape") { router.presentedSheet = .settings }
        }
    }

    private var selectedRecord: RecipeRecord? {
        if let id = router.selectedRecipeID { return records.first { $0.id == id } }
        return records.first
    }
}

private struct PendingDeletion: Equatable {
    let id: String
    let title: String
}

private struct RecipeLibrary: View {
    let records: [RecipeRecord]
    let selection: Binding<String?>
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @AppStorage(AppPreferenceKey.librarySort) private var sort: LibrarySort = .recentlyUpdated
    @State private var searchText = ""
    @State private var pendingDeletion: PendingDeletion?
    @State private var activeSessions: [CookSession] = []

    var body: some View {
        Group {
            if records.isEmpty {
                emptyLibrary
            } else {
                List(selection: selection) { content }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
            }
        }
        .background(RecipeTheme.paper)
        .searchable(text: $searchText, prompt: "Search recipes")
        .toolbar {
            if !records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { sortMenu }
            }
        }
        .confirmationDialog("Delete recipe?", item: $pendingDeletion, titleVisibility: .visible) { pending in
            Button("Delete \(pending.title)", role: .destructive) { delete(pending) }
        } message: { pending in
            Text("\(pending.title) will be removed from your library on all your devices.")
        }
        .task(id: router.activeCookSession?.id) { await loadActiveSessions() }
    }

    @ViewBuilder
    private var content: some View {
        let resumable = activeSessions.filter { session in records.contains { $0.id == session.recipeID } }
        if searchText.isEmpty, let session = resumable.first {
            ContinueCookingCard(session: session) {
                router.activeCookSession = .init(id: session.id)
            }
            .listRowInsets(.init(top: 8, leading: 16, bottom: 10, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }

        let visible = filteredRecords
        if visible.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        ForEach(visible) { record in
            let isSelected = selection.wrappedValue == record.id
            NavigationLink(value: record.id) {
                RecipeLibraryRow(record: record, isCooking: activeSessions.contains { $0.recipeID == record.id })
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paperCard(cornerRadius: 18, isHighlighted: isSelected)
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .navigationLinkIndicatorVisibility(.hidden)
            .tag(record.id)
            .listRowInsets(.init(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .swipeActions {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    pendingDeletion = .init(id: record.id, title: record.title)
                }
            }
            .contextMenu {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    pendingDeletion = .init(id: record.id, title: record.title)
                }
            }
        }
    }

    private var sortMenu: some View {
        Menu("Sort", systemImage: "arrow.up.arrow.down") {
            Picker("Sort by", selection: $sort) {
                ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
            }
        }
        .accessibilityIdentifier("library-sort")
    }

    private var filteredRecords: [RecipeRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? records : records.filter {
            $0.title.localizedStandardContains(query)
                || $0.summaryText.localizedStandardContains(query)
                || $0.sourceTitle.localizedStandardContains(query)
        }
        switch sort {
        case .recentlyUpdated:
            return matching.sorted { $0.updatedAt > $1.updatedAt }
        case .recentlyAdded:
            return matching.sorted { $0.createdAt > $1.createdAt }
        case .title:
            return matching.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("Your cookbook is empty", systemImage: "book.closed")
        } description: {
            Text("Import from a link, paste a recipe, scan a cookbook page, or try the sample recipe.")
        } actions: {
            Button("Import recipe") { router.presentedSheet = .importRecipe }
                .primaryGlassButton()
            Button("Add sample") { addSample() }
                .buttonStyle(.glass)
        }
    }

    private func loadActiveSessions() async {
        activeSessions = (try? await CookSessionStore.shared.allActiveSessions()) ?? []
    }

    private func delete(_ pending: PendingDeletion) {
        guard let record = records.first(where: { $0.id == pending.id }) else { return }
        let sessions = activeSessions.filter { $0.recipeID == pending.id }
        modelContext.delete(record)
        try? modelContext.save()
        if router.selectedRecipeID == pending.id { router.selectedRecipeID = nil }
        // A deleted recipe can't be resumed, so stop its cooking session and Live Activity too.
        Task {
            for snapshot in sessions {
                // The stored session may have gained timers since this view loaded its copy.
                let session = (try? await CookSessionStore.shared.end(sessionID: snapshot.id)) ?? snapshot
                await CookTimerNotifications.cancelAll(session: session)
                await CookActivityController.end(session: session)
            }
            await loadActiveSessions()
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

private struct ContinueCookingCard: View {
    let session: CookSession
    let onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
            HStack(spacing: 14) {
                Image(systemName: "frying.pan.fill")
                    .font(.title3)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(RecipeTheme.focus, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    EyebrowLabel("Continue cooking", color: RecipeTheme.focusText)
                    Text(session.recipeTitle)
                        .font(.headline)
                        .foregroundStyle(RecipeTheme.ink)
                    ProgressView(value: session.progress)
                        .tint(RecipeTheme.focus)
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(RecipeTheme.secondaryInk)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .background(RecipeTheme.focus.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(RecipeTheme.focus.opacity(0.35))
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Continue cooking \(session.recipeTitle)")
        .accessibilityValue("\(session.completedStageIDs.count) of \(session.stages.count) stages done")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("continue-cooking")
    }
}

private struct RecipeLibraryRow: View {
    private struct Facts: Equatable {
        var stageCount = 0
        var totalSeconds: Int?
    }

    let record: RecipeRecord
    let isCooking: Bool
    @State private var facts = Facts()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RecipeMonogram(title: record.title)
            VStack(alignment: .leading, spacing: 6) {
                Text(record.title)
                    .font(RecipeTheme.display(.headline))
                    .foregroundStyle(RecipeTheme.ink)
                if !record.summaryText.isEmpty {
                    Text(record.summaryText)
                        .font(.subheadline)
                        .foregroundStyle(RecipeTheme.secondaryInk)
                        .lineLimit(2)
                }
                metadata
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: record.updatedAt) {
            guard let recipe = try? record.recipe() else { return }
            facts = .init(stageCount: recipe.stages.count, totalSeconds: recipe.estimatedTotalSeconds)
        }
    }

    private var metadata: some View {
        let source = RecipeSourceType(rawValue: record.sourceType) ?? .manual
        return FlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
            metadataItems(source: source)
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .font(.caption.weight(.medium))
        .foregroundStyle(RecipeTheme.secondaryInk)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func metadataItems(source: RecipeSourceType) -> some View {
        if isCooking {
            Label("Cooking", systemImage: "flame.fill")
                .foregroundStyle(RecipeTheme.focusText)
        }
        if let totalSeconds = facts.totalSeconds {
            Label(RecipeDurationFormatter.string(seconds: totalSeconds), systemImage: "clock")
        }
        if facts.stageCount > 0 {
            Label("\(facts.stageCount) stage\(facts.stageCount == 1 ? "" : "s")", systemImage: "list.number")
        }
        Label(source.displayName, systemImage: source.systemImage)
        if record.unresolvedWarningCount > 0 {
            Label("\(record.unresolvedWarningCount)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(RecipeTheme.warning)
                .accessibilityLabel("\(record.unresolvedWarningCount) unresolved source warning\(record.unresolvedWarningCount == 1 ? "" : "s")")
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
                        .foregroundStyle(RecipeTheme.focus)
                        .accessibilityHidden(true)

                    VStack(spacing: 10) {
                        Text("Choose a recipe")
                            .font(RecipeTheme.display(.largeTitle))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilitySortPriority(3)
                        Text("Select a recipe to see its ingredients and cooking stages side by side.")
                            .font(.title3)
                            .foregroundStyle(RecipeTheme.secondaryInk)
                            .multilineTextAlignment(.center)
                            .accessibilitySortPriority(2)
                    }

                    Button("Import recipe", action: onImport)
                        .primaryGlassButton()
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
