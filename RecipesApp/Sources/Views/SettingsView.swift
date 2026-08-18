import AuthenticationServices
import SwiftUI

struct SettingsView: View {
    let persistence: PersistenceController
    @Environment(AuthSession.self) private var auth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Import account") {
                    switch auth.state {
                    case .signedIn:
                        Label("Signed in with Apple", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(RecipeTheme.success)
                        Button("Sign out", role: .destructive) { auth.signOut() }
                    case .signingIn:
                        ProgressView("Signing in…")
                    case let .failed(message):
                        Text(message).foregroundStyle(RecipeTheme.warning)
                        appleButton
                    case .signedOut:
                        appleButton
                    }
                }
                Section("Recipe library") {
                    LabeledContent("Storage", value: persistence.mode == .iCloud ? "iCloud" : "On this device")
                    if let error = persistence.setupError {
                        Text("iCloud was unavailable, so the app opened a local library. \(error)")
                            .font(.footnote)
                            .foregroundStyle(RecipeTheme.warning)
                    }
                }
                Section("Privacy") {
                    Text("Recipe sources and generated recipes are not retained by the import proxy. Cleaned source text is stored only in your private library.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .editorialSurface()
    }

    private var appleButton: some View {
        SignInWithAppleButton(.continue) { _ in
        } onCompletion: { result in
            Task { await auth.handle(result: result) }
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: 46)
    }
}
