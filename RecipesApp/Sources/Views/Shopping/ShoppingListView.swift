import RecipeCore
import SwiftUI

struct ShoppingListRequest: Hashable, Identifiable, Sendable {
    let recipeTitle: String
    let servings: Decimal
    let items: [ShoppingListItem]
    /// Items left unticked to start with: the cook has already gathered every ingredient in them.
    let initiallyExcludedIDs: Set<String>

    var id: String { recipeTitle }

    init(recipe: RecipeV1, servings: Decimal, units: UnitSystemPreference, gatheredIngredientIDs: Set<String>) {
        recipeTitle = recipe.title
        self.servings = servings
        items = ShoppingList.items(for: recipe, servings: servings, units: units)
        initiallyExcludedIDs = Set(
            items.filter { !$0.ingredientIDs.isEmpty && $0.ingredientIDs.allSatisfy(gatheredIngredientIDs.contains) }.map(\.id)
        )
    }
}

/// Adds a recipe's ingredients, at the chosen servings, to a list in Reminders.
struct ShoppingListView: View {
    let request: ShoppingListRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppPreferenceKey.shoppingReminderList) private var savedListID = ""
    @State private var store: (any ShoppingReminderStore)?
    @State private var selectedIDs: Set<String> = []
    @State private var access: ReminderAccess = .notDetermined
    @State private var lists: [ReminderListSummary] = []
    @State private var listID = ""
    @State private var isAdding = false
    @State private var result: ShoppingReminderResult?
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    ContentUnavailableView {
                        Label(resultTitle(result), systemImage: "checkmark.circle.fill")
                    } description: {
                        Text(resultDescription(result))
                    }
                    .accessibilityIdentifier("shopping-list-result")
                } else {
                    itemList
                }
            }
            .navigationTitle("Shopping list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: result == nil ? .cancellationAction : .confirmationAction) {
                    Button(result == nil ? "Cancel" : "Done") { dismiss() }
                        // Dismissing wouldn't stop an add that's under way.
                        .disabled(isAdding)
                }
            }
            .safeAreaBar(edge: .bottom) {
                if result == nil { addButton }
            }
        }
        .editorialSurface()
        .interactiveDismissDisabled(isAdding)
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            selectedIDs = Set(request.items.map(\.id)).subtracting(request.initiallyExcludedIDs)
            let store = ShoppingReminderStoreFactory.make()
            self.store = store
            refreshLists(from: store)
        }
        .onChange(of: scenePhase) { _, phase in
            // Pick up access granted in Settings, or lists changed in Reminders, while the app was away.
            guard phase == .active, !isAdding, let store else { return }
            refreshLists(from: store)
        }
    }

    // MARK: Items

    private var itemList: some View {
        List {
            Section {
                ForEach(request.items) { item in
                    itemRow(item)
                }
            } header: {
                HStack {
                    Text("\(request.recipeTitle) · \(request.servings.formatted()) serving\(request.servings == 1 ? "" : "s")")
                    Spacer()
                    Button(allSelected ? "Select none" : "Select all") {
                        selectedIDs = allSelected ? [] : Set(request.items.map(\.id))
                    }
                    .font(.subheadline)
                    .textCase(nil)
                    .accessibilityIdentifier("shopping-list-select-all")
                }
            } footer: {
                if !request.initiallyExcludedIDs.isEmpty {
                    Text("Ingredients you've ticked off as gathered start unselected.")
                }
            }

            Section {
                listChooser
            } header: {
                Text("Reminders list")
            } footer: {
                Text("Each ingredient becomes a reminder, with the amount and recipe in its notes. Anything already on the list is updated rather than added twice.")
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
    }

    private func itemRow(_ item: ShoppingListItem) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        return Button {
            if isSelected { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? RecipeTheme.focus : RecipeTheme.grid)
                    .accessibilityHidden(true)
                Text(item.name)
                    .foregroundStyle(isSelected ? RecipeTheme.ink : RecipeTheme.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let quantity = item.quantity {
                    Text(quantity)
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? RecipeTheme.ink : RecipeTheme.secondaryInk)
                        .multilineTextAlignment(.trailing)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(RecipeTheme.surface)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("shopping-item-\(item.id)")
    }

    @ViewBuilder
    private var listChooser: some View {
        switch access {
        case .granted:
            if lists.isEmpty {
                Text(ShoppingReminderError.noWritableList.localizedDescription)
                    .foregroundStyle(RecipeTheme.secondaryInk)
                    .listRowBackground(RecipeTheme.surface)
            } else {
                Picker("List", selection: $listID) {
                    ForEach(lists) { list in
                        Text(list.title).tag(list.id)
                    }
                }
                .disabled(isAdding)
                .listRowBackground(RecipeTheme.surface)
                .accessibilityIdentifier("shopping-list-picker")
            }
        case .notDetermined:
            Text("Recipe Timeline will ask to use Reminders when you add these items.")
                .foregroundStyle(RecipeTheme.secondaryInk)
                .listRowBackground(RecipeTheme.surface)
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Text(ShoppingReminderError.accessDenied.localizedDescription)
                    .foregroundStyle(RecipeTheme.secondaryInk)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            .listRowBackground(RecipeTheme.surface)
        }
    }

    private var addButton: some View {
        Button {
            Task { await addSelectedItems() }
        } label: {
            Group {
                if isAdding {
                    ProgressView()
                } else {
                    Label(addButtonTitle, systemImage: "checklist")
                }
            }
            .font(.headline)
            .padding(.horizontal, 8)
        }
        .primaryGlassButton()
        .controlSize(.extraLarge)
        .disabled(selectedItems.isEmpty || isAdding || access == .denied || (access == .granted && lists.isEmpty))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityIdentifier("shopping-list-add")
    }

    // MARK: State

    private var allSelected: Bool { selectedIDs.count == request.items.count }

    private var selectedItems: [ShoppingListItem] {
        request.items.filter { selectedIDs.contains($0.id) }
    }

    private var addButtonTitle: String {
        let count = selectedItems.count
        return count == 0 ? "Add to Reminders" : "Add \(count) item\(count == 1 ? "" : "s") to Reminders"
    }

    private func refreshLists(from store: any ShoppingReminderStore) {
        access = store.access
        lists = store.writableLists()
        let available = Set(lists.map(\.id))
        if available.contains(listID) { return }
        if available.contains(savedListID) {
            listID = savedListID
        } else if let defaultID = store.defaultListID(), available.contains(defaultID) {
            listID = defaultID
        } else {
            listID = lists.first?.id ?? ""
        }
    }

    private func addSelectedItems() async {
        guard let store else { return }
        isAdding = true
        errorMessage = nil
        defer { isAdding = false }
        do {
            if store.access != .granted {
                let granted = try await store.requestAccess()
                refreshLists(from: store)
                guard granted else { return }
            }
            let destination = listID
            guard !destination.isEmpty else { throw ShoppingReminderError.noWritableList }
            let result = try await store.add(selectedItems, recipeTitle: request.recipeTitle, toList: destination)
            savedListID = destination
            withAnimation(.snappy) { self.result = result }
        } catch {
            refreshLists(from: store)
            errorMessage = error.localizedDescription
        }
    }

    private func resultTitle(_ result: ShoppingReminderResult) -> String {
        if result.addedCount == 0 && result.updatedCount == 0 { return "Already on \(result.listTitle)" }
        return "Added to \(result.listTitle)"
    }

    private func resultDescription(_ result: ShoppingReminderResult) -> String {
        var parts: [String] = []
        if result.addedCount > 0 {
            parts.append("\(result.addedCount) new item\(result.addedCount == 1 ? "" : "s")")
        }
        if result.updatedCount > 0 {
            parts.append("\(result.updatedCount) existing item\(result.updatedCount == 1 ? "" : "s") updated")
        }
        if result.alreadyListedCount > 0 {
            parts.append("\(result.alreadyListedCount) already listed")
        }
        return parts.joined(separator: ", ") + "."
    }
}
