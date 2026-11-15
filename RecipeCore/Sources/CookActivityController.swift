import ActivityKit
import Foundation

public enum CookActivityController {
    public static func startOrUpdate(session: CookSession) async {
        // An abandoned session must never revive its activity, even if a stale update races the end.
        if session.endedAt != nil, !session.isComplete {
            await end(session: session)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let activity = activity(for: session.id) {
            await activity.update(content(for: session))
            if session.isComplete {
                await activity.end(content(for: session), dismissalPolicy: .after(Date().addingTimeInterval(300)))
            }
            return
        }
        guard !session.isComplete else { return }
        do {
            _ = try Activity.request(
                attributes: CookActivityAttributes(session: session),
                content: content(for: session),
                pushType: nil
            )
        } catch {
            // Cook mode remains fully functional when the system declines a Live Activity.
        }
    }

    public static func end(session: CookSession) async {
        guard let activity = activity(for: session.id) else { return }
        await activity.end(content(for: session), dismissalPolicy: .immediate)
    }

    public static func reconcileWithStore(_ store: CookSessionStore = .shared) async {
        let active = (try? await store.allActiveSessions()) ?? []
        let sessionIDs = Set(active.map(\.id))
        for activity in Activity<CookActivityAttributes>.activities where !sessionIDs.contains(activity.attributes.sessionID) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        for session in active { await startOrUpdate(session: session) }
    }

    private static func activity(for sessionID: String) -> Activity<CookActivityAttributes>? {
        Activity<CookActivityAttributes>.activities.first { $0.attributes.sessionID == sessionID }
    }

    private static func content(for session: CookSession) -> ActivityContent<CookActivityAttributes.ContentState> {
        .init(
            state: .init(session: session),
            staleDate: session.nearestRunningTimer()?.endDate,
            relevanceScore: session.isComplete ? 0 : 80
        )
    }
}
