import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The Settings pages, listed in the sidebar in this order. Ported from KlipLoft.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, clips, shortcuts, privacy, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .clips: "Clips"
        case .shortcuts: "Shortcuts"
        case .privacy: "Privacy"
        case .about: "About"
        }
    }

    /// White symbol on a colored square, like System Settings' sidebar.
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .clips: "list.clipboard.fill"
        case .shortcuts: "command"
        case .privacy: "hand.raised.fill"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .clips: .orange
        case .shortcuts: .blue
        case .privacy: .blue
        case .about: .indigo
        }
    }
}

/// The selected page, owned by the window controller so `showSettings(page:)` can pick one.
@Observable
final class SettingsNavigation {
    var page: SettingsPage = .general
}

final class PreferencesWindowController: NSWindowController {
    let navigation = SettingsNavigation()
    static let size = NSSize(width: 787, height: 616)

    init(model: AppModel) {
        let host = NSHostingController(rootView: SettingsRootView(navigation: navigation).environment(model))
        host.sizingOptions = []
        // The page's navigation title names the window, and the split view's toolbar becomes the window's.
        host.sceneBridgingOptions = [.title, .toolbars]

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.setContentSize(Self.size)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        // A normal window: opening Settings brings it forward and gives it focus (showSettings),
        // but it doesn't stay above other apps.
        window.title = navigation.page.title
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// System Settings–style window: pages in a sidebar on the left, the selected one on the right.
private struct SettingsRootView: View {
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { navigation.page },
                set: { if let page = $0 { navigation.page = page } }
            )) {
                ForEach(SettingsPage.allCases) { page in
                    Label { Text(page.title) } icon: { SettingsIcon(page: page) }
                        .tag(page)
                }
            }
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .toggleStyle(.switch)
                .navigationTitle(navigation.page.title)
        }
        .frame(width: 787, height: 616)
    }

    @ViewBuilder private var detail: some View {
        switch navigation.page {
        case .general: GeneralPreferencesView()
        case .clips: ClipsPreferencesView()
        case .shortcuts: ShortcutsPreferencesView()
        case .privacy: PrivacyPreferencesView()
        case .about: AboutPreferencesView()
        }
    }
}

/// A page's sidebar icon: its symbol in white on a small rounded square of its color.
private struct SettingsIcon: View {
    let page: SettingsPage

    var body: some View {
        Image(systemName: page.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(page.color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - General

struct GeneralPreferencesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.alwaysPlainText) private var alwaysPlainText = false
    @AppStorage(Prefs.directPaste) private var directPaste = false
    @AppStorage(Prefs.soundEffects) private var soundEffects = false
    /// The slider's position. The saved capacity only changes once the slider settles and any
    /// deletion it causes is confirmed.
    @State private var draftCapacity = HistoryCapacity.current.rawValue
    @State private var capacityCheck: Task<Void, Never>?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(Prefs.historyCapacity) private var savedCapacity = HistoryCapacity.month.rawValue

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch KlipLoft Mini at Login", isOn: $launchAtLogin)
            }
            // Only builds signed for KlipLoft's iCloud container can sync (see CloudSync.isAvailable)
            if CloudSync.isAvailable {
                Section("iCloud") {
                    Toggle(isOn: Binding(
                        get: { CloudSync.isEnabled },
                        set: { CloudSync.setEnabled($0) }
                    )) {
                        Text("Sync History and Pinboards")
                        Text("Shares one history and its capacity with KlipLoft and your other devices. Images over 10 MB stay on the Mac that copied them.")
                    }
                    syncStatus
                }
            }
            Section {
                LabeledContent("History Capacity") {
                    VStack(spacing: 4) {
                        Slider(
                            value: Binding(get: { Double(draftCapacity) }, set: { draftCapacity = Int($0.rounded()) }),
                            in: 0...Double(HistoryCapacity.allCases.count - 1),
                            step: 1
                        )
                        HStack {
                            ForEach(HistoryCapacity.allCases, id: \.self) { option in
                                Text(option.label)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                if option != .unlimited { Spacer() }
                            }
                        }
                    }
                    .frame(width: 260)
                }
                LabeledContent("Clear History") {
                    HStack(spacing: 8) {
                        Button("Last 24 Hours…") { model.confirmClearRecentHistory() }
                        Button("All History…") { model.confirmClearHistory() }
                    }
                }
                LabeledContent("Clear Images") {
                    HStack(spacing: 8) {
                        Button("Last 24 Hours…") { model.confirmClearImages(lastDay: true) }
                        Button("All History…") { model.confirmClearImages(lastDay: false) }
                    }
                }
            } header: {
                Text("History")
            } footer: {
                Text("Pinned items and pinboards are always kept.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Pasting") {
                accessibilityStatus
                Toggle("Always Paste as Plain Text", isOn: $alwaysPlainText)
            }
            Section("Other") {
                Toggle("Sound Effects", isOn: $soundEffects)
            }
        }
        .formStyle(.grouped)
        .onChange(of: launchAtLogin) { _, enabled in
            do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
        .onChange(of: draftCapacity) { _, newValue in
            capacityCheck?.cancel()
            guard newValue != HistoryCapacity.current.rawValue else { return }
            // Wait for the slider to settle, so dragging past "Day" or "Week" deletes nothing.
            capacityCheck = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let target = HistoryCapacity(rawValue: newValue) else { return }
                if !model.setHistoryCapacity(target) {
                    draftCapacity = HistoryCapacity.current.rawValue
                }
            }
        }
        // Another Mac changed the capacity through iCloud.
        .onChange(of: savedCapacity) { _, value in draftCapacity = value }
        .onAppear { model.refreshPermissionStatus() }
    }

    @ViewBuilder private var syncStatus: some View {
        Group {
            switch model.sync.status {
            case .off:
                EmptyView()
            case .noAccount:
                Label("Sign in to iCloud in System Settings to sync", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .syncing:
                Label {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.sync.syncingTitle(now: context.date))
                            ForEach(model.sync.syncingDetails(now: context.date), id: \.self) {
                                Text($0).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 300, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, isActive: true)
                }
                .foregroundStyle(.secondary)
            case .upToDate(let date):
                Label {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Up to date · synced \(date.formatted(.relative(presentation: .named)))")
                    }
                } icon: {
                    Image(systemName: "checkmark.icloud.fill")
                }
                .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.icloud.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11))
    }

    /// The Direct Paste toggle; turning it on asks for Accessibility. While on, a Status row shows
    /// whether access is allowed, with a button while it's still missing.
    @ViewBuilder private var accessibilityStatus: some View {
        Toggle(isOn: Binding(get: { directPaste }, set: { model.setDirectPaste($0) })) {
            Text("Direct Paste")
            Text("Picking a clip pastes it into the app you're in. When off, the clip is copied and you press ⌘V.")
        }
        if directPaste {
            LabeledContent("Status") {
                Label(model.accessibilityGranted ? "Active" : "Waiting for Accessibility access",
                      systemImage: model.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.accessibilityGranted ? .green : .orange)
            }
            if !model.accessibilityGranted {
                LabeledContent {
                    Button("Open Accessibility Settings…") {
                        PasteService.requestAccess()
                        PasteService.openAccessibilitySettings()
                    }
                } label: {
                    Text("Accessibility Needed")
                    Text("Allow KlipLoft Mini in Privacy & Security → Accessibility so it can press ⌘V for you.")
                }
            }
        }
    }
}

// MARK: - Clips

struct ClipsPreferencesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.recentCount) private var recentCount = 10
    @AppStorage(Prefs.previewLines) private var previewLines = Prefs.defaultPreviewLines
    @AppStorage(Prefs.linkPreviews) private var linkPreviews = true
    @AppStorage(Prefs.captureScreenshots) private var captureScreenshots = false
    @AppStorage(Prefs.panelTransparency) private var panelTransparency = 0.0

    var body: some View {
        Form {
            Section("Panel") {
                Picker(selection: Binding(get: { Prefs.rowCount }, set: { recentCount = $0 })) {
                    ForEach(Prefs.rowChoices, id: \.self) { Text("\($0) Rows").tag($0) }
                } label: {
                    Text("Panel Size")
                    Text("How many rows the panel shows at once; scroll for the rest of your history. The preview keeps the same height.")
                }
                .pickerStyle(.menu)
                .onChange(of: recentCount) { model.refresh() }
                Picker(selection: Binding(get: { Prefs.validPreviewLines(previewLines) }, set: { previewLines = $0 })) {
                    ForEach(Prefs.previewLineChoices, id: \.self) { Text($0 == 1 ? "1 Line" : "\($0) Lines").tag($0) }
                } label: {
                    Text("Preview Lines")
                    Text("How much of each clip a row shows under its title. Rows, screenshots and link pictures grow to fit.")
                }
                .pickerStyle(.menu)
                .onChange(of: previewLines) { model.refresh() }
                LabeledContent {
                    TransparencyControl(value: $panelTransparency)
                } label: {
                    Text("Background Transparency")
                    Text("The glass behind the search, the list and the toolbar.")
                }
            }
            Section("Capture") {
                Toggle(isOn: Binding(
                    get: { captureScreenshots },
                    set: { on in captureScreenshots = model.screenshots.setEnabled(on) && on }
                )) {
                    Text("Save Screenshots as Clips")
                    Text("Screenshots you take with ⇧⌘3, ⇧⌘4 or ⇧⌘5 are added and ready to paste.")
                }
                if captureScreenshots {
                    LabeledContent {
                        Button("Change…") { model.screenshots.changeFolder() }
                    } label: {
                        Text("Screenshot Folder")
                        Text(model.screenshots.folderName ?? "Not chosen")
                    }
                }
            }
            Section("Links") {
                Toggle(isOn: $linkPreviews) {
                    Text("Link Previews")
                    Text("Shows each link's page title and image. This contacts the linked site once.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A slider from frosted to glass with the usual look in between, and a preview of rows over a
/// picture. Ported from KlipLoft, with 10% more range at each end.
struct TransparencyControl: View {
    @Binding var value: Double

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Frosted")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Slider(value: $value, in: Prefs.panelTransparencyRange)
                        .frame(width: 160)
                    Text("Glass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if value != 0 {
                    Button("Reset") { value = 0 }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize()
                }
            }
            preview
        }
    }

    /// A strip of the panel over a colorful backdrop, with two miniature rows on it.
    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return ZStack {
            LinearGradient(colors: [.orange, .pink, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
            Color.clear
                .glassEffect(.regular, in: shape)
                .opacity(Prefs.glassOpacity(value))
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(Prefs.frostOpacity(value)))
            VStack(spacing: 5) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.85, green: 0.47, blue: 0.34)).frame(width: 12, height: 12)
                        Capsule().fill(.primary.opacity(0.55)).frame(height: 5)
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        .frame(width: 92, height: 60)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.15)))
        .animation(.easeOut(duration: 0.1), value: value)
    }
}

// MARK: - Shortcuts

struct ShortcutsPreferencesView: View {
    private let panelShortcuts: [(keys: String, action: String)] = [
        ("↑ ↓", "Move between clips"),
        ("↩", "Paste the selected clip, or open a pinboard"),
        ("⌘1 – ⌘9, ⌘0", "Quick-paste one of the first ten clips"),
        ("→ / right-click", "Preview the selected clip"),
        ("←", "Close the preview, or leave a pinboard"),
        ("Tab", "Show pinboards, or back to recent clips"),
        ("⌫ (empty search)", "Leave a pinboard"),
        ("Type", "Search the current list"),
        ("Esc", "Close the preview, clear the search, then close"),
    ]

    @AppStorage(Prefs.hotKeyModifiers) private var hotKeyModifiers = 0

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    ShortcutRecorder()
                } label: {
                    Text("Open KlipLoft Mini")
                    // macOS keeps ⌥ and ⇧⌥ combos for typing symbols while a password field is focused.
                    if hotKeyModifiers & (cmdKey | controlKey) == 0, hotKeyModifiers & optionKey != 0 {
                        Text("Shortcuts with only ⌥ don't work in password fields.")
                    }
                }
            }
            // Action on the left, keys on the right, like System Settings → Keyboard Shortcuts.
            Section("In the Panel") {
                ForEach(panelShortcuts, id: \.keys) { shortcut in
                    LabeledContent(shortcut.action) {
                        Text(shortcut.keys)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutRecorder: View {
    @AppStorage(Prefs.hotKeyDisplay) private var display = "⌥Space"
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button { isRecording ? stop() : start() } label: {
            Text(isRecording ? "Type shortcut…" : display)
                .font(.system(size: 13, weight: .medium))
                .frame(minWidth: 130)
        }
        .onDisappear { stop() }
    }

    private func start() {
        isRecording = true
        HotKey.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.keyCode == 53 { // Escape
                    stop()
                    return nil
                }
                let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                guard !flags.intersection([.command, .option, .control]).isEmpty else {
                    NSSound.beep()
                    return nil
                }
                let saved = HotKey.shared.save(
                    keyCode: UInt32(event.keyCode),
                    modifiers: HotKey.carbonModifiers(from: flags),
                    display: HotKey.displayString(for: event)
                )
                if saved { stop() } else { NSSound.beep() }
                return nil
            }
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording {
            isRecording = false
            HotKey.shared.registerSaved()
        }
    }
}

// MARK: - Privacy

struct PrivacyPreferencesView: View {
    @AppStorage(Prefs.skipSecrets) private var skipSecrets = false
    @AppStorage(Prefs.saveAutomaticCopies) private var saveAutomaticCopies = false
    @State private var ignoredApps = UserDefaults.standard.stringArray(forKey: Prefs.ignoredApps) ?? Prefs.defaultIgnoredApps
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: confirmingOn($skipSecrets)) {
                    Text("Don't Save API Keys and Tokens")
                    Text("Skips copies that contain an API key, access token or private key, such as GitHub, AWS, OpenAI or Stripe keys.")
                }
                Toggle(isOn: $saveAutomaticCopies) {
                    Text("Save Automatic Copies")
                    Text("Keeps copies that apps make by themselves, such as copy-on-select in terminal apps. Copies from password managers are always skipped.")
                }
            } header: {
                Text("Sensitive Data")
            }
            Section {
                VStack(spacing: 0) {
                    ForEach(ignoredApps, id: \.self) { bundleID in
                        AppListRow(bundleID: bundleID, isSelected: selection == bundleID)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = bundleID }
                    }
                    if ignoredApps.isEmpty {
                        Text("No apps are ignored.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    Divider().padding(.top, 6)
                    HStack(spacing: 0) {
                        Button { addApps() } label: {
                            Image(systemName: "plus").frame(width: 22, height: 20)
                        }
                        .help("Add an app")
                        Divider().frame(height: 14)
                        Button { removeSelected() } label: {
                            Image(systemName: "minus").frame(width: 22, height: 20)
                        }
                        .disabled(selection == nil)
                        .help("Stop ignoring the selected app")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 4)
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ignore Applications")
                    Text("Don't save content copied from the applications below.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fontWeight(.regular)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Asks before turning on, and turns off at once.
    private func confirmingOn(_ value: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue }, set: { isOn in
            guard isOn else {
                value.wrappedValue = false
                return
            }
            let alert = NSAlert()
            alert.window.level = .floating
            alert.messageText = "Stop saving API keys and tokens?"
            alert.informativeText = "Copies that contain an API key, token or private key won't be saved."
            alert.addButton(withTitle: "Turn On")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { value.wrappedValue = true }
        })
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Ignore"
        panel.level = .floating
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  !ignoredApps.contains(bundleID)
            else { continue }
            ignoredApps.append(bundleID)
        }
        save()
    }

    private func removeSelected() {
        guard let selection else { return }
        ignoredApps.removeAll { $0 == selection }
        self.selection = nil
        save()
    }

    private func save() {
        UserDefaults.standard.set(ignoredApps, forKey: Prefs.ignoredApps)
    }
}

/// An app's icon and name; apps that aren't installed show their bundle ID.
private struct AppListRow: View {
    let bundleID: String
    let isSelected: Bool

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 10) {
            Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application))
                .resizable()
                .frame(width: 24, height: 24)
            Text(url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - About

struct AboutPreferencesView: View {
    private static let website = URL(string: "https://www.kliploft.app")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("KlipLoft Mini")
                            .font(.system(size: 20, weight: .semibold))
                        Text(version)
                            .foregroundStyle(.secondary)
                        Text("A clipboard manager for macOS, one search away.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                GetKlipLoftCard(website: Self.website)
            }
            Section {
                LabeledContent("Website") {
                    Link("kliploft.app", destination: Self.website)
                }
                updates
                LabeledContent("Source Code") {
                    Link("GitHub", destination: Self.sourceCode)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The App Store updates its copies; a DMG or a build from source is updated by downloading the newest release.
    private var updates: some View {
        LabeledContent("Updates") {
            if Self.isFromAppStore {
                Text("Through the Mac App Store")
                    .foregroundStyle(.secondary)
            } else {
                Link("Releases on GitHub", destination: Self.releases)
            }
        }
    }

    /// The App Store (and TestFlight) put a receipt inside the app; builds from source have none.
    private static let isFromAppStore = FileManager.default.fileExists(
        atPath: Bundle.main.bundleURL.appending(path: "Contents/_MASReceipt/receipt").path)
    private static let sourceCode = URL(string: "https://github.com/ronier83/KlipLoftMini")!
    private static let releases = URL(string: "https://github.com/ronier83/KlipLoftMini/releases")!
}

/// Mini's way into the full KlipLoft, its free bigger sibling: what it adds, and that the
/// history is already waiting there when both sync through iCloud.
private struct GetKlipLoftCard: View {
    let website: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.orange)
                Text("Want More? Try KlipLoft")
                    .font(.headline)
            }
            Text("Mini's bigger sibling, also free: your clips as a drawer of cards in the style you like, KlipLoft for iPhone and iPad with a keyboard that pastes your clips, one-click import from Paste or Maccy, and an MCP server for AI apps.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Both apps sync one history through KlipLoft's iCloud container, but only official builds can use it
            if CloudSync.isAvailable {
                Label("Your history and pinboards are already there through iCloud.", systemImage: "checkmark.icloud")
                    .foregroundStyle(.secondary)
            }
            Link(destination: website) {
                Label("Get KlipLoft", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }
}
