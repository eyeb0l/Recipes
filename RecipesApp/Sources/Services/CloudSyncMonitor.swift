import CloudKit
import CoreData
import Foundation
import Observation

/// One CloudKit mirroring event, copied out of the non-Sendable `NSPersistentCloudKitContainer.Event`.
struct CloudSyncEvent: Equatable, Sendable {
    enum Kind: Sendable {
        case setup
        case `import`
        case export
    }

    let id: UUID
    let kind: Kind
    /// `nil` while the event is still running.
    let endDate: Date?
    let succeeded: Bool
    let errorMessage: String?
}

extension CloudSyncEvent {
    init(_ event: NSPersistentCloudKitContainer.Event) {
        id = event.identifier
        kind = switch event.type {
        case .setup: .setup
        case .import: .import
        case .export: .export
        @unknown default: .setup
        }
        endDate = event.endDate
        succeeded = event.succeeded
        errorMessage = event.error.map(CloudSyncMonitor.message(for:))
    }
}

/// Follows the recipe library's iCloud sync so Settings can say when it last worked, and why it
/// doesn't. SwiftData syncs through `NSPersistentCloudKitContainer`, which reports every setup,
/// import and export as an event; nothing else in the app sees CloudKit failures.
@MainActor
@Observable
final class CloudSyncMonitor {
    /// When an import or export last finished successfully. Persists between launches.
    private(set) var lastSyncDate: Date?
    private(set) var isSyncing = false
    /// The most recent failure that hasn't been followed by a success of the same kind.
    var errorMessage: String? {
        // Export failures matter most: they mean this device's changes aren't reaching iCloud.
        failures[.export] ?? failures[.import] ?? failures[.setup]
    }

    private var failures: [CloudSyncEvent.Kind: String] = [:]
    private var runningEvents: Set<UUID> = []
    private let defaults: UserDefaults
    @ObservationIgnored private nonisolated(unsafe) var observer: (any NSObjectProtocol)?
    private let notificationCenter: NotificationCenter

    init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        lastSyncDate = defaults.object(forKey: AppPreferenceKey.lastCloudSync) as? Date
        observer = notificationCenter.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event
            else { return }
            let summary = CloudSyncEvent(event)
            MainActor.assumeIsolated { self?.record(summary) }
        }
    }

    deinit {
        if let observer { notificationCenter.removeObserver(observer) }
    }

    /// CloudKit posts each event twice: once when it starts and again when it ends.
    func record(_ event: CloudSyncEvent) {
        guard let endDate = event.endDate else {
            runningEvents.insert(event.id)
            isSyncing = true
            return
        }
        runningEvents.remove(event.id)
        isSyncing = !runningEvents.isEmpty

        guard event.succeeded else {
            failures[event.kind] = event.errorMessage ?? "iCloud sync failed."
            return
        }
        failures[event.kind] = nil
        if event.kind != .setup, endDate > (lastSyncDate ?? .distantPast) {
            lastSyncDate = endDate
            defaults.set(endDate, forKey: AppPreferenceKey.lastCloudSync)
        }
    }

    /// "Just now" for the first minute, so the row doesn't count seconds after every save.
    nonisolated static func lastSyncedDescription(for date: Date, relativeTo now: Date = .now) -> String {
        if now.timeIntervalSince(date) < 60 { return "Just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    nonisolated static func message(for error: any Error) -> String {
        let ckError = (error as? CKError).map(firstMeaningfulError(in:))
        switch ckError?.code {
        case .notAuthenticated:
            return "Sign in to iCloud in the Settings app to sync your recipes."
        case .quotaExceeded:
            return "Your iCloud storage is full, so recipe changes can't upload."
        case .accountTemporarilyUnavailable:
            return "Your iCloud account is temporarily unavailable."
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return "iCloud can't be reached right now. Recipes will sync when it's back."
        default:
            return (ckError ?? error).localizedDescription
        }
    }

    /// A partial failure wraps one error per record, and most are "batch request failed" because a
    /// single bad record sinks its whole batch. Surface the error that caused it.
    private nonisolated static func firstMeaningfulError(in error: CKError) -> CKError {
        guard error.code == .partialFailure, let partials = error.partialErrorsByItemID?.values else { return error }
        let errors = partials.compactMap { $0 as? CKError }
        return errors.first { $0.code != .batchRequestFailed } ?? errors.first ?? error
    }
}
