import RecipeCore
import SwiftData
import SwiftUI

struct CookModeHost: View {
    let sessionID: String

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Query private var records: [RecipeRecord]
    @State private var session: CookSession?
    @State private var recipe: RecipeV1?
    @State private var errorMessage: String?
    @State private var isConfirmingEnd = false
    @State private var endError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    CookModeView(
                        session: session,
                        recipe: recipe,
                        onSessionChanged: { self.session = $0 },
                        onExit: exit
                    )
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Can't open cook mode",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView("Opening cook mode…")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: exit)
                        .accessibilityHint("Keeps your progress and timers so you can come back")
                }
                if let session, session.endedAt == nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("End cooking", systemImage: "stop.circle") { isConfirmingEnd = true }
                            .accessibilityIdentifier("end-cooking")
                    }
                }
            }
            .confirmationDialog("End cooking?", isPresented: $isConfirmingEnd, titleVisibility: .visible) {
                Button("End cooking", role: .destructive) { Task { await endSession() } }
            } message: {
                Text("Your progress and running timers for this recipe will be cleared.")
            }
            .alert("Couldn't end cooking", item: $endError) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
        }
        .editorialSurface()
        .task(id: sessionID, load)
    }

    private func load() async {
        do {
            let restored = try await CookSessionStore.shared.reconcileTimers(sessionID: sessionID)
            // A cook link or Live Activity can point at a session the cook already ended.
            guard restored.endedAt == nil || restored.isComplete else {
                errorMessage = "This cooking session has ended. Start cooking again from the recipe."
                return
            }
            session = restored
            recipe = records.first(where: { $0.id == restored.recipeID }).flatMap { try? $0.recipe() }
            await CookTimerNotifications.sync(session: restored)
            await CookActivityController.startOrUpdate(session: restored)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func endSession() async {
        guard let current = session else { return exit() }
        let ended: CookSession
        do {
            ended = try await CookSessionStore.shared.end(sessionID: current.id)
        } catch {
            endError = error.localizedDescription
            return
        }
        await CookTimerNotifications.cancelAll(session: ended)
        await CookActivityController.end(session: ended)
        exit()
    }

    private func exit() {
        router.activeCookSession = nil
        dismiss()
    }
}
