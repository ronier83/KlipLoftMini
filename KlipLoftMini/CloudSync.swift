import AppKit
import CloudKit
import CoreData
import Security
import SwiftData

/// iCloud sync. SwiftData mirrors the clip store to the user's private CloudKit database
/// (through NSPersistentCloudKitContainer), which uploads and downloads only the records that
/// changed since the last sync, so a new Mac gets the whole history once and then only deltas.
/// The history capacity setting syncs through iCloud key-value storage, since each Mac's
/// pruning deletes clips everywhere.
@Observable
final class CloudSync {
    static let containerID = "iCloud.com.ronerez.Klip"
    /// The sizes Settings offers for the image limit, in MB, and the one a new install uses.
    static let syncedImageLimitOptions = [1, 3, 5, 7, 10]
    static let defaultSyncedImageLimitMB = 7

    /// The chosen limit in MB; a value from an old or hand-edited setting falls back to the default.
    static var syncedImageLimitMB: Int {
        let chosen = UserDefaults.standard.integer(forKey: Prefs.syncedImageLimitMB)
        return syncedImageLimitOptions.contains(chosen) ? chosen : defaultSyncedImageLimitMB
    }

    /// Larger images stay on the Mac that copied them (see `LocalImage`). Applies when a clip is
    /// saved, so changing it leaves clips already copied where they are.
    static var maxSyncedImageBytes: Int { syncedImageLimitMB * 1024 * 1024 }

    /// Whether this build is signed for KlipLoft's iCloud container. Only the official builds are;
    /// a build from source is signed with its own team, which can't use it, so it keeps its history
    /// on the Mac and Settings shows no iCloud section.
    static let isAvailable: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String]
        else { return false }
        return containers.contains(containerID)
    }()

    /// Read before Prefs defaults are registered, when the store is opened.
    static var isEnabled: Bool {
        guard isAvailable else { return false }
        // bool(forKey:) also reads "NO" from a launch argument (-iCloudSync NO), which arrives as a string.
        return UserDefaults.standard.object(forKey: Prefs.iCloudSync) == nil || UserDefaults.standard.bool(forKey: Prefs.iCloudSync)
    }

    /// Whether history may be pruned yet: not until a new Mac has downloaded what's in iCloud.
    static var canPrune: Bool {
        !isEnabled || UserDefaults.standard.bool(forKey: Prefs.iCloudImportedOnce)
    }

    enum Status: Equatable {
        case off
        case noAccount
        case syncing
        case upToDate(Date)
        case failed(String)
    }

    private(set) var status: Status = isEnabled ? .syncing : .off

    /// What the sync engine is doing, for the Syncing text. Apple reports no counts, only
    /// the kind of work and when it began.
    struct Activity: Equatable {
        enum Kind { case setup, download, upload, other }
        let kind: Kind
        let started: Date
    }

    /// The oldest sync still running; nil when idle (or after Sync Now, which starts no event).
    private(set) var activity: Activity?
    /// The last sync that finished cleanly, kept across launches.
    private(set) var lastSynced = UserDefaults.standard.object(forKey: Prefs.iCloudLastSynced) as? Date
    /// Running syncs by event ID: a long upload can outlast short imports that start and end meanwhile.
    @ObservationIgnored private var running: [UUID: NSPersistentCloudKitContainer.Event] = [:]
    /// After this long the status explains that a big history takes a while, so it doesn't read as stuck.
    private static let longSync: TimeInterval = 120

    /// Called after each completed download, and when another Mac changes the history capacity.
    @ObservationIgnored var onImport: (() -> Void)?
    @ObservationIgnored var onCapacityChange: (() -> Void)?
    /// Called when no iCloud account is available, so nothing will download.
    @ObservationIgnored var onAccountUnavailable: (() -> Void)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Watches sync events from the start: the store begins its setup and first upload as soon
    /// as it's opened, before `start`, and a missed start event would leave Syncing without
    /// its phase until that sync ends. Captures only this object, since AppModel is still being made.
    init() {
        guard Self.isEnabled else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            MainActor.assumeIsolated { self?.handle(event) }
        })
    }

    /// - Parameter storeWasEmpty: a new Mac waits for the capacity other Macs set instead of
    ///   publishing its own default.
    func start(storeWasEmpty: Bool) {
        guard Self.isEnabled else { return }
        NSApp.registerForRemoteNotifications()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in await AppModel.shared.sync.refreshAccount() }
        })

        let settings = NSUbiquitousKeyValueStore.default
        observers.append(center.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: settings, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.sync.pullCapacity() }
        })
        settings.synchronize()
        if settings.object(forKey: Prefs.historyCapacity) == nil, !storeWasEmpty {
            pushCapacity(HistoryCapacity.current)
        } else {
            pullCapacity()
        }
        Task { await refreshAccount() }
    }

    func pushCapacity(_ capacity: HistoryCapacity) {
        guard Self.isEnabled else { return }
        NSUbiquitousKeyValueStore.default.set(capacity.rawValue, forKey: Prefs.historyCapacity)
    }

    private func pullCapacity() {
        guard let value = (NSUbiquitousKeyValueStore.default.object(forKey: Prefs.historyCapacity) as? NSNumber)?.intValue,
              HistoryCapacity(rawValue: value) != nil,
              value != HistoryCapacity.current.rawValue
        else { return }
        UserDefaults.standard.set(value, forKey: Prefs.historyCapacity)
        onCapacityChange?()
    }

    private func handle(_ event: NSPersistentCloudKitContainer.Event) {
        guard let end = event.endDate else {
            running[event.identifier] = event
            updateActivity()
            if status != .noAccount { status = .syncing }
            return
        }
        running[event.identifier] = nil
        updateActivity()
        guard event.succeeded else {
            // Signed out of iCloud: the sync engine still runs and fails, and its raw error
            // ("Unable to initialize without an iCloud account (CKAccountStatusNoAccount)") would
            // replace the "Sign in to iCloud" message that the account check already showed.
            if status == .noAccount || Self.isNoAccountError(event.error) {
                status = .noAccount
            } else {
                status = .failed(event.error?.localizedDescription ?? "Sync failed.")
            }
            return
        }
        lastSynced = end
        UserDefaults.standard.set(end, forKey: Prefs.iCloudLastSynced)
        // Another sync is still going (say, a long upload while a quick import finished): keep showing it.
        if running.isEmpty { status = .upToDate(end) }
        if event.type == .import {
            UserDefaults.standard.set(true, forKey: Prefs.iCloudImportedOnce)
            onImport?()
        }
    }

    private func updateActivity() {
        activity = running.values.min { $0.startDate < $1.startDate }.map { event in
            let kind: Activity.Kind = switch event.type {
            case .setup: .setup
            case .import: .download
            case .export: .upload
            @unknown default: .other
            }
            return Activity(kind: kind, started: event.startDate)
        }
    }

    /// The Syncing headline: "Uploading to iCloud · started 3 minutes ago".
    func syncingTitle(now: Date) -> String {
        guard let activity else { return "Syncing with iCloud…" }
        let action = switch activity.kind {
        case .setup: "Connecting to iCloud"
        case .download: "Downloading from iCloud"
        case .upload: "Uploading to iCloud"
        case .other: "Syncing with iCloud"
        }
        return "\(action) · started \(activity.started.formatted(.relative(presentation: .named)))"
    }

    /// Lines under the Syncing headline: when it last finished, and reassurance on long syncs.
    func syncingDetails(now: Date) -> [String] {
        var lines: [String] = []
        if let activity, now.timeIntervalSince(activity.started) > Self.longSync {
            lines.append("Large histories can take several minutes. You can keep using KlipLoft Mini.")
        }
        if let lastSynced {
            lines.append("Last synced \(lastSynced.formatted(.relative(presentation: .named)))")
        }
        return lines
    }

    /// Sends any changes that haven't been uploaded yet, rechecks the iCloud account and
    /// settings, and shows Syncing meanwhile. Apple's sync engine has no call to fetch now:
    /// downloads arrive by push, usually within seconds.
    func syncNow(saving context: ModelContext) {
        guard Self.isEnabled else { return }
        let before = status
        status = .syncing
        try? context.save()
        NSUbiquitousKeyValueStore.default.synchronize()
        Task {
            await refreshAccount()
            // With nothing to upload no sync event follows, so settle back after a few seconds.
            try? await Task.sleep(for: .seconds(4))
            if status == .syncing, case .upToDate = before { status = before }
        }
    }

    /// A sync that failed only because no iCloud account is signed in: CloudKit's
    /// not-authenticated error, or the sync engine's "without an iCloud account" setup error.
    private static func isNoAccountError(_ error: Error?) -> Bool {
        guard let error else { return false }
        let errors = [error as NSError] + [(error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }
        return errors.contains { error in
            (error.domain == CKErrorDomain && error.code == CKError.Code.notAuthenticated.rawValue)
                || error.localizedDescription.contains("CKAccountStatusNoAccount")
        }
    }

    private func refreshAccount() async {
        let account = try? await CKContainer(identifier: Self.containerID).accountStatus()
        if account != .available {
            status = .noAccount
            // Only when signed out for sure: a failed check may still be followed by a download.
            if account == .noAccount { onAccountUnavailable?() }
        } else if status == .noAccount {
            status = .syncing
        }
    }

    /// Sync is switched on or off when the store opens, so a change needs a relaunch.
    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Prefs.iCloudSync)
        let alert = NSAlert()
        alert.messageText = enabled ? "Turn on iCloud sync?" : "Turn off iCloud sync?"
        alert.informativeText = enabled
            ? "KlipLoft Mini will restart and sync your clipboard history and pinboards with your other devices."
            : "KlipLoft Mini will restart. Your history stays on this Mac but no longer syncs; clips already in iCloud stay there."
        alert.addButton(withTitle: "Restart KlipLoft Mini")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(!enabled, forKey: Prefs.iCloudSync)
            return
        }
        relaunch()
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        // Start the new copy only after this one has quit, so two never share the store.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
