import RecipeCore
import SwiftData
import SwiftUI

struct RecipeDetailView: View {
    private struct LoadIdentity: Hashable {
        let recordID: String
        let updatedAt: Date
    }

    private enum DetailSheet: Identifiable {
        case editor
        case source
        case export(RecipeExportRequest)

        var id: String {
            switch self {
            case .editor: "editor"
            case .source: "source"
            case .export: "export"
            }
        }
    }

    let record: RecipeRecord
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppPreferenceKey.unitSystem) private var units: UnitSystemPreference = .metric
    @State private var recipe: RecipeV1?
    @State private var loadError: String?
    @State private var servings = 1.0
    @State private var presentedSheet: DetailSheet?
    @State private var cookError: String?
    @State private var activeSession: CookSession?
    @State private var gatheredIngredientIDs: Set<String> = []

    var body: some View {
        Group {
            if let recipe {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        recipeHeader(recipe)
                        if usesStepList {
                            ingredientSection(recipe)
                        }
                        prepSection(recipe)
                        uncertaintySection(recipe)
                        stagesSection(recipe)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 96)
                }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom) {
                    startCookingBar(recipe)
                }
            } else if let loadError {
                ContentUnavailableView(
                    "Recipe unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This saved recipe can't be opened. \(loadError)")
                )
            } else {
                ProgressView()
            }
        }
        .background(RecipeTheme.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit", systemImage: "slider.horizontal.3") { presentedSheet = .editor }
                    .disabled(recipe == nil)
                    .accessibilityIdentifier("edit-recipe")
            }
            .visibilityPriority(.high)
            ToolbarItem(placement: .primaryAction) {
                Button("Export", systemImage: "square.and.arrow.up") {
                    guard let recipe else { return }
                    presentedSheet = .export(.init(recipe: recipe, servings: selectedServings, units: units))
                }
                .disabled(recipe == nil)
                .accessibilityIdentifier("export-recipe")
            }
            ToolbarOverflowMenu {
                Button("View source", systemImage: "doc.text.magnifyingglass") { presentedSheet = .source }
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .editor:
                RecipeEditorView(record: record) { updated in
                    var resolved = updated
                    resolved.recipeYield.servings = updated.recipeYield.resolvedServings
                    recipe = resolved
                    servings = NSDecimalNumber(decimal: resolved.recipeYield.servings).doubleValue
                }
            case .source:
                RecipeSourceView(record: record)
            case let .export(request):
                RecipeExportView(request: request)
            }
        }
        .task(id: LoadIdentity(recordID: record.id, updatedAt: record.updatedAt)) {
            recipe = nil
            loadError = nil
            servings = 1
            do {
                let loaded = try record.recipe()
                let session = try? await CookSessionStore.shared.activeSession(for: record.id)
                recipe = loaded
                activeSession = session
                // A cook in progress keeps the scale it started with until the cook changes it here.
                servings = NSDecimalNumber(decimal: session?.servings ?? loaded.recipeYield.resolvedServings).doubleValue
                gatheredIngredientIDs.formIntersection(loaded.ingredients.map(\.id))
            } catch {
                loadError = error.localizedDescription
            }
        }
        .onChange(of: router.activeCookSession?.id) {
            Task { activeSession = try? await CookSessionStore.shared.activeSession(for: record.id) }
        }
    }

    private var usesStepList: Bool {
        horizontalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize
    }

    private var selectedServings: Decimal {
        NSDecimalNumber(value: servings).decimalValue
    }

    // MARK: Header

    private func recipeHeader(_ recipe: RecipeV1) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                EyebrowLabel(headerEyebrow(recipe), color: RecipeTheme.focusText)
                Text(recipe.title)
                    .font(RecipeTheme.display(.largeTitle, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let summary = recipe.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.title3)
                        .foregroundStyle(RecipeTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if let total = recipe.estimatedTotalSeconds {
                        MetricChip(text: RecipeDurationFormatter.string(seconds: total), systemImage: "clock")
                    }
                    MetricChip(text: "\(recipe.stages.count) stage\(recipe.stages.count == 1 ? "" : "s")", systemImage: "list.number")
                    MetricChip(text: "\(recipe.ingredients.count) ingredient\(recipe.ingredients.count == 1 ? "" : "s")", systemImage: "basket")
                    if recipe.workstreams.count > 1 {
                        MetricChip(text: "\(recipe.workstreams.count) in parallel", systemImage: "arrow.triangle.branch")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()

            scalingControls(recipe)
        }
        .padding(.horizontal)
    }

    private func headerEyebrow(_ recipe: RecipeV1) -> String {
        let source = recipe.provenance.sourceType.displayName
        if let host = recipe.provenance.url.flatMap(URL.init(string:))?.host() {
            return "\(source) · \(host.replacingOccurrences(of: "www.", with: ""))"
        }
        return source
    }

    private func scalingControls(_ recipe: RecipeV1) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    servingsControl(recipe).fixedSize()
                    unitsControl
                }
                VStack(alignment: .leading, spacing: 14) {
                    servingsControl(recipe)
                    unitsControl
                }
            }
        }
        .padding(16)
        .paperCard(cornerRadius: 20)
    }

    private func servingsControl(_ recipe: RecipeV1) -> some View {
        Stepper(value: $servings, in: 1...100, step: 1) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Servings")
                    .font(.subheadline)
                    .foregroundStyle(RecipeTheme.secondaryInk)
                Text(servings.formatted(.number.precision(.fractionLength(0...1))))
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText(value: servings))
            }
            .frame(minWidth: 120, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier("servings-control")
        .accessibilityHint(recipe.recipeYield.label.map { "The original recipe makes \($0)." } ?? "")
    }

    private var unitsControl: some View {
        Picker("Units", selection: $units) {
            ForEach(UnitSystemPreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
    }

    // MARK: Sections

    private func ingredientSection(_ recipe: RecipeV1) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Ingredients") {
                if !gatheredIngredientIDs.isEmpty {
                    Button("Clear") { gatheredIngredientIDs.removeAll() }
                        .font(.subheadline)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(recipe.sortedIngredients.enumerated()), id: \.element.id) { index, ingredient in
                    let gathered = gatheredIngredientIDs.contains(ingredient.id)
                    Button {
                        withAnimation(.snappy) {
                            if gathered { gatheredIngredientIDs.remove(ingredient.id) } else { gatheredIngredientIDs.insert(ingredient.id) }
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: gathered ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(gathered ? RecipeTheme.success : RecipeTheme.grid)
                                .font(.body)
                                .accessibilityHidden(true)
                            Text(ingredient.name)
                                .strikethrough(gathered, color: RecipeTheme.secondaryInk)
                                .foregroundStyle(gathered ? RecipeTheme.secondaryInk : RecipeTheme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let quantity = ingredient.displayQuantity(
                                servings: selectedServings,
                                originalServings: recipe.recipeYield.servings,
                                units: units
                            ) {
                                Text(quantity)
                                    .font(.body.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(gathered ? RecipeTheme.secondaryInk : RecipeTheme.ink)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(gathered ? "Gathered" : "")
                    .accessibilityHint("Marks this ingredient as gathered")
                    if index < recipe.ingredients.count - 1 {
                        Divider().overlay(RecipeTheme.gridSubtle)
                    }
                }
            }
            .padding(.horizontal, 16)
            .paperCard(cornerRadius: 20)
        }
        .padding(.horizontal)
        .accessibilityIdentifier("ingredient-list")
    }

    @ViewBuilder
    private func prepSection(_ recipe: RecipeV1) -> some View {
        if !recipe.prepTasks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Before you start")
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recipe.prepTasks.sorted { $0.sortIndex < $1.sortIndex }) { task in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "circle.dashed")
                                .foregroundStyle(RecipeTheme.focus)
                                .accessibilityHidden(true)
                            Text(task.instruction)
                                .fixedSize(horizontal: false, vertical: true)
                            if task.isOptional {
                                Text("Optional")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(RecipeTheme.secondaryInk)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .paperCard(cornerRadius: 20)
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func uncertaintySection(_ recipe: RecipeV1) -> some View {
        let unresolved = recipe.uncertainties.filter { !$0.isResolved }
        if !unresolved.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(unresolved) { warning in
                        Label(warning.message, systemImage: warning.severity == .critical ? "exclamationmark.octagon" : "info.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Review these in Edit to mark them resolved.")
                        .font(.footnote)
                        .foregroundStyle(RecipeTheme.secondaryInk)
                }
                .padding(.top, 8)
            } label: {
                Label("\(unresolved.count) thing\(unresolved.count == 1 ? "" : "s") to check", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(RecipeTheme.warning)
            }
            .padding(16)
            .background(RecipeTheme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func stagesSection(_ recipe: RecipeV1) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(usesStepList ? "Method" : "Timeline")
                .padding(.horizontal)
            if usesStepList {
                FocusedStepList(recipe: recipe, servings: selectedServings, units: units)
                    .padding(.horizontal)
            } else {
                TimelineGridView(recipe: recipe, servings: selectedServings, units: units)
                    .frame(minHeight: 520)
                    .padding(.horizontal)
            }
        }
    }

    // MARK: Cooking

    private func startCookingBar(_ recipe: RecipeV1) -> some View {
        VStack(alignment: horizontalSizeClass == .compact ? .center : .trailing, spacing: 6) {
            if let cookError {
                Text(cookError)
                    .font(.footnote)
                    .foregroundStyle(RecipeTheme.warning)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Button {
                Task { await startCooking(recipe) }
            } label: {
                Label(activeSession == nil ? "Start cooking" : "Resume cooking", systemImage: activeSession == nil ? "play.fill" : "flame.fill")
                    .font(.headline)
                    .padding(.horizontal, 8)
            }
            .primaryGlassButton()
            .controlSize(.extraLarge)
            // The floating button must not cover most of a landscape iPhone at the largest text sizes.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityIdentifier("start-cooking")
        }
        .frame(maxWidth: .infinity, alignment: horizontalSizeClass == .compact ? .center : .trailing)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func startCooking(_ recipe: RecipeV1) async {
        do {
            if !ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                _ = await CookTimerNotifications.requestAuthorization()
            }
            let session = try await CookSessionStore.shared.createSession(
                for: recipe,
                servings: selectedServings,
                unitSystem: units
            )
            cookError = nil
            await CookActivityController.startOrUpdate(session: session)
            router.activeCookSession = .init(id: session.id)
        } catch {
            cookError = error.localizedDescription
        }
    }
}

private struct RecipeSourceView: View {
    let record: RecipeRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !record.sourceURL.isEmpty, let url = URL(string: record.sourceURL) {
                        Link(destination: url) {
                            Label(record.sourceTitle.isEmpty ? url.host() ?? "Recipe source" : record.sourceTitle, systemImage: "safari")
                                .font(.headline)
                        }
                    } else if !record.sourceTitle.isEmpty {
                        Text(record.sourceTitle).font(.headline)
                    }
                    if record.sourceCleanedText.isEmpty {
                        ContentUnavailableView("No source text saved", systemImage: "doc.text")
                    } else {
                        Text(record.sourceCleanedText)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding()
            }
            .navigationTitle("Recipe source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .editorialSurface()
    }
}
