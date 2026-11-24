import RecipeCore
import SwiftData
import SwiftUI

@main
struct RecipeTimelineApp: App {
    private let persistence: PersistenceController
    @State private var router = AppRouter()
    @State private var authSession = AuthSession()
    @State private var cloudSync = CloudSyncMonitor()
    /// UI tests force dark mode with a launch argument rather than changing the simulator's
    /// appearance, which is global state and makes iOS relaunch apps in the background.
    private let uiTestingColorScheme: ColorScheme? =
        ProcessInfo.processInfo.arguments.contains("--ui-testing-dark") ? .dark : nil

    init() {
        persistence = PersistenceController.make()
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            // Each UI test starts before the user has agreed to send recipe requests to OpenAI.
            UserDefaults.standard.removeObject(forKey: AppPreferenceKey.generationNoticeAccepted)
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(persistence: persistence)
                .environment(router)
                .environment(authSession)
                .environment(cloudSync)
                .onOpenURL { router.handle(url: $0) }
                .preferredColorScheme(uiTestingColorScheme)
        }
        .modelContainer(persistence.container)
    }
}
