import SwiftUI

extension View {
    /// The glass button style the panel's buttons share.
    func glassButtons() -> some View {
        buttonStyle(.glass)
    }

    /// Liquid Glass behind the panel's parts (the search, the list and the toolbar), faded or
    /// frosted by Background Transparency (Settings → Clips).
    func panelGlass<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(PanelGlass(shape: shape, interactive: interactive))
    }
}

/// The panel's glass as a layer behind its content, as in KlipLoft, so Background Transparency
/// can fade it toward see-through or wash it toward frosted.
private struct PanelGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @AppStorage(Prefs.panelTransparency) private var transparency = 0.0

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                Color.clear
                    .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                    .opacity(Prefs.glassOpacity(transparency))
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(Prefs.frostOpacity(transparency)))
            }
        }
    }
}
