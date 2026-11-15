import Foundation
import SwiftData

enum PersistenceMode: String {
    case iCloud
    case localFallback
    case inMemory
}

struct PersistenceController {
    let container: ModelContainer
    let mode: PersistenceMode
    let setupError: String?

    static func make() -> PersistenceController {
        let schema = Schema([RecipeRecord.self])
        let process = ProcessInfo.processInfo
        let isTesting = process.arguments.contains("--ui-testing")
            || process.environment["RECIPE_TIMELINE_IN_MEMORY_STORE"] == "1"
            || process.environment["XCTestConfigurationFilePath"] != nil
        if isTesting {
            // Tests never sync: an unsigned test build has no CloudKit entitlement to set up.
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            return makeContainer(schema: schema, configuration: configuration, mode: .inMemory)
        }

        // CloudKit traps rather than throwing when the app is missing its iCloud entitlement, as unsigned
        // simulator builds are. Those builds also lack the App Group entitlement from the same entitlements
        // file, so a missing App Group container means CloudKit can't be set up safely.
        guard hasAppGroupContainer() else {
            return makeLocalStore(schema: schema, reason: "This build isn't signed with iCloud access.")
        }

        let identifier = Bundle.main.object(forInfoDictionaryKey: "ICloudContainerIdentifier") as? String
            ?? "iCloud.com.irisgiertuga.RecipeTimeline"
        let cloudConfiguration = ModelConfiguration(
            "Recipes",
            schema: schema,
            cloudKitDatabase: .private(identifier)
        )
        do {
            return .init(container: try ModelContainer(for: schema, configurations: [cloudConfiguration]), mode: .iCloud, setupError: nil)
        } catch {
            return makeLocalStore(schema: schema, reason: error.localizedDescription)
        }
    }

    private static func hasAppGroupContainer() -> Bool {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String else { return false }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil
    }

    private static func makeLocalStore(schema: Schema, reason: String) -> PersistenceController {
        let localConfiguration = ModelConfiguration("RecipesLocal", schema: schema, cloudKitDatabase: .none)
        do {
            return .init(
                container: try ModelContainer(for: schema, configurations: [localConfiguration]),
                mode: .localFallback,
                setupError: reason
            )
        } catch {
            fatalError("Unable to initialize recipe storage: \(error)")
        }
    }

    private static func makeContainer(
        schema: Schema,
        configuration: ModelConfiguration,
        mode: PersistenceMode
    ) -> PersistenceController {
        do {
            return .init(container: try ModelContainer(for: schema, configurations: [configuration]), mode: mode, setupError: nil)
        } catch {
            fatalError("Unable to initialize test storage: \(error)")
        }
    }
}
