import RecipeCore
import SwiftData
import SwiftUI

@main
struct RecipeTimelineApp: App {
    private let persistence: PersistenceController
    @State private var router = AppRouter()
    @State private var authSession = AuthSession()

    init() {
        persistence = PersistenceController.make()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(persistence: persistence)
                .environment(router)
                .environment(authSession)
                .onOpenURL { router.handle(url: $0) }
        }
        .modelContainer(persistence.container)
    }
}
