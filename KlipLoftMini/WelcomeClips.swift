import Foundation
import SwiftData

/// Links shown on a fresh install: a KlipLoft pinboard with the website, the source code and the
/// LinkedIn post, plus a support card in builds made with WELCOME_SUPPORT_CARD.
/// They're ordinary clips, so they can be deleted like any other.
extension AppModel {
    private static let welcomePins: [(title: String, url: String, keywords: [String])] = {
        var pins: [(title: String, url: String, keywords: [String])] = [
            ("KlipLoft Website", "https://www.kliploft.app/", ["kliploft", "mini", "website", "download", "home"]),
            ("KlipLoft Mini on GitHub", "https://github.com/ronier83/KlipLoftMini", ["kliploft", "mini", "github", "source", "code", "open source"]),
            ("Say Thanks on LinkedIn", "https://www.linkedin.com/feed/update/urn:li:activity:7522724326031433728/", ["kliploft", "mini", "linkedin", "thanks", "share", "feedback"]),
        ]
        #if WELCOME_SUPPORT_CARD
        pins.append(("Buy Me a Coffee", "https://buymeacoffee.com/klipapp", ["kliploft", "mini", "coffee", "support", "donate", "tip"]))
        #endif
        return pins
    }()

    /// Adds the welcome clips once per Mac, and only to an empty history. With iCloud sync on,
    /// this waits for the first download, so a Mac joining an existing history (KlipLoft's
    /// included) gets none and no second KlipLoft pinboard.
    func addWelcomeClipsIfFreshInstall(since launch: Date) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Prefs.welcomeClipsChecked) else { return }
        defaults.set(true, forKey: Prefs.welcomeClipsChecked)

        // Clips copied since this launch don't count as existing history.
        let hasPinboards = ((try? context.fetchCount(FetchDescriptor<Pinboard>())) ?? 0) > 0
        let hasOlderClips = ((try? context.fetchCount(FetchDescriptor<ClipItem>(predicate: #Predicate { $0.createdAt < launch }))) ?? 0) > 0
        guard !hasPinboards, !hasOlderClips else { return }

        let board = Pinboard(name: "KlipLoft", colorIndex: 6, order: 0) // Orange, the app's own color
        context.insert(board)
        let now = Date.now
        // Inserted last to first, so the history (newest first) also starts with the website.
        for (index, pin) in Self.welcomePins.enumerated().reversed() {
            let item = insertClip(from: ClipDraft(kind: .link, text: pin.url,
                                                  sourceBundleID: Bundle.main.bundleIdentifier, sourceAppName: "KlipLoft Mini"))
            item.title = pin.title
            item.keywords = pin.keywords
            item.pinboardID = board.id
            // The pinboard shows the newest pin first, so the list's order is kept.
            item.pinnedAt = now.addingTimeInterval(-Double(index))
        }
        try? context.save()
        historyChanged()
    }
}
