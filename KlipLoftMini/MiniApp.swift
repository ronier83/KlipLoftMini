import AppKit

/// A menu bar app: no Dock icon, just the status item and the panel.
@main
enum MiniMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
        installStatusItem()
        installMainMenu()
        // Show the panel once at launch, so a first run isn't just a menu bar icon.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            AppModel.shared.panel.show()
        }
    }

    /// Without a Dock icon, launching the app again (Finder, Spotlight, Launchpad) opens Settings,
    /// as KlipLoft does: the panel has its shortcut, and Settings is where a lost user looks.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.showSettings()
        return false
    }

    /// Text fields take ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z from the Edit menu's key equivalents. A menu bar
    /// app has no menus of its own, so without this ⌘A did nothing in the search.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit KlipLoft Mini", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The search bar, drawn like KlipLoft's menu bar icon (same frame height and line weight). A
        // template image, so it follows the menu bar's tint.
        let icon = NSImage(named: "MenuBarIcon")
        icon?.accessibilityDescription = "KlipLoft Mini"
        item.button?.image = icon
        let menu = NSMenu()
        menu.addItem(withTitle: "Open KlipLoft Mini", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "About KlipLoft Mini", action: #selector(openAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit KlipLoft Mini", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openPanel() { AppModel.shared.panel.show() }
    @objc private func openSettings() { AppModel.shared.showSettings() }
    @objc private func openAbout() { AppModel.shared.showAbout() }
}
