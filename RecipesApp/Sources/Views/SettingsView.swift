import AuthenticationServices
import RecipeCore
import SwiftUI

struct SettingsView: View {
    let persistence: PersistenceController
    @Environment(AuthSession.self) private var auth
    @Environment(CloudSyncMonitor.self) private var cloudSync
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppPreferenceKey.unitSystem) private var units: UnitSystemPreference = .metric

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section("Recipe import") {
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
                    if persistence.mode == .iCloud {
                        syncStatus
                    }
                    if let error = persistence.setupError {
                        Text("iCloud isn't available, so this library is stored on this device. \(error)")
                            .font(.footnote)
                            .foregroundStyle(RecipeTheme.warning)
                    }
                }
                Section {
                    Picker("Units", selection: $units) {
                        ForEach(UnitSystemPreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                } header: {
                    Text("Display")
                } footer: {
                    Text("Used for imports, recipes, and cook mode. You can also switch units on any recipe. Each recipe keeps its original amounts.")
                }
                Section("Privacy") {
                    Text("The import service doesn't keep your source or imported recipe. The app saves cleaned source text only in your private library.")
                }
                Section("About") {
                    LabeledContent("Version", value: appVersion)
                }
                }
                .listRowBackground(RecipeTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(RecipeTheme.paper)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .editorialSurface()
    }

    @ViewBuilder
    private var syncStatus: some View {
        // Re-render every half minute so "5 minutes ago" keeps counting while Settings is open.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            LabeledContent("Last synced") {
                if cloudSync.isSyncing {
                    Text("Syncing…")
                } else if let date = cloudSync.lastSyncDate {
                    Text(CloudSyncMonitor.lastSyncedDescription(for: date, relativeTo: context.date))
                } else {
                    Text("Not yet")
                }
            }
        }
        if let message = cloudSync.errorMessage {
            Label(message, systemImage: "exclamationmark.icloud")
                .font(.footnote)
                .foregroundStyle(RecipeTheme.warning)
        }
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
