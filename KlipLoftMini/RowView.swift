import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One line in the list, laid out like the window switcher's: the clip's type in italics on the
/// left, the source app's icon, then the title over a preview of the clip. Or a pinboard.
/// Click pastes or opens; right-click previews.
struct RowView: View {
    let row: Row
    let number: Int
    let isSelected: Bool
    let isPreviewed: Bool
    let model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    /// Lines of the clip under its title (Settings → Clips); the row and its picture grow with them.
    @AppStorage(Prefs.previewLines) private var savedPreviewLines = Prefs.defaultPreviewLines
    private var previewLines: Int { Prefs.validPreviewLines(savedPreviewLines) }

    /// Dark Mode selects with a gray pill and white text, like Spotlight; Light Mode with a soft
    /// gray pill and the usual dark text.
    private var isDark: Bool { colorScheme == .dark }
    private var selectedText: Bool { isSelected && isDark }

    private var selectionFill: Color {
        if isSelected { return isDark ? Color(white: 0.42).opacity(0.62) : Color.black.opacity(0.09) }
        return .clear
    }

    var body: some View {
        HStack(spacing: 14) {
            switch row {
            case .clip(let item): clipContent(item)
            case .pinboard(let board, let count): pinboardContent(board, count: count)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: SpotlightLayout.rowHeight(lines: previewLines))
        // The selected row is a gray pill with white text, like Spotlight's.
        .foregroundStyle(selectedText ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(selectionFill)
        }
        .overlay {
            if isPreviewed {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 1)
            }
        }
        .contentShape(.rect)
        // The pointer selects the row it's over, but only once the mouse has really moved.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        model.rowFrames[row.id] = proxy.frame(in: .global)
                        model.rowAppeared(at: number - 1)
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in model.rowFrames[row.id] = frame }
                    .onDisappear { model.rowFrames[row.id] = nil }
            }
        }
        .onTapGesture { model.activate(row) }
        .overlay {
            RightClickCatcher {
                if case .clip(let item) = row { model.togglePreview(item) } else { model.activate(row) }
            }
        }
    }

    // MARK: Clip

    /// The window switcher's italic label column, here naming the clip's type.
    private func typeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12).italic())
            .foregroundStyle(selectedText ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .frame(width: 72, alignment: .trailing)
    }

    @ViewBuilder
    private func clipContent(_ item: ClipItem) -> some View {
        typeLabel(ClipText.typeLabel(item))
        AppIconView(item: item, side: 38)
        VStack(alignment: .leading, spacing: 3) {
            Text(ClipText.title(item))
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(ClipText.preview(item))
                .font(.system(size: 12.5))
                .foregroundStyle(selectedText ? AnyShapeStyle(.white.opacity(0.78)) : AnyShapeStyle(.secondary))
                .lineLimit(previewLines)
                .truncationMode(.tail)
        }
        Spacer(minLength: 8)
        // Pictures sit on the right, since the app icon took the left; they grow as much as the row does.
        if item.kind == .image || item.kind == .color || (item.kind == .link && item.linkImageData != nil) {
            ClipIcon(item: item, side: 34 + SpotlightLayout.rowHeight(lines: previewLines) - SpotlightLayout.rowHeight(lines: 1),
                     badge: false)
        }
        if item.pinboardID != nil, case .recent = model.mode {
            Image(systemName: "pin.fill")
                .font(.system(size: 11))
                .rotationEffect(.degrees(45))
                .foregroundStyle(item.pinboardID.flatMap { model.pinboardColors[$0] } ?? .secondary)
                .help(item.pinboardID.flatMap { model.pinboardNames[$0] }.map { "Pinned to \($0)" } ?? "Pinned")
        }
        shortcutLabel
        // The Mac's (i): opens this clip's preview, like Space or a right-click.
        Button { withAnimation(SpotlightView.previewSpring) { model.togglePreview(item) } } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(selectedText ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 30)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("Preview (Space)")
        .task(id: item.id) { await LinkPreviews.fetchIfNeeded(for: item, in: model.context) }
    }

    /// ⌘1 … ⌘9 and ⌘0 on the first ten rows, always shown, whatever the list.
    @ViewBuilder
    private var shortcutLabel: some View {
        if number <= 10 {
            Text("⌘\(number % 10)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(selectedText ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
        }
    }

    // MARK: Pinboard

    @ViewBuilder
    private func pinboardContent(_ board: Pinboard, count: Int) -> some View {
        typeLabel("Pinboard")
        Image(systemName: "pin.fill")
            .font(.system(size: 15, weight: .semibold))
            .rotationEffect(.degrees(45))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Circle().fill(board.color.gradient))
        VStack(alignment: .leading, spacing: 3) {
            Text(board.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Text(count == 1 ? "1 clip" : "\(count) clips")
                .font(.system(size: 12.5))
                .foregroundStyle(selectedText ? AnyShapeStyle(.white.opacity(0.78)) : AnyShapeStyle(.secondary))
        }
        Spacer()
        shortcutLabel
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

/// The clip's picture: a thumbnail for images and link previews, a swatch for colors, the file's
/// icon for files, and a document for text, each with the source app's icon as a badge.
struct ClipIcon: View {
    let item: ClipItem
    let side: CGFloat
    var badge = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            base
                .frame(width: side, height: side)
            if badge, item.sourceBundleID != nil {
                Image(nsImage: AppIcons.icon(for: item.sourceBundleID))
                    .resizable()
                    .frame(width: side * 0.45, height: side * 0.45)
                    .offset(x: side * 0.08, y: side * 0.06)
            }
        }
    }

    @ViewBuilder
    private var base: some View {
        switch item.kind {
        case .image:
            if let image = Thumbnails.image(for: item, maxPixelSize: Int(side * 2)) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(.rect(cornerRadius: 7))
            } else {
                systemIcon(.png)
            }
        case .link:
            if let image = Thumbnails.linkImage(for: item, maxPixelSize: Int(side * 2)) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(.rect(cornerRadius: 7))
            } else {
                systemIcon(.url)
            }
        case .color:
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: item.text ?? "") ?? .gray)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.3)))
                .padding(4)
        case .file:
            Image(nsImage: item.filePaths.first.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .data))
                .resizable()
        case .text:
            systemIcon(.plainText)
        }
    }

    private func systemIcon(_ type: UTType) -> some View {
        Image(nsImage: NSWorkspace.shared.icon(for: type))
            .resizable()
    }
}

/// The clip's source app icon, as in the window switcher; the clip's own picture for clips
/// with no source app.
struct AppIconView: View {
    let item: ClipItem
    let side: CGFloat

    var body: some View {
        if item.sourceBundleID != nil {
            Image(nsImage: AppIcons.icon(for: item.sourceBundleID))
                .resizable()
                .frame(width: side, height: side)
        } else {
            ClipIcon(item: item, side: side, badge: false)
        }
    }
}

/// Titles and subtitles shared by the rows and the preview.
enum ClipText {
    /// The italic label left of the app icon.
    static func typeLabel(_ item: ClipItem) -> String {
        switch item.kind {
        case .image: "Image"
        case .file: item.filePaths.count > 1 ? "Files" : "File"
        default: item.kind.title
        }
    }

    /// The line under the title: more of the clip itself, or when there's nothing more to show,
    /// when it was copied.
    static func preview(_ item: ClipItem) -> String {
        let copied = "Copied \(copiedTime(item.createdAt))"
        switch item.kind {
        case .text:
            let text = item.text ?? ""
            let hasTitle = !(item.title ?? "").isEmpty
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let rest = (hasTitle ? lines : Array(lines.dropFirst())).joined(separator: " ")
            return rest.isEmpty ? copied : rest
        case .link:
            let url = (item.text ?? "").replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            return item.linkTitle == nil && (item.title ?? "").isEmpty ? copied : url
        case .image:
            return "\(item.imageWidth) × \(item.imageHeight) pixels"
        case .file:
            return item.filePaths.first.map { ($0 as NSString).deletingLastPathComponent } ?? copied
        case .color:
            return HexColor.components(item.text ?? "").map { "RGB \(Int($0.red * 255)), \(Int($0.green * 255)), \(Int($0.blue * 255))" } ?? copied
        }
    }

    static func title(_ item: ClipItem) -> String {
        if let title = item.title, !title.isEmpty { return title }
        return automaticTitle(item)
    }

    /// The title a clip shows when it hasn't been given a name.
    static func automaticTitle(_ item: ClipItem) -> String {
        switch item.kind {
        case .text, .color:
            let text = item.text ?? ""
            return text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? text
        case .link:
            return item.linkTitle ?? item.text ?? "Link"
        case .image:
            return relativeDate(item.createdAt)
        case .file:
            let names = item.filePaths.map { ($0 as NSString).lastPathComponent }
            return names.count > 1 ? "\(names[0]) and \(names.count - 1) more" : names.first ?? "File"
        }
    }

    static func subtitle(_ item: ClipItem) -> String {
        let kind = switch item.kind {
        case .image: "PNG image"
        case .link: item.linkTitle == nil ? "Link" : (item.text ?? "Link").replacingOccurrences(of: "https://", with: "")
        default: item.kind.title
        }
        return "\(kind) · Copied \(copiedTime(item.createdAt))"
    }

    /// "9:30" today, "Yesterday", or "Nov 18".
    static func copiedTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "Today, 9:30", like the screenshot rows.
    static func relativeDate(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today, \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }
}

/// Catches right-clicks over a SwiftUI view and lets every other click through.
struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp: super.hitTest(point)
            default: nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }
    }
}
