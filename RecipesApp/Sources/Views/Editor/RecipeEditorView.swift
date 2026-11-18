import RecipeCore
import SwiftData
import SwiftUI

struct RecipeEditorView: View {
    private struct StageSelection: Identifiable {
        let id: String
    }

    let record: RecipeRecord
    let onSave: (RecipeV1) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// Set only when the saved recipe can be decoded; editing anything else could overwrite it.
    private let loadError: String?
    @State private var draft: RecipeV1
    @State private var selectedStage: StageSelection?
    @State private var validationMessage: String?

    init(record: RecipeRecord, onSave: @escaping (RecipeV1) -> Void) {
        self.record = record
        self.onSave = onSave
        do {
            _draft = State(initialValue: try record.recipe())
            loadError = nil
        } catch {
            _draft = State(initialValue: RecipeV1(
                id: record.id,
                title: record.title,
                recipeYield: .init(servings: 1),
                ingredients: [],
                stages: [],
                provenance: .init(sourceType: .manual)
            ))
            loadError = error.localizedDescription
        }
    }

    var body: some View {
        NavigationStack {
            if let loadError {
                ContentUnavailableView(
                    "This recipe can't be edited",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
            } else {
                editorForm
            }
        }
        .editorialSurface()
    }

    private var editorForm: some View {
            Form {
                Section("Recipe") {
                    TextField("Title", text: $draft.title)
                    TextField("Summary", text: Binding($draft.summary, replacingNilWith: ""), axis: .vertical)
                    LabeledContent("Original servings") {
                        TextField("Servings", value: $draft.recipeYield.servings, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Ingredients") {
                    ForEach($draft.ingredients) { $ingredient in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Ingredient", text: $ingredient.name)
                            HStack {
                                if ingredient.quantity?.kind == .exact {
                                    TextField("Amount", value: Binding(
                                        get: { ingredient.quantity?.value ?? 0 },
                                        set: { ingredient.quantity?.value = $0 }
                                    ), format: .number)
                                    .keyboardType(.decimalPad)
                                    Picker("Unit", selection: Binding(
                                        get: { ingredient.quantity?.unit ?? .none },
                                        set: { ingredient.quantity?.unit = $0 }
                                    )) {
                                        ForEach(UnitID.allCases, id: \.self) { unit in
                                            Text(unit.editorName).tag(unit)
                                        }
                                    }
                                } else {
                                    Text(ingredient.quantity?.displayString() ?? "No quantity")
                                        .foregroundStyle(RecipeTheme.secondaryInk)
                                }
                                Toggle("Scale with servings", isOn: $ingredient.scalable)
                                    .labelsHidden()
                            }
                            .font(.subheadline)
                        }
                        .padding(.vertical, 3)
                    }
                    .onDelete { offsets in
                        // Removing references too keeps stages, prep tasks, and warnings valid.
                        let ids = offsets.map { draft.ingredients[$0].id }
                        for id in ids { draft.removeIngredient(id: id) }
                    }
                    Button("Add ingredient", systemImage: "plus") { addIngredient() }
                }

                Section("Stages") {
                    ForEach(draft.sortedStages) { stage in
                        Button {
                            selectedStage = .init(id: stage.id)
                        } label: {
                            HStack {
                                Text("\(stage.sortIndex + 1)").monospacedDigit().foregroundStyle(RecipeTheme.secondaryInk)
                                VStack(alignment: .leading) {
                                    Text(stage.action).font(.headline)
                                    Text(stage.instruction).font(.caption).lineLimit(2).foregroundStyle(RecipeTheme.secondaryInk)
                                }
                                Spacer()
                                Image(systemName: "line.3.horizontal")
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .draggable(stage.id)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let source = ids.first else { return false }
                            moveStage(sourceID: source, before: stage.id)
                            return true
                        }
                    }
                    .onMove(perform: moveStages)
                    .onDelete { offsets in
                        let ids = offsets.map { draft.sortedStages[$0].id }
                        for id in ids { draft.removeStage(id: id) }
                    }
                    Button("Add stage", systemImage: "plus") { addStage() }
                }

                if !draft.uncertainties.isEmpty {
                    Section("Source warnings") {
                        ForEach($draft.uncertainties) { $uncertainty in
                            Toggle(isOn: $uncertainty.isResolved) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(uncertainty.message)
                                    Text(uncertainty.isResolved ? "Resolved" : uncertainty.severity.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(uncertainty.isResolved ? RecipeTheme.success : RecipeTheme.warning)
                                }
                            }
                        }
                    }
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(RecipeTheme.warning)
                    }
                }
            }
            .navigationTitle("Edit recipe")
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, .constant(.active))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .primaryGlassButton()
                }
            }
            .sheet(item: $selectedStage) { selection in
                StageDetailEditor(recipe: $draft, stageID: selection.id)
            }
    }

    private func save() {
        normalizeIngredientOrder()
        normalizeStageOrderAndDependencies()
        let validation = RecipeValidator.validate(draft)
        let errors = validation.issues.filter { $0.severity == .error }
        guard errors.isEmpty else {
            validationMessage = errors.map(\.message).joined(separator: " ")
            return
        }
        do {
            try record.update(with: draft)
            try modelContext.save()
            onSave(draft)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func addIngredient() {
        draft.ingredients.append(.init(
            name: "New ingredient",
            quantity: .exact(1, unit: .count),
            sortIndex: draft.ingredients.count
        ))
    }

    private func addStage() {
        let previous = draft.sortedStages.last
        draft.stages.append(.init(
            action: "New stage",
            instruction: "Describe what to do and how you'll know it's done.",
            workstreamID: previous?.workstreamID,
            dependencies: previous.map { [$0.id] } ?? [],
            sortIndex: draft.stages.count
        ))
    }

    private func moveStages(from offsets: IndexSet, to destination: Int) {
        var ordered = draft.sortedStages
        ordered.move(fromOffsets: offsets, toOffset: destination)
        applyStageOrder(ordered)
    }

    private func moveStage(sourceID: String, before targetID: String) {
        guard sourceID != targetID else { return }
        let old = draft
        var ordered = draft.sortedStages
        guard let source = ordered.firstIndex(where: { $0.id == sourceID }),
              let target = ordered.firstIndex(where: { $0.id == targetID }) else { return }
        let item = ordered.remove(at: source)
        ordered.insert(item, at: source < target ? max(0, target - 1) : target)
        applyStageOrder(ordered)
        if !RecipeValidator.validate(draft).isValid {
            draft = old
            validationMessage = "That stage can't move there because another stage depends on it."
        }
    }

    private func applyStageOrder(_ ordered: [Stage]) {
        draft.stages = ordered
        normalizeStageOrderAndDependencies()
    }

    private func normalizeIngredientOrder() {
        for index in draft.ingredients.indices { draft.ingredients[index].sortIndex = index }
    }

    private func normalizeStageOrderAndDependencies() {
        for index in draft.stages.indices { draft.stages[index].sortIndex = index }
        let laneIDs = Dictionary(uniqueKeysWithValues: draft.stages.map { ($0.id, $0.workstreamID) })
        let groups = Dictionary(grouping: draft.stages.indices, by: { draft.stages[$0].workstreamID ?? "__global__" })
        for indices in groups.values {
            let ordered = indices.sorted { draft.stages[$0].sortIndex < draft.stages[$1].sortIndex }
            for (offset, index) in ordered.enumerated() {
                let external = draft.stages[index].dependencies.filter { laneIDs[$0] != draft.stages[index].workstreamID }
                let prior = offset > 0 ? [draft.stages[ordered[offset - 1]].id] : []
                draft.stages[index].dependencies = Array(Set(external + prior)).sorted()
            }
        }
    }
}

private struct StageDetailEditor: View {
    @Binding var recipe: RecipeV1
    let stageID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let index = recipe.stages.firstIndex(where: { $0.id == stageID }) {
                    Form {
                    Section("Stage") {
                        TextField("Action", text: $recipe.stages[index].action)
                        TextField("Instruction", text: $recipe.stages[index].instruction, axis: .vertical)
                            .lineLimit(3...8)
                        TextField("How to tell it's done", text: Binding($recipe.stages[index].completionCue, replacingNilWith: ""), axis: .vertical)
                        TextField("Result name", text: Binding($recipe.stages[index].resultLabel, replacingNilWith: ""))
                    }
                    Section("Timeline lane") {
                        Picker("Lane", selection: $recipe.stages[index].workstreamID) {
                            Text("Whole recipe").tag(String?.none)
                            ForEach(recipe.workstreams) { lane in Text(lane.name).tag(String?.some(lane.id)) }
                        }
                    }
                    Section("Ingredients added in this stage") {
                        ForEach(recipe.sortedIngredients) { ingredient in
                            Toggle(ingredient.name, isOn: ingredientUseBinding(stageIndex: index, ingredientID: ingredient.id))
                        }
                    }
                    Section("Must follow") {
                        ForEach(recipe.sortedStages.filter { $0.id != stageID }) { candidate in
                            Toggle(candidate.action, isOn: dependencyBinding(stageIndex: index, dependencyID: candidate.id))
                        }
                    }
                    Section("Heat and timing") {
                        TextField("Heat, for example medium-low", text: Binding($recipe.stages[index].heat, replacingNilWith: ""))
                        if let duration = recipe.stages[index].duration {
                            Stepper("Minimum time: \(duration.minimumSeconds / 60) min", value: Binding(
                                get: { recipe.stages[index].duration?.minimumSeconds ?? 0 },
                                set: { recipe.stages[index].duration?.minimumSeconds = $0 }
                            ), in: 0...86_400, step: 60)
                        } else {
                            Button("Add duration") { recipe.stages[index].duration = .init(minimumSeconds: 300) }
                        }
                    }
                    }
                } else {
                    ContentUnavailableView("Stage unavailable", systemImage: "exclamationmark.triangle")
                }
            }
            .navigationTitle("Stage details")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .editorialSurface()
    }

    private func ingredientUseBinding(stageIndex: Int, ingredientID: String) -> Binding<Bool> {
        Binding {
            recipe.stages[stageIndex].ingredientUses.contains { $0.ingredientID == ingredientID }
        } set: { enabled in
            if enabled {
                if !recipe.stages[stageIndex].ingredientUses.contains(where: { $0.ingredientID == ingredientID }) {
                    recipe.stages[stageIndex].ingredientUses.append(.init(ingredientID: ingredientID))
                }
            } else {
                recipe.stages[stageIndex].ingredientUses.removeAll { $0.ingredientID == ingredientID }
            }
        }
    }

    private func dependencyBinding(stageIndex: Int, dependencyID: String) -> Binding<Bool> {
        Binding {
            recipe.stages[stageIndex].dependencies.contains(dependencyID)
        } set: { enabled in
            if enabled {
                recipe.stages[stageIndex].dependencies.append(dependencyID)
                recipe.stages[stageIndex].dependencies = Array(Set(recipe.stages[stageIndex].dependencies)).sorted()
            } else {
                recipe.stages[stageIndex].dependencies.removeAll { $0 == dependencyID }
            }
        }
    }
}

private extension Binding where Value == String {
    init(_ source: Binding<String?>, replacingNilWith defaultValue: String) {
        self.init(
            get: { source.wrappedValue ?? defaultValue },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

private extension UnitID {
    /// A readable unit name for the editor's picker. US and UK pints and fluid ounces are named
    /// side by side so a recipe imported with the wrong one can be corrected.
    var editorName: String {
        switch self {
        case .none: "No unit"
        case .count: "Count"
        case .fluidOunce: "US fl oz"
        case .pint: "US pint"
        default: CulinaryUnits.symbol(for: self)
        }
    }
}
