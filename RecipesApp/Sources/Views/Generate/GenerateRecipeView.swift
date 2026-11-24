import RecipeCore
import SwiftData
import SwiftUI

/// Writes a recipe from what the user describes, then lets them send it back with changes
/// as many times as they like before saving it to the library.
struct GenerateRecipeView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var client = RecipeGenerationClient()
    @AppStorage(AppPreferenceKey.unitSystem) private var preferredUnits: UnitSystemPreference = .metric
    @State private var request = ""
    @State private var feedback = ""
    @State private var draft: RecipeDraft?
    /// Earlier versions, newest last, so a change that didn't work out can be undone.
    @State private var previousDrafts: [RecipeDraft] = []
    @State private var errorMessage: String?
    /// Reused when the same request is retried so the service can join in-flight work.
    @State private var attemptKey: String?
    @State private var isConfirmingDiscard = false
    @FocusState private var isFeedbackFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    review(draft)
                } else {
                    compose
                }
            }
            .background(RecipeTheme.paper)
            .navigationTitle(draft == nil ? "Create recipe" : "Review recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .overlay { if client.isWorking { progress } }
            .onChange(of: attemptFingerprint) { attemptKey = nil }
            .confirmationDialog("Discard this recipe?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                Button("Discard recipe", role: .destructive) { dismiss() }
            } message: {
                Text("It hasn't been saved to your library.")
            }
        }
        .interactiveDismissDisabled(draft != nil)
        .editorialSurface()
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                if draft == nil { dismiss() } else { isConfirmingDiscard = true }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            if let draft {
                Button("Save") { save(draft) }
                    .disabled(client.isWorking)
                    .accessibilityIdentifier("save-generated-recipe")
            } else {
                Button("Create") { Task { await generate() } }
                    .disabled(!canGenerate)
                    .accessibilityIdentifier("generate-recipe")
            }
        }
    }

    // MARK: Compose

    private var compose: some View {
        Form {
            Group {
                Section("What would you like to cook?") {
                    TextEditor(text: $request)
                        .frame(minHeight: 140)
                        .font(.body)
                        .accessibilityLabel("What would you like to cook?")
                        .accessibilityIdentifier("generation-request")
                    Text("Describe a dish, what's in your fridge, a diet or allergy, or how long you've got. You can ask for changes before you save it.")
                        .font(.footnote)
                        .foregroundStyle(RecipeTheme.secondaryInk)
                    if trimmedRequest.count > RecipeGenerationRequestBody.maximumTextLength {
                        Text("Keep it under \(RecipeGenerationRequestBody.maximumTextLength.formatted()) characters.")
                            .font(.footnote)
                            .foregroundStyle(RecipeTheme.warning)
                    }
                }

                Section("Units") {
                    Picker("Units", selection: $preferredUnits) {
                        ForEach(UnitSystemPreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("\"As written\" uses the measures cooks use where you live. \(UnitSystemPreference.explanation)")
                        .font(.footnote)
                        .foregroundStyle(RecipeTheme.secondaryInk)
                }

                if needsSignIn {
                    SignInWithAppleSection(
                        title: "Sign in to create recipes",
                        explanation: "Sign in with Apple to create recipes. Your request is sent to the recipe service to write the recipe, and isn't kept."
                    )
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
    }

    // MARK: Review

    private func review(_ draft: RecipeDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GeneratedRecipePreview(draft: draft)
                revisionCard(draft)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func revisionCard(_ draft: RecipeDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Ask for changes")
            Text("Say what to change, such as \"make it vegetarian\", \"less spicy\" or \"for six people\".")
                .font(.footnote)
                .foregroundStyle(RecipeTheme.secondaryInk)
            TextField("What should change?", text: $feedback, axis: .vertical)
                .lineLimit(2...6)
                .padding(12)
                .background(RecipeTheme.stage.opacity(0.58), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .focused($isFeedbackFocused)
                .accessibilityIdentifier("revision-feedback")
            if trimmedFeedback.count > RecipeGenerationRequestBody.maximumTextLength {
                Text("Keep it under \(RecipeGenerationRequestBody.maximumTextLength.formatted()) characters.")
                    .font(.footnote)
                    .foregroundStyle(RecipeTheme.warning)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(RecipeTheme.warning)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { revisionButtons }
                VStack(alignment: .leading, spacing: 10) { revisionButtons }
            }
            if !draft.feedback.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    EyebrowLabel("Changes so far")
                    ForEach(Array(draft.feedback.enumerated()), id: \.offset) { _, change in
                        Label(change, systemImage: "checkmark")
                            .font(.subheadline)
                            .foregroundStyle(RecipeTheme.secondaryInk)
                    }
                }
                .padding(.top, 4)
                .accessibilityElement(children: .combine)
            }
            if needsSignIn {
                SignInWithAppleSection(
                    title: "Sign in to keep revising",
                    explanation: "Your sign-in has expired. Sign in with Apple again to send this recipe back for changes."
                )
            }
        }
        .padding(16)
        .paperCard(cornerRadius: 20)
    }

    @ViewBuilder
    private var revisionButtons: some View {
        Button("Revise recipe", systemImage: "arrow.trianglehead.2.clockwise") {
            Task { await revise() }
        }
        .primaryGlassButton()
        .disabled(!canRevise)
        .accessibilityIdentifier("revise-recipe")
        if !previousDrafts.isEmpty {
            Button("Undo last change", systemImage: "arrow.uturn.backward") { undo() }
                .buttonStyle(.glass)
                .disabled(client.isWorking)
                .accessibilityIdentifier("undo-revision")
        }
        Button("Start over", systemImage: "square.and.pencil") { startOver() }
            .buttonStyle(.glass)
            .disabled(client.isWorking)
    }

    private var progress: some View {
        ZStack {
            RecipeTheme.paper.opacity(0.86).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(RecipeTheme.focus)
                Text(client.state == .revising ? "Revising your recipe…" : "Writing your recipe…")
                    .font(RecipeTheme.display(.title3))
                Text("It may look things up on the web, so this can take a minute.")
                    .font(.footnote)
                    .foregroundStyle(RecipeTheme.secondaryInk)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private var trimmedRequest: String { request.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedFeedback: String { feedback.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var needsSignIn: Bool { client.requiresSignIn && !auth.isAuthenticated }

    private var canGenerate: Bool {
        (RecipeGenerationRequestBody.minimumRequestLength...RecipeGenerationRequestBody.maximumTextLength).contains(trimmedRequest.count)
            && !needsSignIn && !client.isWorking
    }

    private var canRevise: Bool {
        (1...RecipeGenerationRequestBody.maximumTextLength).contains(trimmedFeedback.count) && !needsSignIn && !client.isWorking
    }

    /// Changes whenever what would be sent changes, so a retry of the same request keeps its key.
    private var attemptFingerprint: String {
        [preferredUnits.rawValue, trimmedRequest, draft?.recipe.id ?? "", String(draft?.feedback.count ?? 0), trimmedFeedback]
            .joined(separator: "|")
    }

    private func generate() async {
        errorMessage = nil
        do {
            let key = attemptKey ?? UUID().uuidString
            attemptKey = key
            let created = try await client.generate(request: trimmedRequest, auth: auth, preferredUnits: preferredUnits, idempotencyKey: key)
            attemptKey = nil
            previousDrafts = []
            draft = created
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revise() async {
        guard let current = draft else { return }
        errorMessage = nil
        isFeedbackFocused = false
        do {
            let key = attemptKey ?? UUID().uuidString
            attemptKey = key
            let revised = try await client.generate(
                request: trimmedRequest,
                revision: RecipeRevision(draft: current, feedback: trimmedFeedback),
                auth: auth,
                preferredUnits: preferredUnits,
                idempotencyKey: key
            )
            attemptKey = nil
            previousDrafts.append(current)
            draft = revised
            feedback = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func undo() {
        guard let previous = previousDrafts.popLast() else { return }
        draft = previous
        errorMessage = nil
    }

    private func startOver() {
        draft = nil
        previousDrafts = []
        feedback = ""
        errorMessage = nil
    }

    private func save(_ draft: RecipeDraft) {
        do {
            let descriptor = FetchDescriptor<RecipeRecord>()
            if let existing = try modelContext.fetch(descriptor).first(where: { $0.id == draft.recipe.id }) {
                try existing.update(with: draft.recipe)
            } else {
                modelContext.insert(try RecipeRecord(recipe: draft.recipe))
            }
            try modelContext.save()
            router.selectedRecipeID = draft.recipe.id
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A read-only look at a draft: enough to judge it and say what to change.
private struct GeneratedRecipePreview: View {
    let draft: RecipeDraft

    private var recipe: RecipeV1 { draft.recipe }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            ingredients
            if !recipe.prepTasks.isEmpty { prep }
            warnings
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Method")
                FocusedStepList(recipe: recipe)
            }
            if !draft.sources.isEmpty { sources }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            EyebrowLabel(draft.feedback.isEmpty ? "Draft" : "Revision \(draft.feedback.count)", color: RecipeTheme.focusText)
            Text(recipe.title)
                .font(RecipeTheme.display(.largeTitle, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("draft-title")
            if let summary = recipe.summary, !summary.isEmpty {
                Text(summary)
                    .font(.title3)
                    .foregroundStyle(RecipeTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("draft-summary")
            }
            FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                MetricChip(text: recipe.recipeYield.label ?? "Serves \(recipe.recipeYield.servings.formatted())", systemImage: "person.2")
                if let total = recipe.estimatedTotalSeconds {
                    MetricChip(text: RecipeDurationFormatter.string(seconds: total), systemImage: "clock")
                }
                MetricChip(text: "\(recipe.stages.count) stage\(recipe.stages.count == 1 ? "" : "s")", systemImage: "list.number")
            }
        }
    }

    private var ingredients: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Ingredients")
            VStack(spacing: 0) {
                let sorted = recipe.sortedIngredients
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, ingredient in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(ingredient.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let quantity = ingredient.displayQuantity(
                            servings: recipe.recipeYield.servings,
                            originalServings: recipe.recipeYield.servings,
                            units: .source
                        ) {
                            Text(quantity)
                                .font(.body.weight(.semibold).monospacedDigit())
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .padding(.vertical, 11)
                    .accessibilityElement(children: .combine)
                    if index < sorted.count - 1 {
                        Divider().overlay(RecipeTheme.gridSubtle)
                    }
                }
            }
            .padding(.horizontal, 16)
            .paperCard(cornerRadius: 20)
        }
    }

    private var prep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Before you start")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(recipe.prepTasks.sorted { $0.sortIndex < $1.sortIndex }) { task in
                    Label(task.instruction, systemImage: "circle.dashed")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperCard(cornerRadius: 20)
        }
    }

    @ViewBuilder
    private var warnings: some View {
        let unresolved = recipe.uncertainties.filter { !$0.isResolved }
        if !unresolved.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Worth checking", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(RecipeTheme.warning)
                ForEach(unresolved) { warning in
                    Label(warning.message, systemImage: warning.severity == .critical ? "exclamationmark.octagon" : "info.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .background(RecipeTheme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Sources consulted")
            Text("Pages read while writing this recipe. They're saved with it.")
                .font(.footnote)
                .foregroundStyle(RecipeTheme.secondaryInk)
            ForEach(draft.sources, id: \.url) { source in
                Link(destination: source.url) {
                    Label(source.displayName, systemImage: "safari")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .paperCard(cornerRadius: 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("draft-sources")
    }
}
