import Foundation
import Observation

@MainActor
@Observable
final class AppRouter {
    var selectedRecipeID: String?
    var activeCookSession: CookSessionRoute?
    var presentedSheet: AppSheet?

    func handle(url: URL) {
        guard url.scheme == "recipetimeline" else { return }
        if url.host == "cook",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let sessionID = components.queryItems?.first(where: { $0.name == "session" })?.value {
            activeCookSession = .init(id: sessionID)
        }
    }
}

enum AppSheet: String, Identifiable {
    case importRecipe
    case settings

    var id: String { rawValue }
}

struct CookSessionRoute: Identifiable, Hashable {
    let id: String
}
