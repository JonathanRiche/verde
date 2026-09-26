import CoreText
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Text input positions (the document is the IME's marked text only)

private final class MarkPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

private final class MarkRange: UITextRange {
    let lower: MarkPosition
    let upper: MarkPosition
    init(_ lower: Int, _ upper: Int) {
        self.lower = MarkPosition(min(lower, upper))
        self.upper = MarkPosition(max(lower, upper))
    }
    override var start: UITextPosition { lower }
    override var end: UITextPosition { upper }
    override var isEmpty: Bool { lower.offset == upper.offset }
}

/// Copies go to this device only and expire; the text is never logged.
func copyTerminalText(_ text: String) {
    guard !text.isEmpty else { return }
    UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]],
                                  options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
}

/// Draws the core's grid snapshot and is the keyboard's text input. Committed text
/// goes straight to the session; only in-progress IME composition is kept locally.
/// Contents are never logged and never exposed to accessibility.
final class TerminalGridView: UIView, UITextInput {
    var onMeasured: (GridSize) -> Void = { _ in }
    var onInput: (TermInput) -> Void = { _ in }
    var onScroll: (Int) -> Void = { _ in }
    var onFontSize: (CGFloat) -> Void = { _ in }
    var onSelection: (GridSelection?) -> Void = { _ in }

    var snapshot: TerminalSnapshot? { didSet { plan = snapshot.map { renderPlan($0) }; setNeedsDisplay() } }
    var selection: GridSelection? { didSet { if selection != oldValue { setNeedsDisplay() } } }
    /// Writable host: the keyboard may be shown (input itself is gated by the model).
    var inputEnabled = false {
        didSet { if !inputEnabled && isFirstResponder { _ = resignFirstResponder() } }
    }
    var fontSize: CGFloat = 14 {
        didSet {
            guard fontSize != oldValue else { return }
            fonts.removeAll()
            metrics = CellMetrics.monospaced(size: fontSize, scale: max(traitCollection.displayScale, 1))
            lastMeasured = nil
            setNeedsLayout()
            setNeedsDisplay()
        }
    }

    private(set) var metrics = CellMetrics.monospaced(size: 14, scale: 2)
    private var plan: RenderPlan?
    private var lastMeasured: GridSize?
    private var fonts: [Int: CTFont] = [:]
    private var marked = ""
    private var markedSelection = NSRange(location: 0, length: 0)
    private var panRows: CGFloat = 0

    // UITextInputTraits: a terminal gets raw keys, never corrections.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var textContentType: UITextContentType! = nil

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityLabel = "Terminal"
        metrics = CellMetrics.monospaced(size: fontSize, scale: max(traitCollection.displayScale, 1))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        pan.require(toFail: press)
        [tap, pan, pinch, press].forEach(addGestureRecognizer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let size = terminalGrid(width: bounds.width, height: bounds.height, metrics: metrics)
        guard size != lastMeasured else { return }
        lastMeasured = size
        // Deferred out of the layout pass: it updates observed SwiftUI state.
        DispatchQueue.main.async { [weak self] in self?.onMeasured(size) }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.displayScale != traitCollection.displayScale {
            metrics = CellMetrics.monospaced(size: fontSize, scale: max(traitCollection.displayScale, 1))
            lastMeasured = nil
            setNeedsLayout()
        }
    }

    private func cell(at point: CGPoint) -> (row: Int, col: Int) {
        let cols = max(plan?.cols ?? 1, 1), rows = max(plan?.rows ?? 1, 1)
        return (min(max(Int(point.y / metrics.height), 0), rows - 1), min(max(Int(point.x / metrics.width), 0), cols - 1))
    }

    // MARK: Gestures

    @objc private func tapped() {
        if selection != nil { selection = nil; onSelection(nil); return }
        if inputEnabled && !isFirstResponder { _ = becomeFirstResponder() }
    }

    /// Dragging down reveals older rows (positive), like scrolling a transcript.
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began: panRows = 0
        case .changed:
            let total = gesture.translation(in: self).y / max(metrics.height, 1)
            let delta = Int(total - panRows)
            if delta != 0 {
                panRows += CGFloat(delta)
                onScroll(delta)
            }
        default: panRows = 0
        }
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let size = min(max((fontSize * gesture.scale).rounded(), MIN_FONT_POINTS), MAX_FONT_POINTS)
        guard size != fontSize else { return }
        gesture.scale = 1
        fontSize = size
        onFontSize(size)
    }

    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        guard plan != nil else { return }
        let at = cell(at: gesture.location(in: self))
        switch gesture.state {
        case .began:
            selection = GridSelection(anchorRow: at.row, anchorCol: at.col, row: at.row, col: at.col)
            onSelection(selection)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            guard var current = selection else { return }
            current.row = at.row
            current.col = at.col
            selection = current
            onSelection(current)
        default: break
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { inputEnabled }

    override var keyCommands: [UIKeyCommand]? {
        terminalKeyCommands().map { key in
            let command = UIKeyCommand(input: key.input, modifierFlags: key.flags, action: #selector(keyCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func keyCommand(_ command: UIKeyCommand) {
        guard let input = command.input, let mapped = hardwareKey(input: input, flags: command.modifierFlags) else { return }
        onInput(mapped)
    }

    /// Forward delete has no key-command input string; take it from the raw press.
    private func forwardDelete(_ press: UIPress) -> TermInput? {
        guard inputEnabled, let key = press.key, key.keyCode == .keyboardDeleteForward else { return nil }
        let flags = key.modifierFlags
        return .key("Delete", ctrl: flags.contains(.control), alt: flags.contains(.alternate), shift: flags.contains(.shift))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            if let input = forwardDelete(press) { onInput(input) } else { rest.insert(press) }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { forwardDelete($0) == nil }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return inputEnabled && UIPasteboard.general.hasStrings }
        if action == #selector(copy(_:)) { return selection != nil }
        return false
    }

    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string, !text.isEmpty { onInput(.paste(text)) }
    }

    override func copy(_ sender: Any?) {
        guard let snapshot, let selection else { return }
        copyTerminalText(selectedText(snapshot, selection))
    }

    // MARK: UIKeyInput / UITextInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        let hadMarked = !marked.isEmpty
        if hadMarked { clearMarked() }
        guard !text.isEmpty else { return }
        onInput(.text(text))
    }

    func deleteBackward() {
        if !marked.isEmpty {
            setMarkedText(String(marked.dropLast()), selectedRange: NSRange(location: max((marked as NSString).length - 1, 0), length: 0))
            return
        }
        onInput(.key("Backspace"))
    }

    private func clearMarked() {
        inputDelegate?.textWillChange(self)
        marked = ""
        markedSelection = NSRange(location: 0, length: 0)
        inputDelegate?.textDidChange(self)
        setNeedsDisplay()
    }

    var selectedTextRange: UITextRange? {
        get { MarkRange(markedSelection.location, markedSelection.location + markedSelection.length) }
        set {
            guard let range = newValue as? MarkRange else { return }
            markedSelection = NSRange(location: range.lower.offset, length: range.upper.offset - range.lower.offset)
        }
    }
    var markedTextRange: UITextRange? { marked.isEmpty ? nil : MarkRange(0, (marked as NSString).length) }
    var markedTextStyle: [NSAttributedString.Key: Any]?
    weak var inputDelegate: UITextInputDelegate?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        marked = markedText ?? ""
        let length = (marked as NSString).length
        let location = min(max(selectedRange.location, 0), length)
        markedSelection = NSRange(location: location, length: min(selectedRange.length, length - location))
        setNeedsDisplay()
    }

    func unmarkText() {
        guard !marked.isEmpty else { return }
        let text = marked
        clearMarked()
        onInput(.text(text))
    }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? MarkRange else { return nil }
        let string = marked as NSString
        let lower = min(range.lower.offset, string.length), upper = min(range.upper.offset, string.length)
        return string.substring(with: NSRange(location: lower, length: upper - lower))
    }

    func replace(_ range: UITextRange, withText text: String) {
        guard let range = range as? MarkRange, !marked.isEmpty else { insertText(text); return }
        let string = marked as NSString
        let lower = min(range.lower.offset, string.length), upper = min(range.upper.offset, string.length)
        setMarkedText(string.replacingCharacters(in: NSRange(location: lower, length: upper - lower), with: text),
                      selectedRange: NSRange(location: lower + (text as NSString).length, length: 0))
    }

    var beginningOfDocument: UITextPosition { MarkPosition(0) }
    var endOfDocument: UITextPosition { MarkPosition((marked as NSString).length) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? MarkPosition, let to = toPosition as? MarkPosition else { return nil }
        return MarkRange(from.offset, to.offset)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? MarkPosition else { return nil }
        let target = position.offset + offset
        return target < 0 || target > (marked as NSString).length ? nil : MarkPosition(target)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .left, .up: return self.position(from: position, offset: -offset)
        default: return self.position(from: position, offset: offset)
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = (position as? MarkPosition)?.offset ?? 0, b = (other as? MarkPosition)?.offset ?? 0
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? MarkPosition)?.offset ?? 0) - ((from as? MarkPosition)?.offset ?? 0)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        switch direction {
        case .left, .up: return range.start
        default: return range.end
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? MarkPosition else { return nil }
        switch direction {
        case .left, .up: return MarkRange(0, position.offset)
        default: return MarkRange(position.offset, (marked as NSString).length)
        }
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    /// Candidate windows anchor at the terminal cursor.
    private var cursorRect: CGRect {
        let cursor = snapshot?.cursor
        return CGRect(x: CGFloat(cursor?.col ?? 0) * metrics.width, y: CGFloat(cursor?.row ?? 0) * metrics.height,
                      width: metrics.width, height: metrics.height)
    }

    func firstRect(for range: UITextRange) -> CGRect {
        let cells = CGFloat(max((marked as NSString).length, 1))
        var rect = cursorRect
        rect.size.width = metrics.width * cells
        return rect
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        var rect = cursorRect
        rect.origin.x += CGFloat((position as? MarkPosition)?.offset ?? 0) * metrics.width
        rect.size.width = 2
        return rect
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    // MARK: Drawing

    private func font(_ style: TextStyle) -> CTFont {
        let key = (style.bold ? 1 : 0) | (style.italic ? 2 : 0)
        if let font = fonts[key] { return font }
        let base = UIFont.monospacedSystemFont(ofSize: fontSize, weight: style.bold ? .bold : .regular) as CTFont
        var font = base
        if style.italic {
            if let italic = CTFontCreateCopyWithSymbolicTraits(base, fontSize, nil, .traitItalic, .traitItalic) {
                font = italic
            } else {
                var skew = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
                font = CTFontCreateCopyWithAttributes(base, fontSize, &skew, nil)
            }
        }
        fonts[key] = font
        return font
    }

    private func rect(_ row: Int, _ col: Int, _ cells: Int) -> CGRect {
        CGRect(x: CGFloat(col) * metrics.width, y: CGFloat(row) * metrics.height,
               width: CGFloat(cells) * metrics.width, height: metrics.height)
    }

    /// Glyphs at exact cell positions so rounding never drifts across a row.
    private func drawASCII(_ context: CGContext, _ text: String, row: Int, col: Int, style: TextStyle, color: UInt32) {
        let font = font(style)
        let characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        _ = CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        let positions = (0..<characters.count).map { CGPoint(x: CGFloat($0) * metrics.width, y: 0) }
        context.saveGState()
        context.translateBy(x: CGFloat(col) * metrics.width, y: CGFloat(row) * metrics.height + metrics.baseline)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(cgColor(color))
        CTFontDrawGlyphs(font, glyphs, positions, glyphs.count, context)
        context.restoreGState()
    }

    /// Other text goes through Core Text for font fallback and combining marks.
    private func drawLine(_ context: CGContext, _ text: String, row: Int, col: Int, style: TextStyle, color: UInt32) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(style),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(color),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.saveGState()
        context.translateBy(x: CGFloat(col) * metrics.width, y: CGFloat(row) * metrics.height + metrics.baseline)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func decorate(_ context: CGContext, row: Int, col: Int, cells: Int, style: TextStyle, color: UInt32) {
        guard style.decorated else { return }
        let box = rect(row, col, cells)
        let thickness = max(1, (fontSize / 14).rounded())
        context.setFillColor(cgColor(color))
        if style.underline {
            context.fill(CGRect(x: box.minX, y: box.minY + metrics.baseline + thickness, width: box.width, height: thickness))
        }
        if style.strikethrough {
            context.fill(CGRect(x: box.minX, y: box.minY + metrics.baseline * 0.65, width: box.width, height: thickness))
        }
    }

    override func draw(_ dirty: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.textMatrix = .identity
        guard let plan else {
            context.setFillColor(UIColor.black.cgColor)
            context.fill(bounds)
            return
        }
        context.setFillColor(cgColor(plan.background))
        context.fill(bounds)
        for run in plan.backgrounds {
            context.setFillColor(cgColor(run.color))
            context.fill(rect(run.row, run.col, run.cells))
        }
        for run in plan.texts {
            if run.ascii {
                drawASCII(context, run.text, row: run.row, col: run.col, style: run.style, color: run.style.fg)
            } else {
                drawLine(context, run.text, row: run.row, col: run.col, style: run.style, color: run.style.fg)
            }
            decorate(context, row: run.row, col: run.col, cells: run.cells, style: run.style, color: run.style.fg)
        }
        if let cursor = plan.cursor, marked.isEmpty {
            let box = rect(cursor.row, cursor.col, cursor.cells)
            context.setFillColor(cgColor(cursor.color))
            switch cursor.shape {
            case .block:
                context.fill(box)
                if !cursor.text.isEmpty {
                    drawLine(context, cursor.text, row: cursor.row, col: cursor.col, style: cursor.style, color: cursor.textColor)
                }
            case .underline:
                context.fill(CGRect(x: box.minX, y: box.maxY - max(2, metrics.height * 0.1), width: box.width, height: max(2, metrics.height * 0.1)))
            case .bar:
                context.fill(CGRect(x: box.minX, y: box.minY, width: 2, height: box.height))
            }
        }
        if !marked.isEmpty, let cursor = snapshot?.cursor {
            // In-progress IME composition, drawn over the cursor cell.
            let row = Int(cursor.row), col = Int(cursor.col)
            let fg: UInt32 = 0xffffff
            let width = CGFloat(max(marked.count, 1)) * metrics.width
            context.setFillColor(cgColor(plan.background))
            context.fill(CGRect(x: CGFloat(col) * metrics.width, y: CGFloat(row) * metrics.height, width: width, height: metrics.height))
            drawLine(context, marked, row: row, col: col, style: TextStyle(fg: fg), color: fg)
            context.setFillColor(cgColor(fg))
            context.fill(CGRect(x: CGFloat(col) * metrics.width, y: CGFloat(row) * metrics.height + metrics.baseline + 1, width: width, height: 1))
        }
        if let selection {
            context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.4).cgColor)
            let start = selection.start, end = selection.end
            for row in max(start.row, 0)...max(min(end.row, plan.rows - 1), 0) {
                let from = row == start.row ? start.col : 0
                let to = row == end.row ? end.col : plan.cols - 1
                if from <= to { context.fill(rect(row, from, to - from + 1)) }
            }
        }
    }
}

/// Lets SwiftUI controls reach the grid's first-responder state.
final class TerminalHandle {
    weak var view: TerminalGridView?
    func hideKeyboard() { _ = view?.resignFirstResponder() }
}

struct TerminalCanvas: UIViewRepresentable {
    let snapshot: TerminalSnapshot?
    let inputEnabled: Bool
    let fontSize: CGFloat
    let selection: GridSelection?
    let handle: TerminalHandle
    let onMeasured: (GridSize) -> Void
    let onInput: (TermInput) -> Void
    let onScroll: (Int) -> Void
    let onFontSize: (CGFloat) -> Void
    let onSelection: (GridSelection?) -> Void

    func makeUIView(context: Context) -> TerminalGridView {
        let view = TerminalGridView(frame: .zero)
        handle.view = view
        return view
    }

    func updateUIView(_ view: TerminalGridView, context: Context) {
        view.onMeasured = onMeasured
        view.onInput = onInput
        view.onScroll = onScroll
        view.onFontSize = onFontSize
        view.onSelection = onSelection
        view.fontSize = fontSize
        view.inputEnabled = inputEnabled
        view.selection = selection
        view.snapshot = snapshot
    }
}

// MARK: - Screen

private struct KeyCap: View {
    let label: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(.system(.callout, design: .monospaced)).frame(minWidth: 36, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .tint(active ? .accentColor : .secondary)
    }
}

/// A daemon session on the selected host, drawn from the core's VT snapshot.
/// Leaving detaches (the session keeps running on the host).
struct TerminalScreen: View {
    let browse: BrowseModel
    let workspaceID: String
    /// nil opens "New terminal" (`terminal_create` once the grid is measured).
    let terminalID: String?

    @State private var model: TerminalModel?
    @State private var hostID: String?
    @State private var created: String?
    @State private var selection: GridSelection?
    @State private var handle = TerminalHandle()
    @AppStorage("terminal.fontSize") private var fontSize: Double = 14

    private var title: String {
        let id = model?.terminalID ?? terminalID
        let state = browse.state
        let workspace = state.workspaces?.items.first { $0.workspace_id == workspaceID }
        let pane = ((state.home?.items ?? []) + (workspace?.panes ?? []))
            .first { id != nil && $0.terminal_id == id }
        if let title = pane?.title, !title.isEmpty { return title }
        if let label = model?.view?.label, !label.isEmpty { return label }
        return id == nil ? "New terminal" : "Terminal"
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if let model {
                    TerminalCanvas(snapshot: model.snapshot, inputEnabled: model.writable,
                                   fontSize: CGFloat(fontSize), selection: selection, handle: handle,
                                   onMeasured: { model.setMeasured($0) }, onInput: { model.input($0) },
                                   onScroll: { model.scroll($0) }, onFontSize: { fontSize = Double($0) },
                                   onSelection: { selection = $0 })
                    overlays(model)
                } else {
                    Color.black
                }
            }
            if let model { bottomBar(model) }
        }
        .background(Color.black)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear(perform: open)
        .onDisappear {
            model?.stop()
            selection = nil
        }
    }

    private func open() {
        if let model, !model.closed { return }
        if hostID == nil { hostID = browse.hostID }
        let next = TerminalModel(browse: browse, hostID: hostID, workspaceID: workspaceID, terminalID: terminalID ?? created)
        next.onCreated = { created = $0 }
        model = next
        next.start()
    }

    @ViewBuilder private func overlays(_ model: TerminalModel) -> some View {
        VStack(spacing: 8) {
            if let notice = model.notice {
                HStack(spacing: 8) {
                    if model.failure == nil && (model.terminalID == nil || model.view == nil) {
                        ProgressView().controlSize(.small)
                    }
                    Text(notice).font(.footnote)
                    if notice == replayGapNotice { Button("Dismiss") { model.dismissGap() }.font(.footnote.bold()) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
                .accessibilityElement(children: .combine)
            }
            Spacer()
            if let offset = model.snapshot?.scroll_offset, offset > 0 {
                Button { model.scroll(-Int(offset)) } label: { Label("Latest", systemImage: "arrow.down") }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func bottomBar(_ model: TerminalModel) -> some View {
        if let selection {
            HStack {
                Button("Cancel") { self.selection = nil }
                Spacer()
                Button("Copy") {
                    if let snapshot = model.snapshot { copyTerminalText(selectedText(snapshot, selection)) }
                    self.selection = nil
                }
                .bold()
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(.bar)
        } else if model.writable {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Group { keys(model) }.disabled(!model.interactive)
                    KeyCap(label: "⌨︎") { handle.hideKeyboard() }.accessibilityLabel("Hide keyboard")
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 52)
            .background(.bar)
        }
    }

    @ViewBuilder private func keys(_ model: TerminalModel) -> some View {
        ForEach(accessoryKeys.prefix(2), id: \.label) { key in
            KeyCap(label: key.label) { model.input(key.input) }.accessibilityLabel(key.accessibility)
        }
        KeyCap(label: "Ctrl", active: model.ctrl) { model.toggleCtrl() }
            .accessibilityLabel("Control").accessibilityAddTraits(model.ctrl ? .isSelected : [])
        KeyCap(label: "Alt", active: model.alt) { model.toggleAlt() }
            .accessibilityLabel("Alt").accessibilityAddTraits(model.alt ? .isSelected : [])
        ForEach(accessoryKeys.dropFirst(2), id: \.label) { key in
            KeyCap(label: key.label) { model.input(key.input) }.accessibilityLabel(key.accessibility)
        }
        // PasteButton reads the pasteboard without a permission prompt.
        PasteButton(payloadType: String.self) { strings in
            let text = strings.joined(separator: "\n")
            Task { @MainActor in if !text.isEmpty { model.input(.paste(text)) } }
        }
        .labelStyle(.titleOnly)
        .buttonBorderShape(.roundedRectangle)
    }
}
