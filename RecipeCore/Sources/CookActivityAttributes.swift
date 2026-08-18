import ActivityKit
import Foundation

public struct CookActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var focusedStageID: String?
        public var focusedAction: String
        public var nearestTimerID: String?
        public var nearestTimerStageID: String?
        public var nearestTimerLabel: String?
        public var nearestTimerEnd: Date?
        public var runningTimerCount: Int
        public var completedStageCount: Int
        public var totalStageCount: Int
        public var isComplete: Bool

        public init(session: CookSession) {
            focusedStageID = session.focusedStageID
            focusedAction = session.focusedStage?.action ?? (session.isComplete ? "Finished" : "Choose a stage")
            let nearest = session.nearestRunningTimer()
            nearestTimerID = nearest?.id
            nearestTimerStageID = nearest?.stageID
            nearestTimerLabel = nearest?.label
            nearestTimerEnd = nearest?.endDate
            runningTimerCount = session.runningTimerCount
            completedStageCount = session.completedStageIDs.count
            totalStageCount = session.stages.count
            isComplete = session.isComplete
        }
    }

    public var sessionID: String
    public var recipeID: String
    public var recipeTitle: String

    public init(session: CookSession) {
        sessionID = session.id
        recipeID = session.recipeID
        recipeTitle = session.recipeTitle
    }
}
