import RecipeCore
import SwiftData
import SwiftUI

struct RecipeDetailView: View {
    private enum DetailSheet: String, Identifiable {
        case editor
        case source
        var id: String { rawValue }
    }

    let record: RecipeRecord
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var recipe: RecipeV1?
    @State private var servings = 1.0
    @State private var units: UnitSystemPreference = .metric
    @State private var presentedSheet: DetailSheet?
    @State private var cookError: String?

    var body: some View {
        Group {
            if let recipe {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        recipeHeader(recipe)
                        prepSection(recipe)
                        uncertaintySection(recipe)
                        if horizontalSizeClass == .compact {
                            FocusedStepList(recipe: recipe)
                                .padding(.horizontal)
                        } else {
                            TimelineGridView(
                                recipe: recipe,
                                servings: Decimal(servings),
                                units: units
                            )
                            .frame(minHeight: 520)
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical, 22)
                }
                .safeAreaInset(edge: .bottom) {
                    startCookingBar(recipe)
                }
            } else {
                ContentUnavailableView("Recipe unavailable", systemImage: "exclamationmark.triangle", description: Text("The saved canonical recipe could not be decoded."))
            }
        }
        .background(RecipeTheme.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Source", systemImage: "doc.text.magnifyingglass") { presentedSheet = .source }
                Button("Edit", systemImage: "slider.horizontal.3") { presentedSheet = .editor }
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .editor:
                RecipeEditorView(record: record) { updated in
                    recipe = updated
                    servings = NSDecimalNumber(decimal: updated.recipeYield.servings).doubleValue
                }
            case .source:
                RecipeSourceView(record: record)
            }
        }
        .task(id: record.updatedAt) {
            recipe = try? record.recipe()
            if let recipe, servings == 1 {
                servings = NSDecimalNumber(decimal: recipe.recipeYield.servings).doubleValue
            }
        }
    }

    private func recipeHeader(_ recipe: RecipeV1) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(recipe.title)
                        .font(.system(.largeTitle, design: .serif, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    if let summary = recipe.summary {
                        Text(summary)
                            .font(.title3)
                            .foregroundStyle(RecipeTheme.secondaryInk)
                    }
                }
                Spacer()
            }
            HStack(spacing: 18) {
                Stepper(value: $servings, in: 1...100, step: 1) {
                    LabeledContent("Servings", value: servings.formatted(.number.precision(.fractionLength(0...1))))
                        .frame(minWidth: 145)
                }
                .fixedSize()
                Picker("Units", selection: $units) {
                    Text("Source").tag(UnitSystemPreference.source)
                    Text("Metric").tag(UnitSystemPreference.metric)
                    Text("Imperial").tag(UnitSystemPreference.imperial)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func prepSection(_ recipe: RecipeV1) -> some View {
        if !recipe.prepTasks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Prep checklist")
                    .font(.title2.weight(.semibold))
                ForEach(recipe.prepTasks.sorted { $0.sortIndex < $1.sortIndex }) { task in
                    Label(task.instruction, systemImage: task.isOptional ? "circle.dashed" : "circle")
                        .foregroundStyle(RecipeTheme.ink)
                }
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
                        Text(warning.message)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("\(unresolved.count) source uncertaint\(unresolved.count == 1 ? "y" : "ies")", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(RecipeTheme.warning)
            }
            .padding()
            .background(RecipeTheme.warning.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }

    private func startCookingBar(_ recipe: RecipeV1) -> some View {
        VStack(spacing: 4) {
            if let cookError {
                Text(cookError).font(.footnote).foregroundStyle(RecipeTheme.warning)
            }
            Button {
                Task { await startCooking(recipe) }
            } label: {
                Label("Start cooking", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: 420)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("start-cooking")
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial)
    }

    private func startCooking(_ recipe: RecipeV1) async {
        do {
            _ = await CookTimerNotifications.requestAuthorization()
            let session = try await CookSessionStore.shared.createSession(for: recipe)
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
                        Link(destination: url) { Label(record.sourceTitle.isEmpty ? url.host() ?? "Recipe source" : record.sourceTitle, systemImage: "link") }
                    } else if !record.sourceTitle.isEmpty {
                        Text(record.sourceTitle).font(.headline)
                    }
                    if record.sourceCleanedText.isEmpty {
                        ContentUnavailableView("No source text retained", systemImage: "doc.text")
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .editorialSurface()
    }
}
