import AppKit
import SwiftData
import SwiftUI

/// The clip in full, unfolded inside the list under its row: Space, → or a right-click opens
/// it; Space, ←, Esc or a right-click again closes it.
struct PreviewBody: View {
    let item: ClipItem
    let model: AppModel
    /// The panel's keyboard focus, so the editable fields here can take typing from the list.
    var focus: FocusState<SpotlightView.Focus?>.Binding
    @State private var newPinboardName = ""
    /// The text being edited; saved shortly after typing stops, and when the preview closes.
    @State private var draft = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var naming = false
    /// Edit Title's popup, and the name being typed in it.
    @State private var renaming = false
    @State private var newTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // An accent outline marks the clip as being edited
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor.opacity(isEditing ? 0.55 : 0), lineWidth: 1.5)
                        .padding(.horizontal, -8)
                        .padding(.vertical, -4)
                        .allowsHitTesting(false)
                }
            Text(details)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // While editing, the buttons give way to Done so it's clear how to stop
            if isEditing { editingActions } else { actions }
        }
        .animation(.snappy(duration: 0.15), value: isEditing)
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .padding(.top, 4)
        // Edit Title's popup floats above the buttons inside the panel: a popover is a window of its own, and
        // the panel keeps the keyboard (it never activates the app), so a popover's field got no keys.
        .overlay(alignment: .bottom) {
            if renaming {
                RenameField(text: $newTitle, placeholder: ClipText.automaticTitle(item), focus: focus,
                            save: saveRename, cancel: cancelRename)
                    .padding(.bottom, 62)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .animation(.snappy(duration: 0.15), value: renaming)
    }

    /// True while the clip's text or link address has the keyboard.
    private var isEditing: Bool { focus.wrappedValue == .previewText }

    private var details: String {
        var parts = [item.footerText]
        if let app = item.sourceAppName { parts.append(app) }
        parts.append(ClipText.relativeDate(item.createdAt))
        return parts.joined(separator: " · ")
    }

    /// Text clips save shortly after typing stops.
    private func scheduleTextSave(_ text: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            model.updateText(of: item, to: text)
        }
    }

    private func saveTextNow() {
        saveTask?.cancel()
        guard !item.isDeleted, item.modelContext != nil, !draft.isEmpty else { return }
        model.updateText(of: item, to: draft)
    }

    /// Saves the name typed in Edit Title. Leaving the automatic title as it was keeps it automatic,
    /// so a link's title still follows its page; an empty name goes back to the automatic title.
    private func saveRename() {
        defer { cancelRename() }
        guard !item.isDeleted, item.modelContext != nil else { return }
        let typed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.title == nil, typed == ClipText.automaticTitle(item) { return }
        model.updateTitle(of: item, to: typed)
    }

    /// Closes Edit Title and gives the keys back to the list.
    private func cancelRename() {
        renaming = false
        focus.wrappedValue = .list
    }

    /// Edit Text / Edit Link: gives the clip's text the keyboard, with the cursor at the end.
    private func startEditing() {
        focus.wrappedValue = .previewText
        DispatchQueue.main.async {
            let panel = NSApp.windows.first { $0 is SpotlightPanel }
            (panel?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
        }
    }

    /// Esc in a field stops editing and hands the keys back to the list (where Esc again closes the preview).
    private func endEditing() -> KeyPress.Result {
        focus.wrappedValue = .list
        return .handled
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            TextEditor(text: $draft)
                .font(.system(size: 17))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.automatic)
                .padding(.horizontal, -5)
                .focused(focus, equals: .previewText)
                .onKeyPress(.escape) { endEditing() }
                .onAppear { draft = item.text ?? "" }
                .onChange(of: draft) { _, text in scheduleTextSave(text) }
                .onDisappear { saveTextNow() }
        case .link:
            VStack(alignment: .leading, spacing: 10) {
                if let image = Thumbnails.linkImage(for: item, maxPixelSize: 900) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 12))
                }
                if let title = item.linkTitle {
                    Text(title).font(.system(size: 15, weight: .semibold))
                }
                // The address is editable. It's saved on ↩, Esc or closing rather than while typing,
                // so a half-typed URL isn't turned into a text clip.
                TextField("Link", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .focused(focus, equals: .previewText)
                    .onSubmit { saveTextNow(); focus.wrappedValue = .list }
                    .onKeyPress(.escape) { saveTextNow(); return endEditing() }
                    .onAppear { draft = item.text ?? "" }
                    .onDisappear { saveTextNow() }
            }
        case .image:
            VStack(alignment: .leading, spacing: 10) {
                if let image = Thumbnails.image(for: item, maxPixelSize: 1200) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 12))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let text = model.imageText.text(for: item.id) {
                    foundText(text)
                }
            }
            // An image whose text hasn't been read yet (the backfill hasn't reached it) is read next.
            .task(id: item.id) { model.imageText.enqueue(item.id, data: nil, first: true) }
        case .color:
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(hex: item.text ?? "") ?? .gray)
                .overlay(Text(item.text?.uppercased() ?? "").font(.system(size: 20, weight: .semibold, design: .monospaced)).foregroundStyle(.white).shadow(radius: 3))
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.filePaths, id: \.self) { path in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading) {
                                Text((path as NSString).lastPathComponent).font(.system(size: 13, weight: .medium))
                                Text((path as NSString).deletingLastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Text Found: the text Vision read in the image, selectable; long text scrolls in its box.
    private func foundText(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Text Found")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Paste") { model.paste(item) }
            // Links only: hand the URL to the default browser
            if item.kind == .link {
                Button("Open in Browser") { model.openInBrowser(item) }
            }
            Button("Copy") { model.copy(item) }
            // Images only, once Vision has found text in them
            if item.kind == .image, model.imageText.text(for: item.id) != nil {
                Button("Copy Text") { model.copyText(of: item) }
            }
            pinMenu
            // Text and links can be edited in place; the same as clicking into the text
            if item.kind == .text || item.kind == .link {
                Button(item.kind == .link ? "Edit Link" : "Edit Text", action: startEditing)
            }
            Button("Edit Title") {
                newTitle = ClipText.title(item)
                renaming = true
            }
            Spacer()
            Button(role: .destructive) { model.delete(item) } label: { Image(systemName: "trash") }
                .help("Delete clip")
        }
        .glassButtons()
        .controlSize(.large)
        .popover(isPresented: $naming) {
            HStack {
                TextField("Pinboard name", text: $newPinboardName)
                    .frame(width: 180)
                    .onSubmit(createAndPin)
                Button("Pin", action: createAndPin).disabled(newPinboardName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }

    /// Shown instead of the buttons while editing: Done (same as Esc) saves and hands the keys back to the list.
    private var editingActions: some View {
        HStack(spacing: 10) {
            Button("Done") {
                saveTextNow()
                focus.wrappedValue = .list
            }
            .buttonStyle(.glassProminent)
            .help("Stop editing (Esc)")
            Label("Editing — Esc also finishes", systemImage: "pencil")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .controlSize(.large)
    }

    private var pinMenu: some View {
        // The board this clip is pinned to, if any: the button shows its name and color
        let board = item.pinboardID.flatMap(model.pinboard(withID:))
        return Menu {
            // Each board with its color dot on the left, as in KlipLoft; the clip's current board is grayed out
            ForEach(model.pinboards(), id: \.id) { board in
                Button { model.pin(item, to: board) } label: {
                    Label { Text(board.name) } icon: { Image(nsImage: board.menuDot) }
                }
                .disabled(item.pinboardID == board.id)
            }
            // Menus drop item icons unless asked to show both title and icon
            .labelStyle(.titleAndIcon)
            Divider()
            Button("New Pinboard…") { naming = true }
            if item.pinboardID != nil {
                Button("Unpin") { model.unpin(item) }
            }
        } label: {
            Label {
                Text(board?.name ?? "Pin")
            } icon: {
                Image(systemName: board == nil ? "pin" : "pin.fill")
                    .foregroundStyle(board?.color ?? .primary)
            }
        }
        // Menus don't take the glass button style, so the glass capsule of Paste and Copy is drawn
        // here, sized like them; a pinned clip's glass is tinted with its board's color. The plain
        // style keeps the label's own colors (borderless menus gray it out).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 14)
        .frame(height: 30)
        .glassEffect(board.map { .regular.tint($0.color.opacity(0.3)).interactive() } ?? .regular.interactive(),
                     in: .capsule)
    }

    private func createAndPin() {
        let name = newPinboardName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.pin(item, to: model.createPinboard(named: name))
        newPinboardName = ""
        naming = false
    }
}

/// Edit Title's popup: the current name, all selected, so typing replaces it and → edits it.
/// ↩ saves; Esc cancels. Names sync like the rest of the clip, so KlipLoft shows them too.
private struct RenameField: View {
    @Binding var text: String
    /// The automatic title, shown when the field is emptied (saving empty goes back to it).
    let placeholder: String
    var focus: FocusState<SpotlightView.Focus?>.Binding
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // A field selects all of its text when it takes focus.
            TextField("Name", text: $text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .focused(focus, equals: .rename)
                .onSubmit(save)
                .onKeyPress(.escape) { cancel(); return .handled }
            Button("Cancel", action: cancel)
            Button("Save", action: save)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .onAppear { DispatchQueue.main.async { focus.wrappedValue = .rename } }
    }
}
