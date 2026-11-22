import AppKit
import SwiftUI

/// Pinboards, iCloud and Settings in one glass capsule split by hairlines, floating beside the
/// search bar at its height. Ported from KlipLoft's toolbar group, with the pin in place of
/// Explore Features.
struct ToolbarBubble: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            pinButton
            if model.sync.status != .off {
                ToolbarGroupDivider()
                SyncIndicator(model: model)
            }
            ToolbarGroupDivider()
            settingsMenu
        }
        .padding(.horizontal, 6)
        .frame(height: SpotlightLayout.searchHeight)
        .panelGlass(in: Capsule(), interactive: true)
    }

    /// Recent clips ⇄ pinboards. Lit in the accent color while browsing pinboards, and in the
    /// pinboard's own color inside one.
    private var pinButton: some View {
        let tint: Color? = switch model.mode {
        case .recent: nil
        case .pinboards: .accentColor
        case .pinboard(let id): model.pinboard(withID: id)?.color ?? .accentColor
        }
        return Button { model.togglePinboards() } label: {
            ToolbarGroupSymbol(name: tint == nil ? "pin" : "pin.fill", tint: tint)
                .rotationEffect(.degrees(45))
        }
        .buttonStyle(.plain)
        .help(model.mode == .recent ? "Show Pinboards (⇥)" : "Back to Recent Clips (⇥)")
    }

    private var settingsMenu: some View {
        Menu {
            Button("Settings…", systemImage: "gearshape") { model.showSettings() }
            Menu("Clear History", systemImage: "trash") {
                Button("Last 24 Hours…") { model.confirmClearRecentHistory() }
                Button("All History…") { model.confirmClearHistory() }
            }
            Divider()
            Button("About KlipLoft Mini", systemImage: "info.circle") { model.showAbout() }
            Button("Quit KlipLoft Mini", systemImage: "power") { NSApp.terminate(nil) }
        } label: {
            ToolbarGroupSymbol(name: "gearshape")
        } primaryAction: {
            model.showSettings()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings — press and hold for more")
    }
}

/// iCloud sync status: a cloud that turns orange when it needs attention, with Sync Now in its
/// menu. Hidden while sync is off. Ported from KlipLoft's grouped SyncIndicator.
struct SyncIndicator: View {
    let model: AppModel

    var body: some View {
        let status = model.sync.status
        // Ticks so "started 3 minutes ago" keeps moving: that's what shows a long sync isn't stuck.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            button(for: status, now: context.date)
        }
    }

    private func button(for status: CloudSync.Status, now: Date) -> some View {
        let sync = model.sync
        let title = status == .syncing ? sync.syncingTitle(now: now) : Self.description(of: status)
        let details = status == .syncing ? sync.syncingDetails(now: now) : []
        return Menu {
            Text(title)
            ForEach(details, id: \.self) { Text($0) }
            Divider()
            Button("Sync Now", systemImage: "arrow.clockwise.icloud") { model.syncNow() }
                .disabled(status == .noAccount)
            Button("iCloud Settings…", systemImage: "gearshape") { model.showSettings(page: .general) }
        } label: {
            ToolbarGroupSymbol(name: Self.symbol(for: status), tint: Self.needsAttention(status) ? .orange : nil)
                .symbolEffect(.rotate, isActive: status == .syncing)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(([title] + details).joined(separator: "\n"))
    }

    private static func symbol(for status: CloudSync.Status) -> String {
        switch status {
        case .upToDate: "checkmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .failed: "exclamationmark.icloud"
        case .noAccount: "icloud.slash"
        case .off: "icloud"
        }
    }

    private static func needsAttention(_ status: CloudSync.Status) -> Bool {
        switch status {
        case .failed, .noAccount: true
        default: false
        }
    }

    private static func description(of status: CloudSync.Status) -> String {
        switch status {
        case .upToDate(let date): "Up to date · synced \(date.formatted(.relative(presentation: .named)))"
        case .syncing: "Syncing with iCloud…"
        case .failed(let message): "Sync failed: \(message)"
        case .noAccount: "Sign in to iCloud in System Settings to sync"
        case .off: "iCloud sync is off"
        }
    }
}

/// A symbol in the toolbar bubble: gray like a macOS toolbar button, sized for the bubble.
struct ToolbarGroupSymbol: View {
    let name: String
    var tint: Color?

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(tint ?? Color(nsColor: .secondaryLabelColor))
            .frame(width: 46, height: SpotlightLayout.searchHeight)
            .contentShape(.rect)
    }
}

/// The hairline between the bubble's buttons.
struct ToolbarGroupDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 22)
    }
}
