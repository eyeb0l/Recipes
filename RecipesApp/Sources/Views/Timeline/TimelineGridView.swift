import RecipeCore
import SwiftUI

struct TimelineCookPresentation {
    var focusedStageID: String?
    var readyStageIDs: Set<String> = []
    var completedStageIDs: Set<String> = []
}

struct TimelineGridMetrics: Equatable {
    let ingredientWidth: CGFloat
    let rowHeight: CGFloat
    let globalSlotHeight: CGFloat
    let headerHeight: CGFloat
    let laneWidth: CGFloat
    let cardInset: CGFloat
    let minimumTimelineWidth: CGFloat
    let trailingMargin: CGFloat

    init(
        ingredientWidth: CGFloat = 274,
        rowHeight: CGFloat = 92,
        globalSlotHeight: CGFloat = 90,
        headerHeight: CGFloat = 46,
        laneWidth: CGFloat = 216,
        cardInset: CGFloat = 12,
        minimumTimelineWidth: CGFloat = 440,
        trailingMargin: CGFloat = 24
    ) {
        self.ingredientWidth = ingredientWidth
        self.rowHeight = rowHeight
        self.globalSlotHeight = globalSlotHeight
        self.headerHeight = headerHeight
        self.laneWidth = laneWidth
        self.cardInset = cardInset
        self.minimumTimelineWidth = minimumTimelineWidth
        self.trailingMargin = trailingMargin
    }
}

struct TimelineGridGeometry {
    let layout: TimelineLayout
    let metrics: TimelineGridMetrics
    let globalBandHeight: CGFloat
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let columnOffsets: [Int: CGFloat]
    let columnLaneCounts: [Int: Int]

    private let globalPlacementIndex: [String: Int]

    init(layout: TimelineLayout, metrics: TimelineGridMetrics) {
        self.layout = layout
        self.metrics = metrics

        let globals = layout.placements.filter(\.isGlobal)
        globalPlacementIndex = Dictionary(uniqueKeysWithValues: globals.enumerated().map { ($0.element.stageID, $0.offset) })
        globalBandHeight = max(metrics.globalSlotHeight, CGFloat(max(globals.count, 1)) * metrics.globalSlotHeight)

        var offsets: [Int: CGFloat] = [:]
        var laneCounts: [Int: Int] = [:]
        var runningX: CGFloat = 0
        for column in 0..<layout.columnCount {
            let laneCount = max(
                layout.placements
                    .filter { $0.column == column && !$0.isGlobal }
                    .map(\.subcolumnCount)
                    .max() ?? 1,
                1
            )
            offsets[column] = runningX
            laneCounts[column] = laneCount
            runningX += CGFloat(laneCount) * metrics.laneWidth
        }
        columnOffsets = offsets
        columnLaneCounts = laneCounts
        contentWidth = max(runningX, metrics.minimumTimelineWidth)
        contentHeight =
            metrics.headerHeight
            + globalBandHeight
            + CGFloat(max(layout.rowCount, 1)) * metrics.rowHeight
    }

    func headerFrame(for column: Int) -> CGRect {
        let x = columnOffsets[column] ?? 0
        let lanes = CGFloat(columnLaneCounts[column] ?? 1)
        return CGRect(x: x, y: 0, width: lanes * metrics.laneWidth, height: metrics.headerHeight)
    }

    func cardFrame(for placement: TimelineStagePlacement) -> CGRect {
        if placement.isGlobal {
            let count = max(globalPlacementIndex.count, 1)
            let slotHeight = globalBandHeight / CGFloat(count)
            let index = CGFloat(globalPlacementIndex[placement.stageID] ?? 0)
            return CGRect(
                x: metrics.cardInset / 2,
                y: metrics.headerHeight + index * slotHeight + metrics.cardInset / 2,
                width: contentWidth - metrics.cardInset,
                height: slotHeight - metrics.cardInset
            )
        }

        let startRow = placement.startRow ?? 0
        let rowCount = (placement.endRow ?? startRow) - startRow + 1
        let columnX = columnOffsets[placement.column] ?? 0
        return CGRect(
            x: columnX + CGFloat(placement.subcolumn) * metrics.laneWidth + metrics.cardInset / 2,
            y: metrics.headerHeight + globalBandHeight + CGFloat(startRow) * metrics.rowHeight + metrics.cardInset / 2,
            width: metrics.laneWidth - metrics.cardInset,
            height: CGFloat(rowCount) * metrics.rowHeight - metrics.cardInset
        )
    }

    func inputMarkerOffsets(for placement: TimelineStagePlacement, directRows: [Int]) -> [CGFloat] {
        guard let startRow = placement.startRow else { return [] }
        return directRows.sorted().map { row in
            CGFloat(row - startRow) * metrics.rowHeight
                + metrics.rowHeight / 2
                - metrics.cardInset / 2
        }
    }

    var majorColumnBoundaries: [CGFloat] {
        var boundaries = [CGFloat(0)]
        for column in 0..<layout.columnCount {
            boundaries.append(headerFrame(for: column).maxX)
        }
        return boundaries
    }

    var laneBoundaries: [CGFloat] {
        var boundaries: [CGFloat] = []
        for column in 0..<layout.columnCount {
            let lanes = columnLaneCounts[column] ?? 1
            guard lanes > 1 else { continue }
            let origin = columnOffsets[column] ?? 0
            for lane in 1..<lanes {
                boundaries.append(origin + CGFloat(lane) * metrics.laneWidth)
            }
        }
        return boundaries
    }
}

struct TimelineGridView: View {
    let recipe: RecipeV1
    let servings: Decimal
    let units: UnitSystemPreference
    var cookPresentation: TimelineCookPresentation?
    var onMoveStage: ((String, String) -> Void)?
    var showsFullContent = false

    @ScaledMetric(relativeTo: .body) private var ingredientWidth: CGFloat = 274
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 92
    @ScaledMetric(relativeTo: .body) private var globalSlotHeight: CGFloat = 90
    @ScaledMetric(relativeTo: .caption) private var headerHeight: CGFloat = 46
    @ScaledMetric(relativeTo: .body) private var laneWidth: CGFloat = 216
    @ScaledMetric(relativeTo: .body) private var cardInset: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var quantityWidth: CGFloat = 76

    var body: some View {
        let layout = try? TimelineLayoutEngine.makeLayout(for: recipe)
        if let layout {
            let metrics = TimelineGridMetrics(
                ingredientWidth: ingredientWidth,
                rowHeight: rowHeight,
                globalSlotHeight: globalSlotHeight,
                headerHeight: headerHeight,
                laneWidth: laneWidth,
                cardInset: cardInset
            )
            let geometry = TimelineGridGeometry(layout: layout, metrics: metrics)
            grid(layout: layout, geometry: geometry)
        } else {
            ContentUnavailableView(
                "Timeline unavailable", systemImage: "exclamationmark.triangle", description: Text("Open the editor and check which stages must follow others."))
        }
    }

    @ViewBuilder
    private func grid(layout: TimelineLayout, geometry: TimelineGridGeometry) -> some View {
        if showsFullContent {
            HStack(alignment: .top, spacing: 0) {
                ingredientColumn(geometry: geometry)
                timelineDivider(height: geometry.contentHeight)
                timelineContent(layout: layout, geometry: geometry)
            }
            .padding(.trailing, geometry.metrics.trailingMargin)
            .background(RecipeTheme.surface)
            .overlay { Rectangle().stroke(RecipeTheme.grid.opacity(0.8), lineWidth: 1) }
        } else {
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    ingredientColumn(geometry: geometry)
                    timelineDivider(height: geometry.contentHeight)
                    ScrollView(.horizontal) {
                        timelineContent(layout: layout, geometry: geometry)
                    }
                    .contentMargins(.trailing, geometry.metrics.trailingMargin, for: .scrollContent)
                    .scrollIndicators(.visible)
                }
            }
            .background(RecipeTheme.surface)
            .overlay { Rectangle().stroke(RecipeTheme.grid.opacity(0.8), lineWidth: 1) }
        }
    }

    private func timelineDivider(height: CGFloat) -> some View {
        Rectangle()
            .fill(RecipeTheme.grid)
            .frame(width: 1, height: height)
    }

    private func ingredientColumn(geometry: TimelineGridGeometry) -> some View {
        let metrics = geometry.metrics
        return VStack(spacing: 0) {
            Text("INGREDIENTS")
                .font(.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(RecipeTheme.secondaryInk)
                .padding(.horizontal, 16)
                .frame(width: metrics.ingredientWidth, height: metrics.headerHeight, alignment: .leading)
                .background(RecipeTheme.paper)
            Text("PREP & WHOLE RECIPE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RecipeTheme.secondaryInk)
                .padding(.horizontal, 16)
                .frame(width: metrics.ingredientWidth, height: geometry.globalBandHeight, alignment: .leading)
                .background(RecipeTheme.paper.opacity(0.7))
                .overlay(alignment: .bottom) { Rectangle().fill(RecipeTheme.grid).frame(height: 1) }
            ForEach(recipe.sortedIngredients) { ingredient in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(
                        ingredient.displayQuantity(
                            servings: servings,
                            originalServings: recipe.recipeYield.servings,
                            units: units
                        ) ?? "—"
                    )
                    .font(.body.monospacedDigit().weight(.semibold))
                    .frame(width: quantityWidth, alignment: .trailing)
                    Text(ingredient.name)
                        .font(.body)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(width: metrics.ingredientWidth, height: metrics.rowHeight, alignment: .leading)
                .background(RecipeTheme.surface)
                .overlay(alignment: .bottom) { Rectangle().fill(RecipeTheme.gridSubtle).frame(height: 0.75) }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(width: metrics.ingredientWidth)
    }

    private func timelineContent(layout: TimelineLayout, geometry: TimelineGridGeometry) -> some View {
        let metrics = geometry.metrics
        let stages = Dictionary(uniqueKeysWithValues: recipe.stages.map { ($0.id, $0) })
        let rowByIngredient = Dictionary(uniqueKeysWithValues: recipe.sortedIngredients.enumerated().map { ($0.element.id, $0.offset) })
        let warningStageIDs = Set(recipe.uncertainties.filter { !$0.isResolved }.flatMap(\.stageIDs))

        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                var subtleRules = Path()
                if layout.rowCount > 0 {
                    for row in 1...layout.rowCount {
                        let y = metrics.headerHeight + geometry.globalBandHeight + CGFloat(row) * metrics.rowHeight
                        subtleRules.move(to: CGPoint(x: 0, y: y))
                        subtleRules.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }
                for x in geometry.laneBoundaries {
                    subtleRules.move(to: CGPoint(x: x, y: 0))
                    subtleRules.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(subtleRules, with: .color(RecipeTheme.gridSubtle), lineWidth: 0.75)

                var columnRules = Path()
                for x in geometry.majorColumnBoundaries {
                    columnRules.move(to: CGPoint(x: x, y: 0))
                    columnRules.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(columnRules, with: .color(RecipeTheme.grid.opacity(0.62)), lineWidth: 0.8)

                var majorRules = Path()
                majorRules.move(to: CGPoint(x: 0, y: metrics.headerHeight))
                majorRules.addLine(to: CGPoint(x: size.width, y: metrics.headerHeight))
                majorRules.move(to: CGPoint(x: 0, y: metrics.headerHeight + geometry.globalBandHeight))
                majorRules.addLine(to: CGPoint(x: size.width, y: metrics.headerHeight + geometry.globalBandHeight))
                context.stroke(majorRules, with: .color(RecipeTheme.grid.opacity(0.88)), lineWidth: 1)
            }

            ForEach(0..<layout.columnCount, id: \.self) { column in
                let frame = geometry.headerFrame(for: column)
                Text("STAGE \(column + 1)")
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(RecipeTheme.secondaryInk)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }

            ForEach(layout.placements) { placement in
                if let stage = stages[placement.stageID] {
                    let frame = geometry.cardFrame(for: placement)
                    let directRows = Array(Set(stage.ingredientUses.compactMap { rowByIngredient[$0.ingredientID] })).sorted()
                    TimelineStageCard(
                        stage: stage,
                        units: units,
                        warning: warningStageIDs.contains(stage.id),
                        isFocused: cookPresentation?.focusedStageID == stage.id,
                        isReady: cookPresentation?.readyStageIDs.contains(stage.id) == true,
                        isCompleted: cookPresentation?.completedStageIDs.contains(stage.id) == true,
                        showsLineageRail: !placement.ingredientLineage.isEmpty,
                        inputMarkerOffsets: geometry.inputMarkerOffsets(for: placement, directRows: directRows)
                    )
                    .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                    .offset(x: frame.minX, y: frame.minY)
                    .accessibilityIdentifier("timeline-stage-\(stage.id)")
                    .draggable(stage.id) {
                        Text(stage.action)
                            .font(.headline)
                            .padding()
                            .background(RecipeTheme.timelineStage, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let source = items.first, source != stage.id else { return false }
                        onMoveStage?(source, stage.id)
                        return onMoveStage != nil
                    }
                }
            }
        }
        .frame(width: geometry.contentWidth, height: geometry.contentHeight)
        .background(RecipeTheme.surface)
    }
}

private struct TimelineStageCard: View {
    let stage: Stage
    let units: UnitSystemPreference
    let warning: Bool
    let isFocused: Bool
    let isReady: Bool
    let isCompleted: Bool
    let showsLineageRail: Bool
    let inputMarkerOffsets: [CGFloat]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                Text(stage.action)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 3)
                if warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(RecipeTheme.warning)
                        .accessibilityLabel("Source warning")
                }
            }
            if stageDetail != nil || stage.duration != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 8) {
                        stageDetailText(lineLimit: 2)
                        if stageDetail != nil, stage.duration != nil {
                            Spacer(minLength: 2)
                        }
                        durationBadge
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        stageDetailText(lineLimit: 3)
                        durationBadge
                    }
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: isFocused ? 3 : (isReady ? 2 : 1))
        }
        .overlay(alignment: .leading) {
            if showsLineageRail {
                lineageRail
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(isCompleted ? 0.32 : 1)
        .animation(.easeInOut(duration: 0.2), value: isCompleted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var lineageRail: some View {
        Canvas { context, size in
            let x: CGFloat = 2.5
            var rail = Path()
            rail.move(to: CGPoint(x: x, y: 8))
            rail.addLine(to: CGPoint(x: x, y: max(8, size.height - 8)))
            context.stroke(rail, with: .color(RecipeTheme.focus.opacity(isFocused ? 0.9 : 0.5)), lineWidth: 3)

            for marker in inputMarkerOffsets {
                let y = min(max(marker, 7), max(7, size.height - 7))
                let dot = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: dot), with: .color(RecipeTheme.focus))
            }
        }
        .frame(width: 9)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var borderColor: Color {
        isFocused || isReady ? RecipeTheme.focus : RecipeTheme.timelineStageBorder
    }

    private var background: Color {
        if isFocused { return RecipeTheme.focus.opacity(0.3) }
        if isReady { return RecipeTheme.focus.opacity(0.16) }
        return stage.sortIndex.isMultiple(of: 2) ? RecipeTheme.timelineStage : RecipeTheme.timelineStageAlternate
    }

    private var stageDetail: String? {
        if let temperature = stage.temperature { return temperature.converted(for: units).displayString() }
        return stage.heat.map { "\($0.capitalized) heat" } ?? stage.completionCue
    }

    @ViewBuilder
    private func stageDetailText(lineLimit: Int) -> some View {
        if let stageDetail {
            Text(stageDetail)
                .font(.subheadline)
                .foregroundStyle(RecipeTheme.secondaryInk)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var durationBadge: some View {
        if let duration = stage.duration {
            Label(durationLabel(duration), systemImage: "timer")
                .font(.footnote.monospacedDigit().weight(.medium))
                .foregroundStyle(isFocused ? RecipeTheme.ink : RecipeTheme.secondaryInk)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RecipeTheme.surface.opacity(0.68), in: Capsule())
                .fixedSize()
        }
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
        if warning { parts.append("Contains a source warning") }
        if isFocused { parts.append("Current stage") }
        if isCompleted { parts.append("Completed") }
        return parts.joined(separator: ". ")
    }
}
