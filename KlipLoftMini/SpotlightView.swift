import AppKit
import SwiftUI

/// The search bar and the list under it. A previewed clip opens inside the list: the clip's row
/// stays, the other rows fold away, and the preview unfolds beneath it.
struct SpotlightView: View {
    @Bindable var model: AppModel

    /// The search field takes typing; the list takes ↑ ↓, Space, ↩ and the rest; the preview's
    /// text editor (or link address) and its Edit Title field take typing while they're being edited.
    enum Focus { case search, list, previewText, rename }
    @FocusState private var focus: Focus?
    /// When ↓ last moved focus from the search to the list. SwiftUI can hand that same key press
    /// to the list too once it has focus, which moved the selection a row or two past the first.
    @State private var listEnteredAt = Date.distantPast
    @Namespace private var rowSpace

    private var previewItem: ClipItem? {
        model.previewItemID.flatMap(model.item(withID:))
    }

    var body: some View {
        VStack(spacing: 12) {
            // The search and the toolbar bubble float side by side at the same height.
            HStack(spacing: 10) {
                searchBar
                ToolbarBubble(model: model)
            }
            list
        }
        .frame(width: SpotlightLayout.listWidth)
        .padding(.top, SpotlightLayout.chipRow)
        // While searching: how many clips match, centered above the search.
        .overlay(alignment: .top) {
            if let count = model.matchCount {
                MatchChip(count: count, noun: model.mode == .pinboards ? "Pinboard" : "Match")
                    .frame(height: SpotlightLayout.chipRow - 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.snappy(duration: 0.2), value: model.matchCount == nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.snappy(duration: 0.18), value: model.rows.map(\.id))
        .onChange(of: model.focusToken, initial: true) { focus = .search }
        // A clip is edited as typed: smart quotes and dashes, text replacement and autocorrect would
        // rewrite the whole edited paragraph (code, commands, JSON), so they're off in the preview.
        .onChange(of: focus) { _, field in
            guard field == .previewText || field == .rename else { return }
            DispatchQueue.main.async {
                guard let editor = NSApp.windows.first(where: { $0 is SpotlightPanel })?.firstResponder as? NSTextView else { return }
                Self.typeAsIs(editor)
            }
        }
        // Swapping the list for the preview drops keyboard focus; keep it on the list.
        .onChange(of: model.previewItemID) { _, id in
            guard id != nil || focus != .search else { return }
            focus = .list
            DispatchQueue.main.async { if focus != .search { focus = .list } }
        }
    }

    // MARK: Search bar

    /// The pinboard being browsed, if any.
    private var openPinboard: Pinboard? {
        if case .pinboard(let id) = model.mode { return model.pinboard(withID: id) }
        return nil
    }

    private var placeholder: String {
        switch model.mode {
        case .recent: "Search clips"
        case .pinboards: "Search pinboards"
        case .pinboard: "Search this pinboard"
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30)

            // Inside a pinboard, a chip with its pin in the pinboard's color; click to go back.
            if let board = openPinboard {
                Button { model.mode = .pinboards } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11, weight: .bold))
                            .rotationEffect(.degrees(45))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(board.color.gradient))
                        Text(board.name)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 11)
                    .padding(.vertical, 4)
                    .background(board.color.opacity(0.18), in: .capsule)
                    .overlay(Capsule().strokeBorder(board.color.opacity(0.45)))
                }
                .buttonStyle(.plain)
                .help("Back to all pinboards (⌫)")
            }

            // Type and app filters, as chips; click one (or ⌫ twice) to remove it.
            ForEach(model.searchFilters, id: \.self) { filter in
                FilterChip(filter: filter, isMarked: model.markedFilter == filter) { model.toggleFilter(filter) }
            }

            TextField(model.searchFilters.isEmpty ? placeholder : "", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .regular))
                .focused($focus, equals: .search)
                .onSubmit { if let row = model.selectedRow { model.activate(row) } }
                // No row is selected while typing; ↓ enters the list on its first row.
                .onKeyPress(.upArrow) { .handled }
                .onKeyPress(keys: [.downArrow], phases: [.down, .repeat]) { press in
                    // Held down, the repeats keep coming here: the first press enters the list on
                    // its first clip, and each repeat steps on from there.
                    if press.phase == .repeat, focus == .list || Date.now.timeIntervalSince(listEnteredAt) < 5 {
                        if focus != .list { focus = .list }
                        model.moveSelection(1)
                    } else {
                        enterList()
                    }
                    return .handled
                }
                .onKeyPress(.escape) { model.escape(); return .handled }
                // Tab completes the suggested filter, like autocomplete in Terminal; otherwise
                // it switches to the pinboards. Return still opens the selected clip.
                .onKeyPress(.tab) {
                    if model.searchSuggestion != nil {
                        model.acceptSearchSuggestion()
                    } else {
                        model.togglePinboards()
                    }
                    return .handled
                }
                .onKeyPress(.rightArrow) { handleRight() }
                .onKeyPress(.leftArrow) { handleLeft() }
                .onKeyPress(phases: [.down, .repeat]) { press in
                    if Self.isBackspace(press) { return handleDelete(isRepeat: press.phase == .repeat) }
                    // Any other key unmarks a chip the first ⌫ marked.
                    model.markedFilter = nil
                    return press.phase == .down ? handleCommandDigit(press) : .ignored
                }

            if let suggestion = model.searchSuggestion {
                SuggestionChip(filter: suggestion) { model.acceptSearchSuggestion() }
            }

            filterMenu
        }
        .padding(.leading, 16)
        .padding(.trailing, 18)
        .frame(height: SpotlightLayout.searchHeight)
        .panelGlass(in: Capsule())
    }

    /// → previews the selected clip or opens the selected pinboard, once the caret is at the end.
    private func handleRight() -> KeyPress.Result {
        guard model.query.isEmpty, let row = model.selectedRow else { return .ignored }
        switch row {
        case .clip(let item): if model.previewItemID != item.id { model.togglePreview(item) }
        case .pinboard: model.activate(row)
        }
        return .handled
    }

    private func handleLeft() -> KeyPress.Result {
        guard model.query.isEmpty else { return .ignored }
        if model.previewItemID != nil {
            model.previewItemID = nil
            return .handled
        }
        if case .pinboard = model.mode {
            model.mode = .pinboards
            return .handled
        }
        return .ignored
    }

    /// ⌫ on an empty search steps out of a pinboard.
    /// The Delete (backspace) key. macOS reports it as U+007F, which isn't SwiftUI's `.delete`
    /// (U+0008), so matching only `.delete` missed every press.
    static func isBackspace(_ press: KeyPress) -> Bool {
        press.key == .delete || press.key.character == "\u{7F}"
    }

    /// ⌫ on an empty search: chips first (mark, then remove), then out of a pinboard.
    private func handleDelete(isRepeat: Bool = false) -> KeyPress.Result {
        if model.deleteBackwardOverChips(isRepeat: isRepeat) { return .handled }
        guard model.query.isEmpty, model.mode != .recent, !isRepeat else { return .ignored }
        model.mode = model.mode == .pinboards ? .recent : .pinboards
        return .handled
    }

    /// ⌘1…⌘9 pick the row with that number, and ⌘0 the tenth.
    private func handleCommandDigit(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers == .command, let digit = Int(press.characters), (0...9).contains(digit) else { return .ignored }
        let index = digit == 0 ? 9 : digit - 1
        guard model.rows.indices.contains(index) else { return .ignored }
        model.activate(model.rows[index])
        return .handled
    }

    /// The filter icon at the end of the search: types, then the apps clips came from.
    private var filterMenu: some View {
        Menu {
            Section("Type") {
                ForEach(ClipKind.allCases, id: \.self) { kind in
                    Toggle(isOn: filterBinding(.kind(kind))) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            }
            Section("App") {
                ForEach(model.filterApps, id: \.bundleID) { app in
                    Toggle(isOn: filterBinding(.app(bundleID: app.bundleID, name: app.name))) {
                        Label {
                            Text(app.name)
                        } icon: {
                            Image(nsImage: AppIcons.menuIcon(for: app.bundleID))
                        }
                    }
                }
            }
            if !model.searchFilters.isEmpty {
                Divider()
                Button("Clear Filters") { model.searchFilters = [] }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(model.searchFilters.isEmpty ? Color.secondary : Color.accentColor)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by type or app")
    }

    private func filterBinding(_ filter: SearchFilter) -> Binding<Bool> {
        Binding(get: { model.searchFilters.contains(filter) }, set: { _ in model.toggleFilter(filter) })
    }

    // MARK: List keys

    /// Keys while the list has focus. Letters, digits and symbols go back to the search.
    private func handleListKey(_ press: KeyPress) -> KeyPress.Result {
        // Keys typed into the preview's editor or Edit Title field pass through this ancestor first;
        // leave them to the field, or every letter would close the preview and land in the search.
        if focus == .previewText || focus == .rename { return .ignored }
        if Self.isBackspace(press) {
            if !model.query.isEmpty {
                model.query.removeLast()
                focus = .search
                return .handled
            }
            return handleDelete(isRepeat: press.phase == .repeat)
        }
        model.markedFilter = nil
        // Held-down keys repeat only the arrows.
        if press.phase == .repeat, press.key != .downArrow, press.key != .upArrow { return .handled }
        if press.modifiers.contains(.command) { return handleCommandDigit(press) }
        // The ↓ that entered the list, delivered again: it already did its job.
        if press.key == .downArrow || press.key == .upArrow, Date.now.timeIntervalSince(listEnteredAt) < 0.2 {
            return .handled
        }
        switch press.key {
        case .downArrow:
            moveSelection(1)
        case .upArrow:
            if model.selectedIndex == 0, model.previewItemID == nil {
                focus = .search
            } else {
                moveSelection(-1)
            }
        case .space:
            guard let row = model.selectedRow else { return .ignored }
            switch row {
            case .clip(let item): withAnimation(Self.previewSpring) { model.togglePreview(item) }
            case .pinboard: model.activate(row)
            }
        case .return:
            guard let row = model.selectedRow else { return .ignored }
            model.activate(row)
        case .escape:
            if model.previewItemID != nil {
                withAnimation(Self.previewSpring) { model.previewItemID = nil }
            } else {
                model.escape()
            }
        case .tab:
            model.togglePinboards()
        case .rightArrow:
            guard let row = model.selectedRow else { return .ignored }
            switch row {
            case .clip(let item): if model.previewItemID != item.id { withAnimation(Self.previewSpring) { model.togglePreview(item) } }
            case .pinboard: model.activate(row)
            }
        case .leftArrow:
            if model.previewItemID != nil {
                withAnimation(Self.previewSpring) { model.previewItemID = nil }
            } else if case .pinboard = model.mode {
                model.mode = .pinboards
            }
        default:
            guard press.modifiers.isSubset(of: [.shift]), let scalar = press.characters.unicodeScalars.first,
                  !CharacterSet.whitespacesAndNewlines.contains(scalar), !CharacterSet.controlCharacters.contains(scalar)
            else { return .ignored }
            // Editing a clip starts only on purpose (a click in its text, or Edit Text), so typing searches
            typeIntoSearch(press.characters)
        }
        return .handled
    }

    /// Turns off the substitutions that would change a clip's text behind the user's back.
    static func typeAsIs(_ editor: NSTextView) {
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
    }

    /// ↑ ↓. With a preview open it jumps straight to the next clip's preview: the open/close
    /// spring is for opening and closing, not for stepping through clips.
    private func moveSelection(_ offset: Int) {
        guard model.previewItemID != nil else { return model.moveSelection(offset) }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { model.moveSelection(offset) }
    }

    /// Moves focus from the search to the list, on its first row.
    private func enterList() {
        guard !model.rows.isEmpty else { return }
        model.selectedIndex = 0
        listEnteredAt = .now
        focus = .list
    }

    /// Moves focus back to the search and adds the typed text at the end of it, rather than
    /// replacing the search (a field selects all of its text when it takes focus).
    private func typeIntoSearch(_ text: String) {
        model.previewItemID = nil
        focus = .search
        DispatchQueue.main.async {
            let panel = NSApp.windows.first { $0 is SpotlightPanel }
            if let editor = panel?.firstResponder as? NSTextView {
                editor.moveToEndOfDocument(nil)
                editor.insertText(text, replacementRange: editor.selectedRange())
            } else {
                model.query += text
            }
        }
    }

    static let previewSpring = Animation.spring(response: 0.38, dampingFraction: 0.84)

    // MARK: List

    private var visibleRows: CGFloat {
        CGFloat(min(max(model.rows.count, 1), Prefs.rowCount))
    }

    private var previewed: (item: ClipItem, index: Int)? {
        guard let id = model.previewItemID, let index = model.rows.firstIndex(where: { $0.id == id }),
              case .clip(let item) = model.rows[index] else { return nil }
        return (item, index)
    }

    @ViewBuilder
    private var list: some View {
        Group {
            if model.rows.isEmpty {
                Text(emptyText)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: SpotlightLayout.rowHeight)
            } else if let previewed {
                VStack(spacing: 0) {
                    RowView(row: .clip(previewed.item), number: previewed.index + 1, isSelected: true,
                            isPreviewed: false, model: model)
                        .matchedGeometryEffect(id: previewed.item.id, in: rowSpace)
                        .padding([.horizontal, .top], 8)
                    // The row plus the preview fill the full list height, whatever the clip.
                    PreviewBody(item: previewed.item, model: model, focus: $focus)
                        .frame(height: SpotlightLayout.listHeight - SpotlightLayout.rowHeight - 8)
                        .id(previewed.item.id)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: -18)).combined(with: .scale(scale: 0.97, anchor: .top)),
                            removal: .opacity
                        ))
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                                RowView(row: row, number: index + 1, isSelected: (focus == .list || model.mouseActive) && index == model.selectedIndex,
                                        isPreviewed: false, model: model)
                                    .matchedGeometryEffect(id: row.id, in: rowSpace)
                                    .id(row.id)
                            }
                        }
                        .padding(8)
                    }
                    .scrollIndicators(.never)
                    .frame(height: visibleRows * (SpotlightLayout.rowHeight + 2) + 16)
                    .onAppear { proxy.scrollTo(model.selectedRow?.id) }
                    // Back to the top each time the panel opens, and when a search changes the list.
                    .onChange(of: model.focusToken) { if let id = model.rows.first?.id { proxy.scrollTo(id, anchor: .top) } }
                    .onChange(of: model.rows.first?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .top) } }
                    .onChange(of: model.selectedIndex) { _, index in
                        guard model.rows.indices.contains(index) else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(model.rows[index].id) }
                    }
                }
                .transition(.opacity)
            }
        }
        .panelGlass(in: RoundedRectangle(cornerRadius: 26))
        .focusable()
        .focused($focus, equals: .list)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in handleListKey(press) }
        .animation(Self.previewSpring, value: model.previewItemID)
    }

    private var emptyText: String {
        switch model.mode {
        case .recent: model.query.isEmpty ? "Copy something and it shows up here." : "No clips match."
        case .pinboards: model.query.isEmpty ? "No pinboards yet. Pin a clip from its preview." : "No pinboards match."
        case .pinboard: model.query.isEmpty ? "This pinboard is empty." : "No pinned clips match."
        }
    }
}

/// A type or app filter in the search. The first ⌫ marks it in the accent color; the next, or a
/// click, removes it.
struct FilterChip: View {
    let filter: SearchFilter
    let isMarked: Bool
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                switch filter {
                case .kind(let kind):
                    Image(systemName: kind.symbol)
                        .font(.system(size: 12.5))
                        .foregroundStyle(isMarked ? Color.white : Color.secondary)
                case .app(let bundleID, _):
                    Image(nsImage: AppIcons.icon(for: bundleID))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 18, height: 18)
                }
                Text(filter.title)
                    .lineLimit(1)
                    .foregroundStyle(isMarked ? Color.white : Color.primary)
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(isMarked ? Color.white : Color.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(.circle)
            }
            .font(.system(size: 14))
            .padding(.leading, 8)
            .padding(.trailing, 5)
            .frame(height: 28)
            .background(Capsule().fill(isMarked ? Color.accentColor : Color.primary.opacity(0.09)))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Remove filter")
    }
}

/// The filter offered for what's typed (`AppModel.searchSuggestion`): a dimmed, dashed chip with
/// ⇥ at its end; Tab or a click turns it into a real chip.
struct SuggestionChip: View {
    let filter: SearchFilter
    let accept: () -> Void

    var body: some View {
        Button(action: accept) {
            HStack(spacing: 5) {
                switch filter {
                case .kind(let kind):
                    Image(systemName: kind.symbol)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                case .app(let bundleID, _):
                    Image(nsImage: AppIcons.icon(for: bundleID))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 18, height: 18)
                }
                Text(filter.title)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 14))
            .padding(.leading, 8)
            .padding(.trailing, 9)
            .frame(height: 28)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .opacity(0.8)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(filter.isKind ? "Press Tab to filter by this type" : "Press Tab to filter by this app")
    }
}

/// "12 Matches", "1 Match", "No Matches" (or pinboards), in a small glass chip.
struct MatchChip: View {
    let count: Int
    let noun: String

    private var title: String {
        if count == 0 { return "No \(noun == "Match" ? "Matches" : "Pinboards")" }
        let plural = noun == "Match" ? "Matches" : "\(noun)s"
        return "\(count.formatted()) \(count == 1 ? noun : plural)"
    }

    var body: some View {
        Text(title)
            .font(.system(size: 13.5, weight: .semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.snappy, value: count)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .panelGlass(in: Capsule())
    }
}
