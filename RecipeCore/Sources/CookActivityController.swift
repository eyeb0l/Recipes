import ActivityKit
import Foundation

public enum CookActivityController {
    public static func startOrUpdate(session snapshot: CookSession, store: CookSessionStore = .shared) async {
        // Callers can hold a snapshot taken before the cook ended the session, so act on the stored one.
        let session = (try? await store.session(id: snapshot.id)) ?? snapshot
        // An abandoned session must never revive its activity.
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
            let activity = try Activity.request(
                attributes: CookActivityAttributes(session: session),
                content: content(for: session),
                pushType: nil
            )
            // If End persisted after the read above, it may have looked for activities before this one
            // existed. Re-check: an End that persists later still finds this activity and ends it.
            if let latest = try? await store.session(id: session.id), latest.endedAt != nil, !latest.isComplete {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
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
