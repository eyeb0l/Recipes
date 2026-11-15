import Foundation

public enum CookTimerStatus: String, Codable, Sendable {
    case running
    case paused
    case finished
    case cancelled
}

public struct CookTimerState: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var stageID: String
    public var label: String
    public var durationSeconds: Int
    public var startedAt: Date?
    public var endDate: Date?
    public var remainingSeconds: Int
    public var status: CookTimerStatus

    public init(
        id: String,
        stageID: String,
        label: String,
        durationSeconds: Int,
        startedAt: Date? = nil,
        endDate: Date? = nil,
        remainingSeconds: Int? = nil,
        status: CookTimerStatus = .paused
    ) {
        self.id = id
        self.stageID = stageID
        self.label = label
        self.durationSeconds = durationSeconds
        self.startedAt = startedAt
        self.endDate = endDate
        self.remainingSeconds = remainingSeconds ?? durationSeconds
        self.status = status
    }

    public func secondsRemaining(at date: Date = Date()) -> Int {
        if status == .running, let endDate {
            return max(0, Int(endDate.timeIntervalSince(date).rounded(.up)))
        }
        return max(0, remainingSeconds)
    }
}

/// An ingredient as it was when cooking started, so later recipe edits can't change a cook in progress.
public struct CookIngredientSnapshot: Codable, Hashable, Sendable {
    public var name: String
    public var quantity: CulinaryQuantity?
    public var scalable: Bool

    public init(name: String, quantity: CulinaryQuantity?, scalable: Bool) {
        self.name = name
        self.quantity = quantity
        self.scalable = scalable
    }
}

public struct CookStageSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var action: String
    public var instruction: String
    public var completionCue: String?
    public var dependencies: [String]
    public var ingredientNames: [String]
    /// Amounts added at this stage. `nil` for sessions saved by earlier builds, which kept names only.
    public var ingredients: [CookIngredientSnapshot]?
    public var timers: [StageTimer]
    public var heat: String?
    public var temperature: CookingTemperature?
    public var sortIndex: Int

    public init(stage: Stage, ingredients: [String: Ingredient]) {
        id = stage.id
        action = stage.action
        instruction = stage.instruction
        completionCue = stage.completionCue
        dependencies = stage.dependencies
        ingredientNames = stage.ingredientUses.compactMap { ingredients[$0.ingredientID]?.name }
        self.ingredients = stage.ingredientUses.compactMap { use in
            guard let ingredient = ingredients[use.ingredientID] else { return nil }
            return .init(name: ingredient.name, quantity: use.quantity ?? ingredient.quantity, scalable: ingredient.scalable)
        }
        timers = stage.timers
        heat = stage.heat
        temperature = stage.temperature
        sortIndex = stage.sortIndex
    }
}

public struct CookSession: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var recipeID: String
    public var recipeTitle: String
    public var stages: [CookStageSnapshot]
    public var prepTaskIDs: [String]
    public var completedPrepTaskIDs: Set<String>
    public var completedStageIDs: Set<String>
    public var focusedStageID: String?
    public var timers: [CookTimerState]
    public var startedAt: Date
    public var updatedAt: Date
    public var endedAt: Date?
    /// The serving count chosen when cooking started. `nil` for sessions saved by earlier builds.
    public var servings: Decimal?
    /// The display units chosen when cooking started. `nil` for sessions saved by earlier builds.
    public var unitSystem: UnitSystemPreference?
    /// The recipe's own serving count when cooking started; the base for scaling snapshot amounts.
    public var baseServings: Decimal?

    public init(
        recipe: RecipeV1,
        servings: Decimal? = nil,
        unitSystem: UnitSystemPreference? = nil,
        date: Date = Date()
    ) {
        let ingredientMap = Dictionary(uniqueKeysWithValues: recipe.ingredients.map { ($0.id, $0) })
        id = UUID().uuidString
        recipeID = recipe.id
        recipeTitle = recipe.title
        stages = recipe.sortedStages.map { CookStageSnapshot(stage: $0, ingredients: ingredientMap) }
        prepTaskIDs = recipe.prepTasks.sorted { $0.sortIndex < $1.sortIndex }.map(\.id)
        completedPrepTaskIDs = []
        completedStageIDs = []
        focusedStageID = stages.first(where: { $0.dependencies.isEmpty })?.id
        timers = []
        startedAt = date
        updatedAt = date
        endedAt = nil
        self.servings = servings
        self.unitSystem = unitSystem
        baseServings = recipe.recipeYield.servings
    }

    /// What to add at a stage, scaled to the session's servings and units, from the snapshot taken
    /// when cooking started. Sessions from earlier builds fall back to ingredient names.
    public func ingredientLines(for stage: CookStageSnapshot) -> [String] {
        guard let ingredients = stage.ingredients else { return stage.ingredientNames }
        let base = baseServings ?? 0
        let factor = base > 0 ? (servings ?? base) / base : 1
        let units = unitSystem ?? .source
        return ingredients.map { ingredient in
            let amount = ingredient.quantity?
                .scaled(by: factor, enabled: ingredient.scalable)
                .converted(for: units)
                .displayString()
            return [amount, ingredient.name].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// The share of stages finished, from 0 to 1.
    public var progress: Double {
        stages.isEmpty ? 0 : Double(completedStageIDs.count) / Double(stages.count)
    }

    public var isComplete: Bool {
        completedStageIDs.count == stages.count && !stages.isEmpty
    }

    public var readyStageIDs: [String] {
        stages.sorted { ($0.sortIndex, $0.id) < ($1.sortIndex, $1.id) }.filter {
            !completedStageIDs.contains($0.id) && Set($0.dependencies).isSubset(of: completedStageIDs)
        }.map(\.id)
    }

    public var focusedStage: CookStageSnapshot? {
        guard let focusedStageID else { return nil }
        return stages.first { $0.id == focusedStageID }
    }

    public func nearestRunningTimer(at date: Date = Date()) -> CookTimerState? {
        timers.filter { $0.status == .running && ($0.endDate ?? .distantFuture) > date }
            .min { ($0.endDate ?? .distantFuture) < ($1.endDate ?? .distantFuture) }
    }

    public var runningTimerCount: Int {
        timers.filter { $0.status == .running }.count
    }
}

public actor CookSessionStore {
    public static let shared = CookSessionStore()

    private let fileURL: URL
    private var sessions: [String: CookSession]?

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    public func createSession(
        for recipe: RecipeV1,
        servings: Decimal? = nil,
        unitSystem: UnitSystemPreference? = nil,
        date: Date = Date()
    ) throws -> CookSession {
        var all = try loadIfNeeded()
        if var existing = all.values.first(where: { $0.recipeID == recipe.id && $0.endedAt == nil }) {
            // Resuming keeps progress, but follows the servings and units the cook chose this time.
            guard existing.servings != servings || existing.unitSystem != unitSystem else { return existing }
            existing.servings = servings
            existing.unitSystem = unitSystem
            existing.updatedAt = date
            all[existing.id] = existing
            try persist(all)
            return existing
        }
        let session = CookSession(recipe: recipe, servings: servings, unitSystem: unitSystem, date: date)
        all[session.id] = session
        try persist(all)
        return session
    }

    public func session(id: String) throws -> CookSession? {
        try loadIfNeeded()[id]
    }

    public func activeSession(for recipeID: String) throws -> CookSession? {
        try loadIfNeeded().values.first { $0.recipeID == recipeID && $0.endedAt == nil }
    }

    public func allActiveSessions() throws -> [CookSession] {
        try loadIfNeeded().values.filter { $0.endedAt == nil }.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func setPrepTask(_ taskID: String, completed: Bool, sessionID: String, date: Date = Date()) throws -> CookSession {
        try update(sessionID: sessionID) { session in
            if completed { session.completedPrepTaskIDs.insert(taskID) } else { session.completedPrepTaskIDs.remove(taskID) }
            session.updatedAt = date
        }
    }

    @discardableResult
    public func focus(stageID: String, sessionID: String, date: Date = Date()) throws -> CookSession {
        try update(sessionID: sessionID) { session in
            guard session.readyStageIDs.contains(stageID) else { return }
            session.focusedStageID = stageID
            session.updatedAt = date
        }
    }

    @discardableResult
    public func complete(stageID: String, sessionID: String, date: Date = Date()) throws -> CookSession {
        try update(sessionID: sessionID) { session in
            guard session.stages.contains(where: { $0.id == stageID }) else {
                throw CookSessionError.unknownStage
            }
            guard !session.completedStageIDs.contains(stageID) else { return }
            guard session.readyStageIDs.contains(stageID) else {
                throw CookSessionError.blockedStage
            }
            session.completedStageIDs.insert(stageID)
            session.updatedAt = date
            session.focusedStageID = session.readyStageIDs.first
            if session.isComplete { session.endedAt = date }
        }
    }

    @discardableResult
    public func toggleTimer(
        sessionID: String,
        stageID: String,
        timer: StageTimer,
        date: Date = Date()
    ) throws -> CookSession {
        try update(sessionID: sessionID) { session in
            let compositeID = "\(stageID):\(timer.id)"
            guard let stage = session.stages.first(where: { $0.id == stageID }),
                  stage.timers.contains(where: { $0.id == timer.id }) else {
                throw CookSessionError.unknownTimer
            }
            if let index = session.timers.firstIndex(where: { $0.id == compositeID }) {
                var existing = session.timers[index]
                // A running timer past its deadline is finished even before reconciliation records it,
                // so the cook's tap restarts it rather than pausing it at zero.
                if existing.status == .running, existing.secondsRemaining(at: date) == 0 {
                    existing.status = .finished
                }
                switch existing.status {
                case .running:
                    existing.remainingSeconds = existing.secondsRemaining(at: date)
                    existing.status = .paused
                    existing.endDate = nil
                case .paused:
                    existing.startedAt = date
                    existing.endDate = date.addingTimeInterval(TimeInterval(max(existing.remainingSeconds, 1)))
                    existing.status = .running
                case .finished, .cancelled:
                    existing.startedAt = date
                    existing.remainingSeconds = timer.durationSeconds
                    existing.endDate = date.addingTimeInterval(TimeInterval(timer.durationSeconds))
                    existing.status = .running
                }
                session.timers[index] = existing
            } else {
                guard session.readyStageIDs.contains(stageID) else {
                    throw CookSessionError.blockedStage
                }
                session.timers.append(.init(
                    id: compositeID,
                    stageID: stageID,
                    label: timer.label,
                    durationSeconds: timer.durationSeconds,
                    startedAt: date,
                    endDate: date.addingTimeInterval(TimeInterval(timer.durationSeconds)),
                    status: .running
                ))
            }
            session.updatedAt = date
        }
    }

    @discardableResult
    public func cancelTimer(timerID: String, sessionID: String, date: Date = Date()) throws -> CookSession {
        try update(sessionID: sessionID) { session in
            guard let index = session.timers.firstIndex(where: { $0.id == timerID }) else {
                throw CookSessionError.unknownTimer
            }
            session.timers[index].status = .cancelled
            session.timers[index].endDate = nil
            session.updatedAt = date
        }
    }

    @discardableResult
    public func reconcileTimers(sessionID: String, date: Date = Date()) throws -> CookSession {
        try update(sessionID: sessionID) { session in
            for index in session.timers.indices where session.timers[index].status == .running {
                if session.timers[index].secondsRemaining(at: date) == 0 {
                    session.timers[index].status = .finished
                    session.timers[index].remainingSeconds = 0
                }
            }
            session.updatedAt = date
        }
    }

    /// Abandons a session: it stops being resumable and its timers stop, so nothing reschedules them.
    /// Returns the stored session, including timers started elsewhere (for example from a Live Activity).
    @discardableResult
    public func end(sessionID: String, date: Date = Date()) throws -> CookSession {
        try update(sessionID: sessionID) { session in
            session.endedAt = date
            session.updatedAt = date
            for index in session.timers.indices where session.timers[index].status == .running || session.timers[index].status == .paused {
                session.timers[index].status = .cancelled
                session.timers[index].endDate = nil
            }
        }
    }

    private func update(sessionID: String, mutation: (inout CookSession) throws -> Void) throws -> CookSession {
        var all = try loadIfNeeded()
        guard var session = all[sessionID] else { throw CookSessionError.notFound }
        try mutation(&session)
        all[sessionID] = session
        try persist(all)
        return session
    }

    private func loadIfNeeded() throws -> [String: CookSession] {
        if let sessions { return sessions }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            sessions = [:]
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode([String: CookSession].self, from: data)
        sessions = decoded
        return decoded
    }

    private func persist(_ value: [String: CookSession]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        sessions = value
    }

    private static func defaultFileURL() -> URL {
        let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
        if let group, let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return container.appendingPathComponent("CookSessions.json")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("RecipeTimeline/CookSessions.json")
    }
}

public enum CookSessionError: Error, LocalizedError, Equatable {
    case notFound
    case unknownStage
    case blockedStage
    case unknownTimer

    public var errorDescription: String? {
        switch self {
        case .notFound: "Cook session could not be found."
        case .unknownStage: "This stage is not part of the cook session."
        case .blockedStage: "Complete the stages this step depends on first."
        case .unknownTimer: "This timer is not part of the cook session."
        }
    }
}
