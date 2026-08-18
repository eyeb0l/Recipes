import RecipeCore
import SwiftUI

struct TimelineCookPresentation {
    var focusedStageID: String?
    var readyStageIDs: Set<String> = []
    var completedStageIDs: Set<String> = []
}

struct TimelineGridView: View {
    let recipe: RecipeV1
    let servings: Decimal
    let units: UnitSystemPreference
    var cookPresentation: TimelineCookPresentation?
    var onMoveStage: ((String, String) -> Void)?

    private let ingredientWidth: CGFloat = 290
    private let rowHeight: CGFloat = 78
    private let globalHeight: CGFloat = 88
    private let headerHeight: CGFloat = 42
    private let columnWidth: CGFloat = 196

    var body: some View {
        let layout = try? TimelineLayoutEngine.makeLayout(for: recipe)
        if let layout {
            let globalCount = layout.placements.filter(\.isGlobal).count
            let globalBandHeight = max(globalHeight, CGFloat(max(globalCount, 1)) * 68)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    ingredientColumn(globalBandHeight: globalBandHeight)
                    Divider().overlay(RecipeTheme.grid)
                    ScrollView(.horizontal) {
                        timelineContent(layout: layout, globalBandHeight: globalBandHeight)
                    }
                    .scrollIndicators(.visible)
                }
            }
            .background(RecipeTheme.surface)
            .overlay { Rectangle().stroke(RecipeTheme.grid, lineWidth: 1) }
        } else {
            ContentUnavailableView("Timeline unavailable", systemImage: "exclamationmark.triangle", description: Text("Resolve invalid stage dependencies in the editor."))
        }
    }

    private func ingredientColumn(globalBandHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text("INGREDIENTS")
                .font(.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(RecipeTheme.secondaryInk)
                .frame(maxWidth: .infinity, minHeight: headerHeight, alignment: .leading)
                .padding(.horizontal, 16)
                .background(RecipeTheme.paper)
            Text("PREP & GLOBAL")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(RecipeTheme.secondaryInk)
                .frame(maxWidth: .infinity, minHeight: globalBandHeight, alignment: .leading)
                .padding(.horizontal, 16)
                .background(RecipeTheme.paper.opacity(0.7))
                .overlay(alignment: .bottom) { Divider().overlay(RecipeTheme.grid) }
            ForEach(recipe.sortedIngredients) { ingredient in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(ingredient.displayQuantity(
                        servings: servings,
                        originalServings: recipe.recipeYield.servings,
                        units: units
                    ) ?? "—")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .frame(width: 82, alignment: .trailing)
                    Text(ingredient.name)
                        .font(.body)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(width: ingredientWidth, height: rowHeight, alignment: .leading)
                .background(RecipeTheme.surface)
                .overlay(alignment: .bottom) { Divider().overlay(RecipeTheme.grid) }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(width: ingredientWidth)
    }

    private func timelineContent(layout: TimelineLayout, globalBandHeight: CGFloat) -> some View {
        let width = max(CGFloat(layout.columnCount) * columnWidth, 440)
        let height = headerHeight + globalBandHeight + CGFloat(max(layout.rowCount, 1)) * rowHeight
        let stages = Dictionary(uniqueKeysWithValues: recipe.stages.map { ($0.id, $0) })
        let warningStageIDs = Set(recipe.uncertainties.filter { !$0.isResolved }.flatMap(\.stageIDs))
        let globalPlacements = layout.placements.filter(\.isGlobal)
        let globalIndex = Dictionary(uniqueKeysWithValues: globalPlacements.enumerated().map { ($0.element.stageID, $0.offset) })

        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: headerHeight))
                path.addLine(to: CGPoint(x: size.width, y: headerHeight))
                path.move(to: CGPoint(x: 0, y: headerHeight + globalBandHeight))
                path.addLine(to: CGPoint(x: size.width, y: headerHeight + globalBandHeight))
                for row in 0...layout.rowCount {
                    let y = headerHeight + globalBandHeight + CGFloat(row) * rowHeight
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                for column in 0...layout.columnCount {
                    let x = CGFloat(column) * columnWidth
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(path, with: .color(RecipeTheme.grid), lineWidth: 1)
            }

            ForEach(0..<layout.columnCount, id: \.self) { column in
                Text("STAGE \(column + 1)")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(RecipeTheme.secondaryInk)
                    .frame(width: columnWidth, height: headerHeight)
                    .position(x: CGFloat(column) * columnWidth + columnWidth / 2, y: headerHeight / 2)
            }

            ForEach(layout.placements) { placement in
                if let stage = stages[placement.stageID] {
                    TimelineStageCard(
                        stage: stage,
                        warning: warningStageIDs.contains(stage.id),
                        isFocused: cookPresentation?.focusedStageID == stage.id,
                        isReady: cookPresentation?.readyStageIDs.contains(stage.id) == true,
                        isCompleted: cookPresentation?.completedStageIDs.contains(stage.id) == true
                    )
                    .frame(
                        width: placement.isGlobal ? width - 8 : cardWidth(placement),
                        height: cardHeight(
                            placement,
                            globalCount: globalPlacements.count,
                            globalBandHeight: globalBandHeight
                        )
                    )
                    .position(
                        x: placement.isGlobal ? width / 2 : cardX(placement),
                        y: cardY(
                            placement,
                            globalIndex: globalIndex[placement.stageID] ?? 0,
                            globalCount: globalPlacements.count,
                            globalBandHeight: globalBandHeight
                        )
                    )
                    .draggable(stage.id) {
                        Text(stage.action)
                            .font(.headline)
                            .padding()
                            .background(RecipeTheme.stage, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let source = items.first, source != stage.id else { return false }
                        onMoveStage?(source, stage.id)
                        return onMoveStage != nil
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .background(RecipeTheme.surface)
    }

    private func cardWidth(_ placement: TimelineStagePlacement) -> CGFloat {
        columnWidth / CGFloat(max(placement.subcolumnCount, 1)) - 8
    }

    private func cardHeight(
        _ placement: TimelineStagePlacement,
        globalCount: Int,
        globalBandHeight: CGFloat
    ) -> CGFloat {
        if placement.isGlobal { return globalBandHeight / CGFloat(max(globalCount, 1)) - 8 }
        return CGFloat((placement.endRow ?? 0) - (placement.startRow ?? 0) + 1) * rowHeight - 10
    }

    private func cardX(_ placement: TimelineStagePlacement) -> CGFloat {
        let slotWidth = columnWidth / CGFloat(max(placement.subcolumnCount, 1))
        return CGFloat(placement.column) * columnWidth + CGFloat(placement.subcolumn) * slotWidth + slotWidth / 2
    }

    private func cardY(
        _ placement: TimelineStagePlacement,
        globalIndex: Int,
        globalCount: Int,
        globalBandHeight: CGFloat
    ) -> CGFloat {
        if placement.isGlobal {
            let slotHeight = globalBandHeight / CGFloat(max(globalCount, 1))
            return headerHeight + CGFloat(globalIndex) * slotHeight + slotHeight / 2
        }
        let start = CGFloat(placement.startRow ?? 0)
        let rows = CGFloat((placement.endRow ?? 0) - (placement.startRow ?? 0) + 1)
        return headerHeight + globalBandHeight + start * rowHeight + rows * rowHeight / 2
    }
}

private struct TimelineStageCard: View {
    let stage: Stage
    let warning: Bool
    let isFocused: Bool
    let isReady: Bool
    let isCompleted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(stage.action)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 3)
                if warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(RecipeTheme.warning)
                        .accessibilityLabel("Uncertainty")
                }
            }
            if let detail = stageDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(RecipeTheme.secondaryInk)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            if let duration = stage.duration {
                Label(durationLabel(duration), systemImage: "timer")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isFocused ? RecipeTheme.ink : RecipeTheme.secondaryInk)
            }
        }
        .padding(10)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused || isReady ? RecipeTheme.focus : RecipeTheme.grid, lineWidth: isFocused ? 3 : 1)
        }
        .opacity(isCompleted ? 0.32 : 1)
        .animation(.easeInOut(duration: 0.2), value: isCompleted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var background: Color {
        if isFocused { return RecipeTheme.focus.opacity(0.28) }
        if isReady { return RecipeTheme.focus.opacity(0.14) }
        return stage.sortIndex.isMultiple(of: 2) ? RecipeTheme.stage : RecipeTheme.stageAlternate
    }

    private var stageDetail: String? {
        if let temperature = stage.temperature { return temperature.displayString() }
        return stage.heat.map { "\($0.capitalized) heat" } ?? stage.completionCue
    }

    private func durationLabel(_ duration: StageDuration) -> String {
        let low = duration.minimumSeconds / 60
        if let maximum = duration.maximumSeconds, maximum != duration.minimumSeconds {
            return "\(low)–\(maximum / 60) min"
        }
        return low < 1 ? "\(duration.minimumSeconds) sec" : "\(low) min"
    }

    private var accessibilityLabel: String {
        var parts = [stage.action, stage.instruction]
        if warning { parts.append("Contains an uncertainty") }
        if isFocused { parts.append("Current stage") }
        if isCompleted { parts.append("Completed") }
        return parts.joined(separator: ". ")
    }
}
