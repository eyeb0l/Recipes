import EventKit
import Foundation
import RecipeCore

/// A Reminders list the app can add items to.
struct ReminderListSummary: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

enum ReminderAccess: Equatable, Sendable {
    case notDetermined
    case granted
    /// Denied by the person or restricted by the device; only Settings can change it.
    case denied
}

enum ShoppingReminderError: LocalizedError, Equatable {
    case accessDenied
    case noWritableList
    case listUnavailable
    case listChanged

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Recipe Timeline doesn't have access to Reminders. You can allow it in Settings."
        case .noWritableList:
            "There's no Reminders list that can be changed. Create a list in Reminders, then try again."
        case .listUnavailable:
            "That Reminders list is no longer available. Choose another list."
        case .listChanged:
            "The Reminders list changed while the items were being added, so nothing was added. Try again."
        }
    }
}

/// What adding a shopping list to Reminders changed.
struct ShoppingReminderResult: Equatable, Sendable {
    let listTitle: String
    let addedCount: Int
    let updatedCount: Int
    let alreadyListedCount: Int
}

@MainActor
protocol ShoppingReminderStore: AnyObject {
    var access: ReminderAccess { get }
    /// Asks for access if it hasn't been decided. Returns whether the app can now use Reminders.
    func requestAccess() async throws -> Bool
    func writableLists() -> [ReminderListSummary]
    func defaultListID() -> String?
    func incompleteReminders(inList listID: String) async throws -> [ExistingShoppingReminder]
    /// Applies a plan, or throws `listChanged` without changing anything if a reminder it updates has
    /// since been edited, completed, moved or deleted.
    func apply(_ plan: ShoppingReminderPlan, toList listID: String) throws
}

extension ShoppingReminderStore {
    /// Adds `items` to a list, reusing reminders that are already there for the same thing.
    func add(_ items: [ShoppingListItem], recipeTitle: String, toList listID: String) async throws -> ShoppingReminderResult {
        guard access == .granted else { throw ShoppingReminderError.accessDenied }
        guard let list = writableLists().first(where: { $0.id == listID }) else { throw ShoppingReminderError.listUnavailable }
        let existing = try await incompleteReminders(inList: listID)
        let plan = ShoppingList.plan(adding: items, recipeTitle: recipeTitle, to: existing)
        if !plan.isEmpty {
            try apply(plan, toList: listID)
        }
        return ShoppingReminderResult(
            listTitle: list.title,
            addedCount: plan.newReminders.count,
            updatedCount: plan.notesUpdates.count,
            alreadyListedCount: plan.alreadyListedCount
        )
    }
}

enum ShoppingReminderStoreFactory {
    /// UI tests use an in-memory store so they never wait on the Reminders permission prompt.
    @MainActor
    static func make() -> any ShoppingReminderStore {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            return InMemoryShoppingReminderStore(lists: [.init(id: "ui-testing-groceries", title: "Groceries")])
        }
        return EventKitShoppingReminderStore()
    }
}

// MARK: - EventKit

@MainActor
final class EventKitShoppingReminderStore: ShoppingReminderStore {
    private let store = EKEventStore()

    var access: ReminderAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestAccess() async throws -> Bool {
        switch access {
        case .granted: return true
        case .denied: return false
        case .notDetermined: return try await store.requestFullAccessToReminders()
        }
    }

    func writableLists() -> [ReminderListSummary] {
        guard access == .granted else { return [] }
        return store.calendars(for: .reminder)
            .filter(\.allowsContentModifications)
            .map { ReminderListSummary(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func defaultListID() -> String? {
        guard access == .granted, let list = store.defaultCalendarForNewReminders(), list.allowsContentModifications else { return nil }
        return list.calendarIdentifier
    }

    func incompleteReminders(inList listID: String) async throws -> [ExistingShoppingReminder] {
        guard let calendar = store.calendar(withIdentifier: listID) else { throw ShoppingReminderError.listUnavailable }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [calendar])
        return await withCheckedContinuation { continuation in
            // EventKit calls back on its own queue. The closure must be @Sendable, or Swift infers it
            // as main-actor isolated and traps when it runs elsewhere; copy out plain values here.
            store.fetchReminders(matching: predicate) { @Sendable reminders in
                let existing = (reminders ?? []).map {
                    ExistingShoppingReminder(id: $0.calendarItemIdentifier, title: $0.title ?? "", notes: $0.notes)
                }
                continuation.resume(returning: existing)
            }
        }
    }

    func apply(_ plan: ShoppingReminderPlan, toList listID: String) throws {
        guard let calendar = store.calendar(withIdentifier: listID), calendar.allowsContentModifications else {
            throw ShoppingReminderError.listUnavailable
        }
        do {
            for update in plan.notesUpdates {
                // The plan was worked out from a fetch that may now be out of date. Never write over a
                // change made since, in Reminders or on another device.
                guard let reminder = store.calendarItem(withIdentifier: update.reminderID) as? EKReminder,
                      reminder.refresh(),
                      !reminder.isCompleted,
                      reminder.calendar?.calendarIdentifier == listID,
                      reminder.notes == update.previousNotes
                else { throw ShoppingReminderError.listChanged }
                reminder.notes = update.notes
                try store.save(reminder, commit: false)
            }
            for item in plan.newReminders {
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = calendar
                reminder.title = item.title
                reminder.notes = item.notes
                try store.save(reminder, commit: false)
            }
            try store.commit()
        } catch {
            store.reset()
            throw error
        }
    }
}

// MARK: - In memory

/// A Reminders stand-in for tests and UI-test launches.
@MainActor
final class InMemoryShoppingReminderStore: ShoppingReminderStore {
    struct Reminder: Equatable {
        let id: String
        var listID: String
        var title: String
        var notes: String?
        var isCompleted = false
    }

    var access: ReminderAccess
    /// Settable so tests can change a reminder between planning and applying.
    var reminders: [Reminder] = []
    private let lists: [ReminderListSummary]
    private let grantsAccessOnRequest: Bool

    init(lists: [ReminderListSummary], access: ReminderAccess = .notDetermined, grantsAccessOnRequest: Bool = true) {
        self.lists = lists
        self.access = access
        self.grantsAccessOnRequest = grantsAccessOnRequest
    }

    func requestAccess() async throws -> Bool {
        if access == .notDetermined { access = grantsAccessOnRequest ? .granted : .denied }
        return access == .granted
    }

    func writableLists() -> [ReminderListSummary] { access == .granted ? lists : [] }
    func defaultListID() -> String? { access == .granted ? lists.first?.id : nil }

    func incompleteReminders(inList listID: String) async throws -> [ExistingShoppingReminder] {
        reminders
            .filter { $0.listID == listID && !$0.isCompleted }
            .map { ExistingShoppingReminder(id: $0.id, title: $0.title, notes: $0.notes) }
    }

    func apply(_ plan: ShoppingReminderPlan, toList listID: String) throws {
        guard lists.contains(where: { $0.id == listID }) else { throw ShoppingReminderError.listUnavailable }
        let indices = try plan.notesUpdates.map { update in
            guard let index = reminders.firstIndex(where: { $0.id == update.reminderID }),
                  !reminders[index].isCompleted,
                  reminders[index].listID == listID,
                  reminders[index].notes == update.previousNotes
            else { throw ShoppingReminderError.listChanged }
            return index
        }
        for (index, update) in zip(indices, plan.notesUpdates) {
            reminders[index].notes = update.notes
        }
        for item in plan.newReminders {
            reminders.append(.init(id: UUID().uuidString, listID: listID, title: item.title, notes: item.notes))
        }
    }

    func insert(_ reminder: Reminder) { reminders.append(reminder) }
}
