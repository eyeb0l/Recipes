import AppIntents
import Foundation
import UserNotifications

public struct CompleteCookStageIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Complete Cooking Stage"
    public static let description = IntentDescription("Marks a stage complete in the active cooking session.")

    @Parameter(title: "Session ID") public var sessionID: String
    @Parameter(title: "Stage ID") public var stageID: String

    public init() {
        sessionID = ""
        stageID = ""
    }

    public init(sessionID: String, stageID: String) {
        self.sessionID = sessionID
        self.stageID = stageID
    }

    public func perform() async throws -> some IntentResult {
        let session = try await CookSessionStore.shared.complete(stageID: stageID, sessionID: sessionID)
        await CookActivityController.startOrUpdate(session: session)
        return .result()
    }
}

public struct ToggleCookTimerIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Pause or Resume Cooking Timer"
    public static let description = IntentDescription("Pauses or resumes the nearest timer in a cooking session.")

    @Parameter(title: "Session ID") public var sessionID: String
    @Parameter(title: "Stage ID") public var stageID: String
    @Parameter(title: "Timer ID") public var timerID: String

    public init() {
        sessionID = ""
        stageID = ""
        timerID = ""
    }

    public init(sessionID: String, stageID: String, timerID: String) {
        self.sessionID = sessionID
        self.stageID = stageID
        self.timerID = timerID
    }

    public func perform() async throws -> some IntentResult {
        guard let current = try await CookSessionStore.shared.session(id: sessionID),
              let stage = current.stages.first(where: { $0.id == stageID }),
              let timer = stage.timers.first(where: { "\(stageID):\($0.id)" == timerID }) else {
            return .result()
        }
        let session = try await CookSessionStore.shared.toggleTimer(
            sessionID: sessionID,
            stageID: stageID,
            timer: timer
        )
        await CookTimerNotifications.sync(session: session)
        await CookActivityController.startOrUpdate(session: session)
        return .result()
    }
}

public enum CookTimerNotifications {
    public static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public static func sync(session: CookSession) async {
        let center = UNUserNotificationCenter.current()
        let knownIDs = session.timers.map { notificationID(sessionID: session.id, timerID: $0.id) }
        center.removePendingNotificationRequests(withIdentifiers: knownIDs)

        for timer in session.timers where timer.status == .running {
            let remaining = timer.secondsRemaining()
            guard remaining > 0 else { continue }
            let content = UNMutableNotificationContent()
            content.title = timer.label
            content.body = "\(session.recipeTitle) is ready for your attention."
            content.sound = .default
            content.userInfo = ["sessionID": session.id, "stageID": timer.stageID]
            let request = UNNotificationRequest(
                identifier: notificationID(sessionID: session.id, timerID: timer.id),
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(max(remaining, 1)), repeats: false)
            )
            try? await center.add(request)
        }
    }

    private static func notificationID(sessionID: String, timerID: String) -> String {
        "cook:\(sessionID):\(timerID)"
    }
}
