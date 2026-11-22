import os
import AppKit

/// Picks up screenshots saved by macOS's built-in tool (⇧⌘3/4/5). Spotlight tags those files
/// with kMDItemIsScreenCapture, so a live metadata query finds new ones without any polling.
///
/// The App Store sandbox only lets the app read a folder the user picked, so the screenshot
/// folder is chosen once in an Open panel and kept as a security-scoped bookmark.
final class ScreenshotWatcher {
    nonisolated static let previewBundleID = "com.apple.Preview"

    private let onCapture: (ClipDraft) -> Void
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var seenPaths: Set<String> = []
    private var startedAt = Date.now
    /// The folder being read under its security scope while watching.
    private var scopedFolder: URL?

    init(onCapture: @escaping (ClipDraft) -> Void) {
        self.onCapture = onCapture
    }

    var folderName: String? { Self.bookmarkedFolder()?.lastPathComponent }

    /// Turning it on asks for the folder the first time. Returns false if the user cancels.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard enabled else {
            stop()
            return true
        }
        if Self.bookmarkedFolder() == nil, !Self.chooseFolder() { return false }
        start()
        return query != nil
    }

    /// Asks for the screenshot folder again (Settings → Change Folder…).
    func changeFolder() {
        guard Self.chooseFolder() else { return }
        stop()
        start()
    }

    private func start() {
        guard query == nil, let folder = Self.bookmarkedFolder(), folder.startAccessingSecurityScopedResource() else {
            EventLog.screenshots.error("no readable screenshot folder")
            return
        }
        scopedFolder = folder
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemContentTypeTree == 'public.image'")
        query.searchScopes = [folder]
        startedAt = .now
        seenPaths = []

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.markExisting() }
        })
        observers.append(center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] note in
            let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
            let changed = note.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem] ?? []
            MainActor.assumeIsolated { self?.handle(added + changed) }
        })
        query.start()
        self.query = query
        EventLog.screenshots.notice("watching for screenshots in \(folder.lastPathComponent, privacy: .public)")
    }

    private func stop() {
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
    }

    private static func bookmarkedFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Prefs.screenshotFolderBookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(fresh, forKey: Prefs.screenshotFolderBookmark)
        }
        return url
    }

    /// Opens on the Desktop, where macOS saves screenshots unless told otherwise.
    private static func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.message = "Choose the folder your screenshots are saved to (usually the Desktop)."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: .withSecurityScope)
        else { return false }
        UserDefaults.standard.set(bookmark, forKey: Prefs.screenshotFolderBookmark)
        return true
    }

    private func markExisting() {
        guard let query else { return }
        query.disableUpdates()
        for case let item as NSMetadataItem in query.results {
            if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String { seenPaths.insert(path) }
        }
        query.enableUpdates()
    }

    private func handle(_ items: [NSMetadataItem]) {
        for item in items {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  seenPaths.insert(path).inserted
            else { continue }
            // A screenshot moved or re-indexed after watching started isn't a new capture.
            if let created = item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date,
               created < startedAt.addingTimeInterval(-5) { continue }
            let url = URL(fileURLWithPath: path)
            Task { [weak self] in
                let draft = await Task.detached(priority: .userInitiated) {
                    (try? Data(contentsOf: url)).flatMap {
                        ClipDraft.image(from: $0, sourceBundleID: Self.previewBundleID, sourceAppName: "Preview")
                    }
                }.value
                if let draft { self?.onCapture(draft) }
            }
        }
    }
}
