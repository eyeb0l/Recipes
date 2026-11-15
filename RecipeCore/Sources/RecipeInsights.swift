import Foundation

public extension RecipeV1 {
    /// The shortest time the stage graph needs when independent workstreams run in parallel.
    ///
    /// Uses each stage's minimum duration (or its longest timer when no duration is given) along the
    /// critical path. Returns `nil` when no stage carries timing, so the app never invents a total.
    var estimatedTotalSeconds: Int? {
        let stagesByID = Dictionary(stages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stageSeconds = stagesByID.mapValues { stage -> Int? in
            if let duration = stage.duration { return max(0, duration.minimumSeconds) }
            return stage.timers.map(\.durationSeconds).max()
        }
        guard stageSeconds.values.contains(where: { ($0 ?? 0) > 0 }) else { return nil }

        var finish: [String: Int] = [:]
        var visiting: Set<String> = []
        func finishTime(_ id: String) -> Int {
            if let known = finish[id] { return known }
            // A cycle is a validation error; treat the back edge as contributing nothing.
            guard stagesByID[id] != nil, visiting.insert(id).inserted else { return 0 }
            let start = stagesByID[id]!.dependencies.map(finishTime).max() ?? 0
            visiting.remove(id)
            let value = start + ((stageSeconds[id] ?? nil) ?? 0)
            finish[id] = value
            return value
        }
        return stagesByID.keys.map(finishTime).max()
    }

    /// Removes an ingredient and every reference to it so the recipe stays valid.
    mutating func removeIngredient(id: String) {
        ingredients.removeAll { $0.id == id }
        for index in ingredients.indices { ingredients[index].sortIndex = index }
        for index in stages.indices { stages[index].ingredientUses.removeAll { $0.ingredientID == id } }
        for index in prepTasks.indices { prepTasks[index].ingredientIDs.removeAll { $0 == id } }
        for index in uncertainties.indices { uncertainties[index].ingredientIDs.removeAll { $0 == id } }
    }

    /// Removes a stage, reconnecting the stages that followed it to the stages it depended on.
    mutating func removeStage(id: String) {
        guard let removed = stages.first(where: { $0.id == id }) else { return }
        stages.removeAll { $0.id == id }
        for index in stages.indices where stages[index].dependencies.contains(id) {
            let inherited = removed.dependencies.filter { $0 != stages[index].id }
            stages[index].dependencies = Array(Set(stages[index].dependencies.filter { $0 != id } + inherited)).sorted()
        }
        for (offset, stage) in sortedStages.enumerated() {
            if let index = stages.firstIndex(where: { $0.id == stage.id }) { stages[index].sortIndex = offset }
        }
        for index in uncertainties.indices { uncertainties[index].stageIDs.removeAll { $0 == id } }
    }
}

public enum RecipeDurationFormatter {
    /// A compact, human cooking duration such as "45 min" or "1 hr 20 min".
    public static func string(seconds: Int) -> String {
        let minutes = Int((Double(max(0, seconds)) / 60).rounded(.up))
        guard minutes >= 60 else { return "\(max(minutes, 1)) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }
}
