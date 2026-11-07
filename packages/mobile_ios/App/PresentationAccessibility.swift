import SwiftUI
import Observation
import UIKit

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
            // A real container keeps child accessibility modifiers (including NavigationStack's
            // native wrappers) from overriding the visibility of the presenting layer.
            .accessibilityElement(children: .contain)
            .accessibilityHidden(covered || context.state.topLayer > context.layer)
            .background(PresentationAccessibilityBridge(hidden: covered || context.state.topLayer > context.layer,
                                                         layer: context.layer, topLayer: context.state.topLayer))
            .environment(\.presentationAccessibility, context)
    }
}

/// NavigationStack and native list wrappers can remain in UIKit's AX tree despite the SwiftUI
/// modifier. Hide the presenting hosting controller's content, leaving presented controllers alone.
private struct PresentationAccessibilityBridge: UIViewRepresentable {
    let hidden: Bool
    let layer: Int
    let topLayer: Int
    func makeUIView(context: Context) -> LayerView { LayerView() }
    func updateUIView(_ view: LayerView, context: Context) {
        view.hiddenFromAccessibility = hidden
        view.accessibilityIdentifier = "presentation-layer-\(layer)-top-\(topLayer)"
        view.updateVisibility()
        DispatchQueue.main.async { [weak view] in view?.updateVisibility() }
    }

    final class LayerView: UIView {
        var hiddenFromAccessibility = false
        private weak var hostingView: UIView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateVisibility()
        }

        func updateVisibility() {
            guard window != nil else { return }
            var responder: UIResponder? = self
            while let current = responder {
                if var controller = current as? UIViewController {
                    while let parent = controller.parent { controller = parent }
                    if hostingView !== controller.view {
                        hostingView?.accessibilityElementsHidden = false
                        hostingView = controller.view
                    }
                    controller.view.accessibilityElementsHidden = hiddenFromAccessibility
                    return
                }
                responder = current.next
            }
        }

        deinit { hostingView?.accessibilityElementsHidden = false }
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

/// A custom overlay shares the scene's hosting controller with the screen behind it. Give
/// that screen its own native boundary so hiding it cannot also hide the overlay's controls.
private struct AccessibilityContentHost<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let covered: Bool
    @Environment(\.self) private var environment
    @Environment(\.presentationAccessibility) private var layer

    private var hidden: Bool { covered || (layer.map { $0.state.topLayer > $0.layer } ?? false) }

    func makeUIViewController(context: Context) -> ContentController {
        let controller = ContentController(content: hostedContent)
        controller.update(content: hostedContent, hidden: hidden)
        return controller
    }

    func updateUIViewController(_ controller: ContentController, context: Context) {
        controller.update(content: hostedContent, hidden: hidden)
    }

    private var hostedContent: AnyView {
        AnyView(content.environment(\.self, environment).accessibilityHidden(hidden))
    }

    final class ContentController: UIViewController {
        private let hosting: UIHostingController<AnyView>
        private var hiddenFromAccessibility = false

        init(content: AnyView) {
            hosting = UIHostingController(rootView: content)
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            addChild(hosting)
            hosting.view.backgroundColor = .clear
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hosting.view)
            NSLayoutConstraint.activate([
                hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            hosting.didMove(toParent: self)
        }

        func update(content: AnyView, hidden: Bool) {
            hosting.rootView = content
            hiddenFromAccessibility = hidden
            // SwiftUI owns the child hosting view's AX flags. This plain UIKit parent is
            // the stable boundary, including the navigation controller's native descendants.
            updateVisibility()
            DispatchQueue.main.async { [weak self] in self?.updateVisibility() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            updateVisibility()
        }

        private func updateVisibility() {
            view.accessibilityElementsHidden = hiddenFromAccessibility
        }
    }
}

extension View {
    func accessibilityContentHost(covered: Bool) -> some View {
        AccessibilityContentHost(content: self, covered: covered)
    }

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
