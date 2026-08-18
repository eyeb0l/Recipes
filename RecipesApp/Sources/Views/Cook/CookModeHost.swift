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
                        "Cook session unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView("Restoring cook session…")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: exit)
                }
            }
        }
        .editorialSurface()
        .task(id: sessionID, load)
    }

    private func load() async {
        do {
            let restored = try await CookSessionStore.shared.reconcileTimers(sessionID: sessionID)
            session = restored
            recipe = records.first(where: { $0.id == restored.recipeID }).flatMap { try? $0.recipe() }
            await CookTimerNotifications.sync(session: restored)
            await CookActivityController.startOrUpdate(session: restored)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exit() {
        router.activeCookSession = nil
        dismiss()
    }
}
