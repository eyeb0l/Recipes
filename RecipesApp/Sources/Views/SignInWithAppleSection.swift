import AuthenticationServices
import SwiftUI

/// Asks the user to sign in before the app sends anything to the import service.
struct SignInWithAppleSection: View {
    let title: String
    let explanation: String
    @Environment(AuthSession.self) private var auth

    var body: some View {
        Section(title) {
            if case let .failed(message) = auth.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(RecipeTheme.warning)
            }
            Text(explanation)
                .font(.footnote)
            SignInWithAppleButton(.continue) { _ in
            } onCompletion: { result in
                Task { await auth.handle(result: result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 46)
        }
    }
}
