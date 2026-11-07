import SwiftUI
import Observation

/// One scene's modal stack. Each sheet keeps its own layer, so dismissing a child restores
/// the parent sheet rather than exposing the screen behind both of them.
@Observable final class PresentationAccessibilityState {
    private var layers: [UUID: Int] = [:]
    var topLayer: Int { layers.values.max() ?? 0 }
    func present(_ id: UUID, at layer: Int) { layers[id] = layer }
    func dismiss(_ id: UUID) { layers[id] = nil }
}

private struct PresentationAccessibilityContext {
    let state: PresentationAccessibilityState
    let layer: Int
    var next: Self { Self(state: state, layer: layer + 1) }
}

private struct PresentationAccessibilityKey: EnvironmentKey {
    static let defaultValue: PresentationAccessibilityContext? = nil
}

private extension EnvironmentValues {
    var presentationAccessibility: PresentationAccessibilityContext? {
        get { self[PresentationAccessibilityKey.self] }
        set { self[PresentationAccessibilityKey.self] = newValue }
    }
}

private struct PresentationAccessibilityLayer: ViewModifier {
    let context: PresentationAccessibilityContext
    var covered = false
    func body(content: Content) -> some View {
        content
            .accessibilityHidden(covered || context.state.topLayer > context.layer)
            .environment(\.presentationAccessibility, context)
    }
}

private struct PresentationAccessibilityRoot: ViewModifier {
    let covered: Bool
    @State private var state = PresentationAccessibilityState()
    func body(content: Content) -> some View {
        content.modifier(PresentationAccessibilityLayer(context: .init(state: state, layer: 0), covered: covered))
    }
}

private struct AccessibleSheetContent<Sheet: View>: View {
    @Environment(\.presentationAccessibility) private var parent
    @State private var id = UUID()
    @ViewBuilder let sheet: () -> Sheet
    var body: some View {
        if let parent {
            sheet()
                .modifier(PresentationAccessibilityLayer(context: parent.next))
                .onAppear { parent.state.present(id, at: parent.next.layer) }
                .onDisappear { parent.state.dismiss(id) }
        } else { sheet() }
    }
}

/// Native Photos/file pickers own their content; only their presenting layer is ours to hide.
private struct TrackedAccessibilityPresentation: ViewModifier {
    let presented: Bool
    @Environment(\.presentationAccessibility) private var parent
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content
            .onChange(of: presented, initial: true) { _, shown in
                guard let parent else { return }
                if shown { parent.state.present(id, at: parent.next.layer) }
                else { parent.state.dismiss(id) }
            }
            .onDisappear { parent?.state.dismiss(id) }
    }
}

extension View {
    func presentationAccessibilityRoot(covered: Bool = false) -> some View {
        modifier(PresentationAccessibilityRoot(covered: covered))
    }

    func trackedAccessibilityPresentation(_ presented: Bool) -> some View {
        modifier(TrackedAccessibilityPresentation(presented: presented))
    }

    func accessibleSheet<Sheet: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                      @ViewBuilder content: @escaping () -> Sheet) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) { AccessibleSheetContent(sheet: content) }
    }

    func accessibleSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                          @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        sheet(item: item, onDismiss: onDismiss) { item in AccessibleSheetContent { content(item) } }
    }

    func accessibleFullScreenCover<Sheet: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                                @ViewBuilder content: @escaping () -> Sheet) -> some View {
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) { AccessibleSheetContent(sheet: content) }
    }

    func accessibleFullScreenCover<Item: Identifiable, Sheet: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                                    @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        fullScreenCover(item: item, onDismiss: onDismiss) { item in AccessibleSheetContent { content(item) } }
    }
}
