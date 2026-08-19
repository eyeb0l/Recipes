import Foundation

public struct TimelineStagePlacement: Codable, Hashable, Identifiable, Sendable {
    public var id: String { stageID }
    public let stageID: String
    public let column: Int
    public let subcolumn: Int
    public let subcolumnCount: Int
    public let startRow: Int?
    public let endRow: Int?
    public let ingredientLineage: [String]

    public var isGlobal: Bool { startRow == nil }
}

public struct TimelineLayout: Codable, Hashable, Sendable {
    public let placements: [TimelineStagePlacement]
    public let rowCount: Int
    public let columnCount: Int

    public init(placements: [TimelineStagePlacement], rowCount: Int, columnCount: Int) {
        self.placements = placements
        self.rowCount = rowCount
        self.columnCount = columnCount
    }
}

public enum TimelineLayoutError: Error, LocalizedError {
    case invalidRecipe([RecipeValidationIssue])

    public var errorDescription: String? {
        switch self {
        case let .invalidRecipe(issues):
            issues.map(\.message).joined(separator: " ")
        }
    }
}

public enum TimelineLayoutEngine {
    private struct DraftPlacement {
        let stageID: String
        let column: Int
        var subcolumn: Int
        var subcolumnCount: Int
        let startRow: Int?
        let endRow: Int?
        let ingredientLineage: [String]
    }

    public static func makeLayout(for recipe: RecipeV1) throws -> TimelineLayout {
        let validation = RecipeValidator.validate(recipe)
        let blocking = validation.issues.filter { $0.severity == .error }
        guard blocking.isEmpty else { throw TimelineLayoutError.invalidRecipe(blocking) }

        let ingredients = recipe.sortedIngredients
        let rowByIngredient = Dictionary(uniqueKeysWithValues: ingredients.enumerated().map { ($0.element.id, $0.offset) })
        let stages = recipe.sortedStages
        let stageByID = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, $0) })

        var ranks: [String: Int] = [:]
        func rank(for stageID: String) -> Int {
            if let existing = ranks[stageID] { return existing }
            let value = (stageByID[stageID]?.dependencies.map { rank(for: $0) }.max() ?? -1) + 1
            ranks[stageID] = value
            return value
        }
        for stage in stages { _ = rank(for: stage.id) }

        let ordered = stages.sorted {
            let lhs = (ranks[$0.id] ?? 0, $0.sortIndex, $0.id)
            let rhs = (ranks[$1.id] ?? 0, $1.sortIndex, $1.id)
            return lhs < rhs
        }
        var lineageByStage: [String: Set<String>] = [:]
        var drafts: [DraftPlacement] = []

        for stage in ordered {
            var lineage = Set(stage.ingredientUses.map(\.ingredientID))
            for dependency in stage.dependencies {
                lineage.formUnion(lineageByStage[dependency] ?? [])
            }
            lineageByStage[stage.id] = lineage
            let rows = lineage.compactMap { rowByIngredient[$0] }.sorted()
            drafts.append(.init(
                stageID: stage.id,
                column: ranks[stage.id] ?? 0,
                subcolumn: 0,
                subcolumnCount: 1,
                startRow: rows.first,
                endRow: rows.last,
                ingredientLineage: lineage.sorted { (rowByIngredient[$0] ?? .max) < (rowByIngredient[$1] ?? .max) }
            ))
        }

        let columns = Dictionary(grouping: drafts.indices, by: { drafts[$0].column })
        for indices in columns.values {
            let nonGlobal = indices.filter { drafts[$0].startRow != nil }.sorted {
                let lhs = (drafts[$0].startRow ?? -1, drafts[$0].endRow ?? -1, drafts[$0].stageID)
                let rhs = (drafts[$1].startRow ?? -1, drafts[$1].endRow ?? -1, drafts[$1].stageID)
                return lhs < rhs
            }

            // Lane counts belong to a connected group of overlapping row intervals, not
            // to the entire topological column. A collision near the top of a recipe
            // should not squeeze a later, non-overlapping stage into the same narrow lanes.
            var components: [[Int]] = []
            var componentMaximumEnd: Int?
            for index in nonGlobal {
                let start = drafts[index].startRow ?? 0
                let end = drafts[index].endRow ?? start
                if let maximumEnd = componentMaximumEnd, start <= maximumEnd {
                    components[components.count - 1].append(index)
                    componentMaximumEnd = max(maximumEnd, end)
                } else {
                    components.append([index])
                    componentMaximumEnd = end
                }
            }

            for component in components {
                var occupiedEnds: [Int] = []
                for index in component {
                    let start = drafts[index].startRow ?? 0
                    let end = drafts[index].endRow ?? start
                    let slot = occupiedEnds.firstIndex(where: { $0 < start }) ?? occupiedEnds.count
                    if slot == occupiedEnds.count { occupiedEnds.append(end) } else { occupiedEnds[slot] = end }
                    drafts[index].subcolumn = slot
                }
                let count = max(occupiedEnds.count, 1)
                for index in component { drafts[index].subcolumnCount = count }
            }
        }

        let placements = drafts.map {
            TimelineStagePlacement(
                stageID: $0.stageID,
                column: $0.column,
                subcolumn: $0.subcolumn,
                subcolumnCount: $0.subcolumnCount,
                startRow: $0.startRow,
                endRow: $0.endRow,
                ingredientLineage: $0.ingredientLineage
            )
        }.sorted { ($0.column, $0.subcolumn, $0.stageID) < ($1.column, $1.subcolumn, $1.stageID) }

        return .init(
            placements: placements,
            rowCount: ingredients.count,
            columnCount: max((ranks.values.max() ?? -1) + 1, 1)
        )
    }

    public static func readyStageIDs(recipe: RecipeV1, completed: Set<String>) -> [String] {
        recipe.sortedStages.filter { stage in
            !completed.contains(stage.id) && Set(stage.dependencies).isSubset(of: completed)
        }.map(\.id)
    }
}
