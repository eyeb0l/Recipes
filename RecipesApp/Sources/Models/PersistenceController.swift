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
            let localConfiguration = ModelConfiguration("RecipesLocal", schema: schema, cloudKitDatabase: .none)
            do {
                return .init(
                    container: try ModelContainer(for: schema, configurations: [localConfiguration]),
                    mode: .localFallback,
                    setupError: error.localizedDescription
                )
            } catch {
                fatalError("Unable to initialize recipe storage: \(error)")
            }
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
