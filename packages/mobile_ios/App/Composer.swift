import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

func composerChoiceLabel(_ choices: [ChatChoice], value: String?) -> String {
    choices.first { $0.id == (value ?? "") }?.label
        ?? value.flatMap { $0.isEmpty ? nil : $0 } ?? "Auto"
}

/// The speed a label or picker names (I10-2): "Standard" or "Fast", never the core's "Normal".
/// The chip abbreviates it to "Std" (the same words as Android).
func composerSpeedLabel(_ id: String?) -> String { id == "on" ? "Fast" : "Standard" }

/// A picker or menu row for a choice that is the host's default: "Full access (default)" (I10-1).
func composerDefaultMarked(_ label: String) -> String { label + " (default)" }

/// A new thread runs with full access unless the user picks otherwise (host default).
let defaultAccessID = "full_access"

/// The empty field's placeholder: while a reply runs it says what Send does instead.
func composerPlaceholder(_ kind: FollowupKind?) -> String {
    kind.map { $0.hint + "…" } ?? "Ask anything, or use / for commands and @ to search files."
}

/// The line under the controls while a reply runs. The empty field's placeholder already says
/// it, and a follow-up card speaks for itself, so the hint shows once (I2-5).
func composerHintLine(_ kind: FollowupKind?, text: String, followupShown: Bool) -> String? {
    guard let kind, !followupShown, !text.isEmpty else { return nil }
    return kind.hint + ". Long-press Send for other options."
}

/// A chip label cut to `limit` characters with "…" (a capped frame would stretch every chip to it).
func chipDisplay(_ text: String, limit: Int) -> String {
    text.count > limit ? String(text.prefix(max(1, limit - 1))) + "…" : text
}

/// A catalog row that stands for the provider's own default.
func isDefaultChoice(_ id: String) -> Bool { id.isEmpty || id == "default" }

/// What a default choice runs (I10-1): the model the core names ("Opus 5.5"), else "Auto". Never a
/// bare "Default"; pickers mark the default row instead.
func composerDefaultLabel(_ resolved: String?) -> String {
    guard let resolved, !resolved.isEmpty else { return "Auto" }
    return resolved
}

/// A chip's estimated widths: with its label, and as an icon (nil when it has no icon).
struct ComposerChipWidth: Equatable {
    let kind: ComposerPicker
    let full: CGFloat
    let iconOnly: CGFloat?
    /// With the short label (Auto, Std, Ask…); `full` when the chip has none.
    var short: CGFloat? = nil
    /// With the short label and no glyph ("Auto", "Std").
    var bare: CGFloat? = nil
    /// The narrowest a model chip may truncate to.
    var minimum: CGFloat? = nil
}

/// Which chips go where, which use their short label, which only their icon, and how far the
/// model chip may be truncated.
struct ComposerChipPlan: Equatable {
    var first: [ComposerPicker]
    var second: [ComposerPicker] = []
    var icons: Set<ComposerPicker> = []
    var short: Set<ComposerPicker> = []
    /// Short labels shown without their glyph, so a narrow phone keeps every label.
    var bare: Set<ComposerPicker> = []
    var modelCap: CGFloat? = nil
    var twoRows: Bool { !second.isEmpty }
}

/// The chip row's layout for `available` points (the paperclip included), S25: full labels;
/// then short labels (Auto, Std, Full); then the model truncated before any label goes; icons
/// only when even short labels can't fit; otherwise the model on its own row.
func composerChipPlan(widths: [ComposerChipWidth], available: CGFloat) -> ComposerChipPlan {
    let spacing: CGFloat = 4, attach: CGFloat = 44
    let labelled: Set<ComposerPicker> = [.effort, .speed, .access]
    let shortKinds = Set(widths.filter { $0.short != nil && labelled.contains($0.kind) }.map(\.kind))
    let iconKinds = Set(widths.filter { $0.iconOnly != nil && labelled.contains($0.kind) }.map(\.kind))
    func w(_ c: ComposerChipWidth, short: Set<ComposerPicker>, icons: Set<ComposerPicker>, bare: Set<ComposerPicker> = []) -> CGFloat {
        if icons.contains(c.kind), let icon = c.iconOnly { return icon }
        if bare.contains(c.kind), let b = c.bare { return b }
        if short.contains(c.kind), let s = c.short { return s }
        return c.full
    }
    func total(_ items: [ComposerChipWidth], short: Set<ComposerPicker>, icons: Set<ComposerPicker>, bare: Set<ComposerPicker> = []) -> CGFloat {
        items.reduce(0) { $0 + spacing + w($1, short: short, icons: icons, bare: bare) }
    }
    let kinds = widths.map(\.kind)
    // 1. Full labels, 2. short labels.
    for short in [Set<ComposerPicker>(), shortKinds] where attach + total(widths, short: short, icons: []) <= available {
        return ComposerChipPlan(first: kinds, short: short)
    }
    // 3. Short labels with the model truncated, down to its minimum; then the same without the
    //    effort and access glyphs, then without the speed glyph too: labels outlast glyphs.
    let bareKinds = Set(widths.filter { $0.bare != nil && labelled.contains($0.kind) }.map(\.kind))
    let bareSteps: [Set<ComposerPicker>] = [[], bareKinds.subtracting([.speed]), bareKinds]
    if let model = widths.first(where: { $0.kind == .model }), let minimum = model.minimum {
        let others = widths.filter { $0.kind != .model }
        for bare in bareSteps {
            let cap = available - attach - total(others, short: shortKinds, icons: [], bare: bare) - spacing
            if cap >= model.full { return ComposerChipPlan(first: kinds, short: shortKinds, bare: bare) }
            if cap >= minimum { return ComposerChipPlan(first: kinds, short: shortKinds, bare: bare, modelCap: cap) }
        }
    }
    // 4. Icons only, the model truncated if need be.
    if attach + total(widths, short: [], icons: iconKinds) <= available {
        return ComposerChipPlan(first: kinds, icons: iconKinds)
    }
    if let model = widths.first(where: { $0.kind == .model }), let minimum = model.minimum {
        let cap = available - attach - total(widths.filter { $0.kind != .model }, short: [], icons: iconKinds) - spacing
        if cap >= minimum { return ComposerChipPlan(first: kinds, icons: iconKinds, modelCap: cap) }
    }
    // 5. Large text: the model (and provider) beside the paperclip, the rest below.
    let lead = widths.filter { $0.kind == .model || $0.kind == .provider }
    let rest = widths.filter { $0.kind != .model && $0.kind != .provider }
    let room = available + attach
    if total(rest, short: [], icons: []) - spacing <= room {
        return ComposerChipPlan(first: lead.map(\.kind), second: rest.map(\.kind))
    }
    if total(rest, short: shortKinds, icons: []) - spacing <= room {
        return ComposerChipPlan(first: lead.map(\.kind), second: rest.map(\.kind), short: shortKinds)
    }
    return ComposerChipPlan(first: lead.map(\.kind), second: rest.map(\.kind), icons: iconKinds)
}

/// The model chip: the chosen model, else the one an unset choice runs (the catalog's first);
/// the provider's default row reads the model the core names ("Opus 5.5"), else "Auto" (I10-1).
func composerModelLabel(_ models: [ChatChoice], value: String?, defaultLabel: String? = nil) -> String {
    let id = (value?.isEmpty == false ? value : nil) ?? models.first?.id
    guard let id else { return composerDefaultLabel(defaultLabel) }
    if isDefaultChoice(id) { return composerDefaultLabel(defaultLabel) }
    return composerChoiceLabel(models, value: id)
}

/// The model a chip names: what runs ("Opus 5.5").
func composerResolvedModel(_ models: [ChatChoice], value: String?, defaultLabel: String?) -> String {
    composerModelLabel(models, value: value, defaultLabel: defaultLabel)
}

/// The effort a chip names: the chosen one, else the default's resolved effort ("High"), else "Auto".
func composerResolvedEffort(_ efforts: [ChatChoice], value: String?, defaultLabel: String?) -> String {
    let label = composerEffortLabel(efforts, value: value, defaultLabel: defaultLabel)
    return label.hasPrefix("Auto · ") ? String(label.dropFirst("Auto · ".count)) : label
}

/// The effort a picker or New chat row names (S25): the chosen effort, else "Auto" (the
/// provider's default), "Auto · High" when the core names it. Never a bare "Default".
func composerEffortLabel(_ efforts: [ChatChoice], value: String?, defaultLabel: String? = nil) -> String {
    guard let value, !isDefaultChoice(value) else {
        guard let defaultLabel, !defaultLabel.isEmpty else { return "Auto" }
        return "Auto · " + defaultLabel
    }
    return composerChoiceLabel(efforts, value: value)
}

/// The short chip labels, the same table as Android (S25): effort Low/Med/High/Auto, speed
/// Std/Fast, access Ask (supervised) / Full.
func composerShortLabel(_ kind: ComposerPicker, id: String?, label: String) -> String {
    let value = (id ?? "").lowercased()
    switch kind {
    case .effort:
        switch value {
        case "", "default": return "Auto"
        case "low": return "Low"
        case "medium": return "Med"
        case "high": return "High"
        case "xhigh", "extra-high": return "XHigh"
        case "max": return "Max"
        case "minimal": return "Min"
        case "none": return "None"
        default: return String(label.prefix(4))
        }
    case .speed: return value == "on" ? "Fast" : "Std"
    case .access: return value == "supervised" ? "Ask" : "Full"
    default: return label
    }
}

/// The access mode in effect ("Full access" when unset).
func composerResolvedAccess(_ choices: [ChatChoice], value: String?) -> String {
    let id = (value?.isEmpty == false ? value : nil) ?? defaultAccessID
    return composerChoiceLabel(choices, value: id)
}

/// The access label: "Supervised" or "Full access"; unset reads the host default it resolves to (I10-1).
func composerAccessLabel(_ choices: [ChatChoice], value: String?) -> String {
    if let value, !value.isEmpty { return composerChoiceLabel(choices, value: value) }
    return choices.first { $0.id == defaultAccessID }?.label ?? "Full access"
}

/// A picker row's label (I10-1, I10-2): effort's default row reads "Auto", the model's default row
/// the model it runs, speed "Standard" / "Fast", and the host's default "(default)".
func composerPickerLabel(_ kind: ComposerPicker, _ choice: ChatChoice, defaultModel: String? = nil) -> String {
    switch kind {
    case .effort: return isDefaultChoice(choice.id) ? "Auto" : choice.label
    case .model: return isDefaultChoice(choice.id) ? composerDefaultMarked(composerDefaultLabel(defaultModel)) : choice.label
    case .speed:
        guard choice.id == "off" || choice.id == "on" else { return choice.label }
        return choice.id == "off" ? composerDefaultMarked(composerSpeedLabel(choice.id)) : composerSpeedLabel(choice.id)
    case .access: return choice.id == defaultAccessID ? composerDefaultMarked(choice.label) : choice.label
    case .provider: return choice.label
    }
}

/// The option a picker marks as current: the selection, else what an unset value means.
func composerCurrentChoice(_ picker: ComposerPicker, value: String?, choices: [ChatChoice] = []) -> String {
    if let value, !value.isEmpty { return value }
    if picker == .access { return defaultAccessID }
    // Unset means the catalog's default row: the "" choice, else (models) the first one, which the
    // core sends when nothing is picked (I3-11).
    if choices.isEmpty || choices.contains(where: { $0.id.isEmpty }) { return "" }
    return picker == .model ? choices[0].id : ""
}

/// One row of the "/" or "@" suggestion list.
struct ComposerSuggestion: Identifiable, Equatable {
    let id: String
    let label: String
    /// What is inserted: the command name or the file path.
    let value: String
    let detail: String?
    let enabled: Bool
}

/// Matching commands or files, de-duplicated by id and label (a host can list a command twice).
func composerSuggestions(_ token: ComposerToken, mentions: [ChatMention], slash: [ChatChoice]) -> [ComposerSuggestion] {
    var seen = Set<String>()
    var out: [ComposerSuggestion] = []
    if token.marker == "@" {
        // The host's search may return everything (I6-7): keep the files the query matches,
        // substring matches first, then those whose letters appear in order.
        for item in rankedMentions(mentions, query: token.query) where seen.insert(item.path).inserted {
            let folder = (item.path as NSString).deletingLastPathComponent
            out.append(ComposerSuggestion(id: item.path, label: item.label, value: item.path, detail: folder.isEmpty ? nil : folder, enabled: true))
        }
    } else {
        for item in slash where token.query.isEmpty || item.label.localizedCaseInsensitiveContains(token.query) {
            guard seen.insert(item.id).inserted, seen.insert("label:" + item.label).inserted else { continue }
            out.append(ComposerSuggestion(id: item.id, label: item.label, value: item.label, detail: item.reason, enabled: item.enabled))
        }
    }
    return out
}

/// Files matching `query` (case-insensitive): name or path containing it, then fuzzy matches.
func rankedMentions(_ mentions: [ChatMention], query: String) -> [ChatMention] {
    let q = query.lowercased()
    guard !q.isEmpty else { return mentions }
    func contains(_ m: ChatMention) -> Bool { m.label.lowercased().contains(q) || m.path.lowercased().contains(q) }
    func fuzzy(_ m: ChatMention) -> Bool {
        var rest = Substring(q)
        for ch in m.path.lowercased() where ch == rest.first { rest = rest.dropFirst(); if rest.isEmpty { return true } }
        return false
    }
    let direct = mentions.filter(contains)
    return direct + mentions.filter { !contains($0) && fuzzy($0) }
}

/// The "/" commands or "@" files as one vertical list of 44-point rows (S5).
private struct ComposerSuggestionList: View {
    let items: [ComposerSuggestion]
    let files: Bool
    let accept: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(files ? "Files" : "Commands").font(VerdeTheme.ui(13, bold: true)).foregroundStyle(VerdeTheme.muted)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            if items.count > 4 {
                ScrollView { rows }.frame(height: 44 * 4.5)
            } else {
                rows
            }
        }
        .background(VerdeTheme.alternate, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("composer-suggestions")
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                Button { accept(item.value) } label: { row(item) }
                    .buttonStyle(.plain)
                    .disabled(!item.enabled)
            }
        }
    }

    private func row(_ item: ComposerSuggestion) -> some View {
        HStack(spacing: 8) {
            Text(item.label).font(files ? VerdeTheme.ui(14) : VerdeTheme.mono(14)).lineLimit(1)
            if let detail = item.detail {
                Text(detail).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .opacity(item.enabled ? 1 : 0.5)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The Companion sheet's single-row composer: placeholder, a live voice transcript shown in place
/// of the field, a voice notice, and trailing controls (the mic).
struct CompactComposer {
    var placeholder: String
    var transcript: String?
    var level: Double = 0
    var notice: String?
    var trailing: AnyView?
    /// Set for the Companion: the brain chip is a read-only label that opens its settings, and
    /// the "+" menu keeps only attach and access.
    var openBrain: (() -> Void)? = nil
    /// The brain's one name (I6-6); the chip shows it instead of the model alone.
    var brainName: String? = nil
}

/// "Haiku 5.5 · Low": the model and effort as one chip label.
func composerChipLabel(model: String, effort: String?) -> String {
    guard let effort, !effort.isEmpty, effort != "Default", effort != "Auto" else { return model }
    return model + " · " + effort
}

struct ChatComposer: View {
    let model: ComposerModel
    let availableHeight: CGFloat
    /// The conversation's width; the chip row's layout is chosen from it (I7-1).
    var availableWidth: CGFloat = 0
    var compact: CompactComposer? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    /// Wide windows put the setting chips on the attach and send row. The text view keeps its
    /// place in the tree either way, so crossing the threshold keeps its text and keyboard focus.
    @Environment(\.adaptive) private var adaptive
    @State private var picker: ComposerPicker?
    /// The picker shown as a popover on its chip (I11-4, regular width).
    @State private var anchored: ComposerPicker?
    @State private var popoverRowsHeight: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var photo: PhotosPickerItem?
    /// The library picker is presented from the composer, not embedded in the attach menu: a
    /// `PhotosPicker` inside a `Menu` is torn down when the menu closes, so it never appears.
    @State private var photos = false
    @State private var files = false
    @State private var camera = false
    @State private var focused = false
    @State private var resizedHeight: CGFloat?
    @State private var dragStart: CGFloat?
    /// The text's own height; the field grows with it (a few lines) unless resized by hand.
    @State private var contentHeight: CGFloat = 0
    /// Two lines at the default size, more with larger text so glyphs are never cut off.
    @ScaledMetric(relativeTo: .body) private var basePrompt: CGFloat = 56

    var body: some View {
        Group {
            if let compact { compactBody(compact) } else { fullBody }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.flushNow() } }
        .onDisappear { model.flushNow() }
        .sheet(item: $picker) { kind in
            NavigationStack {
                let current = composerCurrentChoice(kind, value: selectedID(kind), choices: choices(kind))
                List(sortedChoices(kind), id: \.id) { choice in
                    Button { model.select(kind, choice.id); picker = nil } label: { pickerRow(kind, choice, current: current) }
                        .disabled(!choice.enabled)
                }.navigationTitle(kind.rawValue.capitalized).toolbar { BarButton("Done", bold: true) { picker = nil } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $camera) { ComposerCamera { image in camera = false; if let image { prepare(image) } } }
        .sheet(isPresented: Binding(get: { model.view?.shell_confirmation != nil }, set: { shown in
            if !shown, let confirmation = model.view?.shell_confirmation { model.confirmShell(confirmation, accept: false) }
        })) {
            if let confirmation = model.view?.shell_confirmation {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Run this command on the host?") .font(VerdeTheme.ui(15, bold: true))
                        Text(confirmation.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Text(confirmation.cwd) .font(VerdeTheme.ui(12))
                        HStack { Button("Cancel") { model.confirmShell(confirmation, accept: false) }; Spacer(); Button("Run") { model.confirmShell(confirmation, accept: true) }.buttonStyle(PrimaryButtonStyle(fullWidth: false)) }
                    }.padding().disabled(model.busy)
                }.presentationDetents([.medium])
            }
        }
        .photosPicker(isPresented: $photos, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            Task {
                guard let item else { return }
                defer { photo = nil }
                guard let data = try? await item.loadTransferable(type: Data.self), data.count <= 24 * 1024 * 1024, let image = UIImage(data: data) else { model.notice = "This image couldn't be opened."; return }
                prepare(image)
            }
        }
        .fileImporter(isPresented: $files, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 24 * 1024 * 1024,
                  let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { model.notice = "Only images can be attached from the phone."; return }
            prepare(image)
        }
    }

    /// Follow-up, notice, slash/mention suggestions and attachments (both layouts).
    @ViewBuilder private var extras: some View {
            if let followup = model.view?.followup, visibleFollowup(followup) {
                VStack(alignment: .leading) {
                    Text("\(followup.kind.capitalized) · \(followup.state)").font(.caption.bold())
                    Text(followup.text).lineLimit(3) .font(VerdeTheme.ui(12))
                    HStack {
                        if followup.can_retry { Button("Retry") { model.followup("retry", followup) } }
                        if followup.can_pull_back { Button("Pull back") { model.followup("pull", followup) } }
                        Button("Remove") { model.followup("cancel", followup) }
                    }.disabled(model.busy)
                }.accessibilityIdentifier("composer-followup")
            }
            if let notice = model.notice ?? model.view?.error?.message {
                Text(notice) .font(VerdeTheme.ui(12)).foregroundStyle(.red).accessibilityIdentifier("composer-notice")
            }
            if let token = model.token {
                let items = composerSuggestions(token, mentions: model.view?.mentions ?? [], slash: model.view?.catalogs.slash ?? [])
                if !items.isEmpty { ComposerSuggestionList(items: items, files: token.marker == "@") { model.accept($0) } }
            }
            if let attachments = model.view?.draft.attachments, !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(attachments, id: \.local_id) { item in
                            HStack {
                                if let data = model.previews[item.local_id], let image = UIImage(data: data) {
                                    Image(uiImage: image).resizable().scaledToFit().frame(width: 44, height: 44)
                                }
                                Text(item.name) .font(VerdeTheme.ui(12))
                                Button { model.detach(item.local_id) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(VerdeTheme.muted).minTarget()
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(item.name)").disabled(model.busy || model.pending)
                            }
                        }
                    }
                }
            }
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            extras
            Capsule().fill(VerdeTheme.border).frame(width: 40, height: 4)
                .frame(maxWidth: .infinity).frame(height: adaptive.tier.wide ? 14 : 24).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                    if dragStart == nil { dragStart = promptHeight }
                    resizedHeight = composerPromptHeight((dragStart ?? basePrompt) - value.translation.height, available: availableHeight, minimum: basePrompt)
                }.onEnded { _ in dragStart = nil })
                .onTapGesture(count: 2) { resizedHeight = nil }
                .accessibilityElement().accessibilityLabel("Resize prompt box")
                .accessibilityValue("\(Int(promptHeight)) points")
                .accessibilityHint("Drag up to expand, down to shrink, or double-tap to reset.")
                .accessibilityAction(named: "Expand prompt box") { resizePrompt(56) }
                .accessibilityAction(named: "Shrink prompt box") { resizePrompt(-56) }
                .accessibilityAction(named: "Reset prompt box size") { resizedHeight = nil }
                .accessibilityIdentifier("composer-resize")
            ComposerText(text: model.text, selection: model.selection, editable: !model.pending, edit: model.edit, focus: { focused = $0 },
                         height: { height in if abs(height - contentHeight) > 1 { contentHeight = height } })
                .frame(height: promptHeight)
                .overlay(alignment: .topLeading) {
                    if model.text.isEmpty {
                        Text(composerPlaceholder(followupKind))
                            .font(VerdeTheme.ui()).foregroundStyle(VerdeTheme.subtle).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier("composer-field")
            // S11: one row, paperclip first, chips with their resolved values, then Stop / Send.
            // The chips wrap onto another line only when they don't fit (large text).
            HStack(alignment: .bottom, spacing: 4) {
                // S18/S25: one row at the default text size, labels shortening before they go. The
                // choice is computed from the conversation's width and the text size, never from
                // measuring the chips, so no layout pass can change it (I7-1: measured layouts
                // looped at 100% CPU). Wide windows and iPad use the same plan in the 720-point
                // column (S28).
                chipRows(composerChipPlan(widths: chipWidths(), available: chipRowWidth))
                Spacer(minLength: 4)
                // One 44-point action slot (I8-1, I8-3): Send, or Stop while a reply runs. With text
                // typed during a reply, Stop stacks above Send instead of widening the row, so the
                // chip layout never changes because a turn started or ended.
                VStack(spacing: 4) {
                    if running && model.canSubmit { stopButton }
                    if running && !model.canSubmit { stopButton } else { sendButton }
                }
            }
            if let line = composerHintLine(followupKind, text: model.text, followupShown: model.view?.followup.map(visibleFollowup) ?? false) {
                Text(line).font(VerdeTheme.ui(12)).foregroundStyle(.secondary).accessibilityIdentifier("composer-action-hint")
            }
        }
        .padding(12)
        .background(VerdeTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(focused ? VerdeTheme.accent : VerdeTheme.mutedPanel, lineWidth: focused ? 1.5 : 1))
        .padding(8)
        // Never wider than the conversation (I8-2): an over-wide row would widen the whole screen.
        .frame(maxWidth: availableWidth > 0 ? availableWidth : nil)
    }

    /// Width left for the paperclip and chips: the composer card minus its margins and padding,
    /// the action slot and its spacing, and a margin for estimate error (I8-2).
    private var chipRowWidth: CGFloat {
        let column = adaptive.tier.wide && compact == nil ? min(availableWidth, transcriptTextWidth + 16) : availableWidth
        return max(0, column - 16 - 24 - (44 + 12) - 12)
    }

    private var running: Bool { model.chat.state.turn != nil }

    private var stopButton: some View {
        Button(action: model.chat.stopTurn) {
            Image(systemName: "stop.fill").font(.system(size: 10)).foregroundStyle(VerdeTheme.background)
                .frame(width: 44, height: 44).background(VerdeTheme.warning, in: Circle())
                // I10-6: no pulse while the turn waits on an approval; nothing is working then.
                .modifier(Pulse(active: !model.chat.state.stopping && model.chat.state.thread?.approval == nil, minimum: 0.74, period: 1.4))
        }
        .buttonStyle(.plain).disabled(!model.chat.state.canStop).accessibilityLabel("Stop")
    }

    private var sendButton: some View {
        Button(action: model.submit) {
            Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold))
                .foregroundStyle(model.canSubmit ? VerdeTheme.onAccent : VerdeTheme.disabledContent)
                .frame(width: 44, height: 44)
                .background(model.canSubmit ? VerdeTheme.accent : VerdeTheme.disabledFill, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canSubmit).accessibilityLabel(sendLabel).accessibilityHint(sendHint)
        .accessibilityIdentifier("composer-send")
        .contextMenu { sendAlternatives }
    }

    /// Estimated chip widths (full label, icon only) from font metrics at the current text size.
    private func chipWidths() -> [ComposerChipWidth] {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let size = UIFontMetrics(forTextStyle: .body).scaledValue(for: 12, compatibleWith: traits)
        let font = UIFont(name: "NotoSans-Regular", size: size) ?? .systemFont(ofSize: size)
        func measure(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        return visiblePickers.map { kind in
            // The provider glyph grows with text (ProviderGlyph), plus its 6-point gap.
            let providerGlyph = providerGlyphSize(UIFontMetrics(forTextStyle: .footnote).scaledValue(for: 18, compatibleWith: traits)) + 6
            let glyph: CGFloat = kind == .model || kind == .provider ? providerGlyph : 0
            let icon: CGFloat = hasChipIcon(kind) ? 22 : 0
            let full = glyph + icon + measure(chipDisplay(chipText(kind), limit: kind == .model ? 22 : 28)) + 20
            let short = [.effort, .speed, .access].contains(kind) ? glyph + icon + measure(shortChipText(kind)) + 20 : nil
            let bare = short != nil && icon > 0 ? max(44, measure(shortChipText(kind)) + 20) : nil
            let minimum: CGFloat? = kind == .model ? glyph + measure("GPT-6…") + 20 : nil
            return ComposerChipWidth(kind: kind, full: full, iconOnly: hasChipIcon(kind) ? 44 : nil, short: short, bare: bare, minimum: minimum)
        }
    }

    @ViewBuilder private func chipRows(_ plan: ComposerChipPlan) -> some View {
        if plan.twoRows {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    attachMenu
                    ForEach(plan.first, id: \.self) { kind in planChip(kind, plan) }
                }
                HStack(spacing: 4) {
                    ForEach(plan.second, id: \.self) { kind in planChip(kind, plan) }
                }
            }
        } else {
            HStack(spacing: 4) {
                attachMenu
                ForEach(plan.first, id: \.self) { kind in planChip(kind, plan) }
            }
        }
    }

    @ViewBuilder private func planChip(_ kind: ComposerPicker, _ plan: ComposerChipPlan) -> some View {
        let chip = settingButton(kind, compact: plan.icons.contains(kind), stretch: false, short: plan.short.contains(kind), bare: plan.bare.contains(kind))
        if kind == .model, let cap = plan.modelCap { chip.frame(maxWidth: cap, alignment: .leading) } else { chip }
    }

    private func shortChipText(_ kind: ComposerPicker) -> String {
        composerShortLabel(kind, id: kind == .speed ? (selectedID(kind) ?? "off") : composerCurrentChoice(kind, value: selectedID(kind), choices: choices(kind)), label: chipText(kind))
    }

    private func hasChipIcon(_ kind: ComposerPicker) -> Bool { kind == .speed || settingIcon(kind) != nil }

    private var attachMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo") { photos = true }
            Button("Camera", systemImage: "camera") { openCamera() }
            Button("Files", systemImage: "folder") { files = true }
        } label: { Image(systemName: "paperclip").frame(width: 44, height: 44).accessibilityLabel("Attach image") }
            .accessibilityLabel("Attach image").disabled(model.busy || model.pending)
    }

    /// The input on its own full-width row, then one compact row: "+", the brain chip, the mic,
    /// stop (while running) and send.
    private func compactBody(_ compact: CompactComposer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            extras
            if let notice = compact.notice {
                Text(notice).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning).lineLimit(2)
            }
            compactField(compact)
            HStack(alignment: .center, spacing: 2) {
                plusMenu(brainLocked: compact.openBrain != nil)
                if model.view != nil {
                    // The brain's name may take two lines at large text instead of being cut (I7-4).
                    Group {
                        if let openBrain = compact.openBrain { brainLabelChip(openBrain, name: compact.brainName) } else { settingsChip }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                }
                Spacer(minLength: 4)
                if let trailing = compact.trailing { trailing }
                if model.chat.state.turn != nil {
                    Button(action: model.chat.stopTurn) {
                        Image(systemName: "stop.fill").font(.system(size: 10)).foregroundStyle(VerdeTheme.background)
                            .frame(width: 32, height: 32).background(VerdeTheme.warning, in: Circle())
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!model.chat.state.canStop).accessibilityLabel("Stop")
                }
                Button(action: model.submit) {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(model.canSubmit ? VerdeTheme.onAccent : VerdeTheme.disabledContent)
                        .frame(width: 32, height: 32)
                        .background(model.canSubmit ? VerdeTheme.accent : VerdeTheme.disabledFill, in: Circle())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canSubmit).accessibilityLabel(sendLabel).accessibilityHint(sendHint)
                .accessibilityIdentifier("composer-send")
                .contextMenu { sendAlternatives }
            }
        }
        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
        .background(VerdeTheme.panel)
        .overlay(alignment: .top) { Divider().overlay(VerdeTheme.border) }
    }

    @ViewBuilder private func compactField(_ compact: CompactComposer) -> some View {
        Group {
            if let transcript = compact.transcript {
                HStack(spacing: 8) {
                    LevelMeter(level: compact.level)
                    Text(transcript.isEmpty ? "Listening…" : transcript)
                        .font(VerdeTheme.ui(15)).foregroundStyle(transcript.isEmpty ? VerdeTheme.subtle : VerdeTheme.text)
                        .lineLimit(6).frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(transcript.isEmpty ? "Listening" : "Heard: " + transcript)
            } else {
                TextField(followupKind.map { $0.hint + "…" } ?? compact.placeholder,
                          text: Binding(get: { model.text }, set: { value in
                              model.edit(value, selection: NSRange(location: (value as NSString).length, length: 0))
                          }), axis: .vertical)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1...3 : 1...6)
                    .font(VerdeTheme.ui(15))
                    // The field itself is the 44-point target, not only its pill.
                    .frame(minHeight: 44).contentShape(Rectangle())
                    .disabled(model.pending)
                    .accessibilityLabel("Message")
                    // I12-5: distinct from the chat's own composer when both are on screen.
                    .accessibilityIdentifier("companion-composer-field")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, compact.transcript == nil ? 2 : 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(VerdeTheme.alternate, in: RoundedRectangle(cornerRadius: 18))
    }

    /// Attach, plus the rarely changed pickers (provider on a fresh chat, access, speed).
    private func plusMenu(brainLocked: Bool) -> some View {
        Menu {
            Section {
                Button("Photos", systemImage: "photo") { photos = true }
                Button("Camera", systemImage: "camera") { openCamera() }
                Button("Files", systemImage: "folder") { files = true }
            }
            Section {
                ForEach(visiblePickers.filter { brainLocked ? $0 == .access : ($0 != .model && $0 != .effort) }) { kind in
                    Button { picker = kind } label: { Text("\(kind.rawValue.capitalized): \(selectionLabel(kind))") }
                }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
        }
        .disabled(model.busy || model.pending)
        .accessibilityLabel("More options")
        .accessibilityHint("Attach an image or change access.")
        .accessibilityIdentifier("composer-more")
    }

    /// The Companion's brain, read-only here: changing it lives in Settings → Brain.
    private func brainLabelChip(_ open: @escaping () -> Void, name: String?) -> some View {
        let label = name ?? composerChipLabel(model: selectionLabel(.model), effort: visiblePickers.contains(.effort) ? selectionLabel(.effort) : nil)
        return Button(action: open) {
            HStack(spacing: 5) {
                ProviderGlyph(provider: model.displayedSelection?.provider).scaleEffect(0.8)
                // One line at every size: it shrinks, then truncates in the middle.
                Text(label).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted).lineLimit(1)
                    .minimumScaleFactor(0.7).truncationMode(.middle)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Brain: \(label)")
        .accessibilityHint("Opens companion settings to change the brain.")
        .accessibilityIdentifier("composer-brain")
    }

    /// "Haiku 5.5 · Low": opens the existing model and effort pickers.
    @ViewBuilder private var settingsChip: some View {
        let label = composerChipLabel(model: selectionLabel(.model), effort: visiblePickers.contains(.effort) ? selectionLabel(.effort) : nil)
        let chip = HStack(spacing: 5) {
            ProviderGlyph(provider: model.displayedSelection?.provider).scaleEffect(0.8)
            Text(label).font(VerdeTheme.ui(12)).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(VerdeTheme.subtle)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(VerdeTheme.alternate, in: Capsule())
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        Group {
            if visiblePickers.contains(.effort) {
                Menu {
                    Button("Model: \(selectionLabel(.model))") { picker = .model }
                    Button("Effort: \(selectionLabel(.effort))") { picker = .effort }
                } label: { chip }
            } else {
                Button { picker = .model } label: { chip }.buttonStyle(.plain)
            }
        }
        .padding(.leading, 6)
        .disabled(model.busy || model.pending)
        .accessibilityLabel("Model and effort: \(label). Change")
        .accessibilityIdentifier("composer-setting-model")
    }

    private var hasImages: Bool { model.view?.draft.attachments.isEmpty == false }
    /// How Send delivers while a turn runs (nil when nothing is running).
    private var followupKind: FollowupKind? {
        guard model.chat.state.turn != nil else { return nil }
        return composerFollowupKind(provider: model.displayedSelection?.provider, images: hasImages)
    }
    private var sendLabel: String { followupKind?.label ?? "Send" }
    private var sendHint: String { followupKind?.hint ?? "Sends your message." }

    /// Long-press on Send while a turn runs: the other ways to deliver this message.
    @ViewBuilder private var sendAlternatives: some View {
        if model.chat.state.turn != nil {
            ForEach(followupAlternatives(provider: model.displayedSelection?.provider, images: hasImages), id: \.self) { kind in
                Button { model.submit(voice: false, followup: kind) } label: { Label(kind.insteadLabel, systemImage: followupIcon(kind)) }
                    .disabled(!model.canSubmit)
            }
        }
    }

    private func followupIcon(_ kind: FollowupKind) -> String {
        switch kind {
        case .steer: return "arrow.turn.down.right"
        case .interrupt: return "bolt"
        case .queue: return "text.line.last.and.arrowtriangle.forward"
        }
    }
    private var promptHeight: CGFloat {
        let natural = min(max(basePrompt, contentHeight), basePrompt * 3)
        return composerPromptHeight(resizedHeight ?? natural, available: availableHeight, minimum: basePrompt)
    }
    private func resizePrompt(_ delta: CGFloat) { resizedHeight = composerPromptHeight(promptHeight + delta, available: availableHeight, minimum: basePrompt) }
    private func sortedChoices(_ kind: ComposerPicker) -> [ChatChoice] { choices(kind).sorted { $0.favorite && !$1.favorite } }

    private func pickerRow(_ kind: ComposerPicker, _ choice: ChatChoice, current: String) -> some View {
        PickerRow(glyph: AnyView(pickerGlyph(kind, value: choice.id)), choice: pickerChoice(kind, choice), selected: choice.id == current,
                  subtitle: isDefaultChoice(choice.id) ? defaultSubtitle(kind) : nil)
    }

    /// I11-4: on regular widths a picker is a popover on its chip, as tall as its rows (up to a
    /// cap, then it scrolls, its indicator flashing so more rows read as more).
    private func pickerPopover(_ kind: ComposerPicker) -> some View {
        let current = composerCurrentChoice(kind, value: selectedID(kind), choices: choices(kind))
        return VStack(spacing: 0) {
            HStack {
                Text(kind.rawValue.capitalized).font(VerdeTheme.ui(15, bold: true)).accessibilityAddTraits(.isHeader)
                Spacer()
                BarButton("Done", bold: true) { anchored = nil }
            }.padding(.leading, 16).padding(.trailing, 6)
            Divider().overlay(VerdeTheme.border)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sortedChoices(kind), id: \.id) { choice in
                        Button { model.select(kind, choice.id); anchored = nil } label: {
                            pickerRow(kind, choice, current: current).padding(.horizontal, 16).padding(.vertical, 4)
                        }.buttonStyle(.plain).disabled(!choice.enabled)
                    }
                }.onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { popoverRowsHeight = $0 }
            }
            .scrollIndicatorsFlash(onAppear: true)
            .frame(height: popoverRowsHeight > 0 ? min(popoverRowsHeight, 480) : nil)
        }
        .frame(width: 340)
        .background(VerdeTheme.background)
        .presentationCompactAdaptation(.popover)
    }

    private func openPicker(_ kind: ComposerPicker) {
        if horizontalSizeClass == .regular { anchored = kind } else { picker = kind }
    }

    private func settingButton(_ kind: ComposerPicker, compact: Bool, stretch: Bool = true, short: Bool = false, bare: Bool = false) -> some View {
        Button { openPicker(kind) } label: {
            HStack(spacing: 6) {
                if kind == .model { ProviderGlyph(provider: model.displayedSelection?.provider) }
                // S25: a bolt for Fast and a gauge for Standard, not a bare ring.
                if bare {
                    EmptyView()
                } else if kind == .speed {
                    Image(systemName: selectedID(kind) == "on" ? "bolt.fill" : "gauge.with.dots.needle.33percent")
                        .font(.system(size: 13, weight: .semibold)).frame(width: 16, height: 16).accessibilityHidden(true)
                } else if let icon = settingIcon(kind) {
                    ComposerGlyph(name: icon).opacity(0.32)
                        .overlay(alignment: .bottom) {
                            ComposerGlyph(name: icon).mask(alignment: .bottom) {
                                Rectangle().frame(height: 16 * settingFill(kind))
                            }
                        }.frame(width: 16, height: 16).accessibilityHidden(true)
                }
                if !compact {
                    Text(short ? shortChipText(kind) : chipDisplay(chipText(kind), limit: kind == .model ? 22 : 28))
                        .lineLimit(1).truncationMode(kind == .model ? .middle : .tail)
                }
            }.font(VerdeTheme.ui(12)).padding(.horizontal, compact ? 0 : 10)
                .frame(minWidth: 44, maxWidth: kind == .model && stretch ? .infinity : nil, minHeight: 44, alignment: kind == .model ? .leading : .center)
                .frame(width: compact ? 44 : nil)
                .background(VerdeTheme.alternate, in: Capsule())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(kind.rawValue.capitalized): \(selectionLabel(kind)). Change")
            .accessibilityIdentifier("composer-setting-" + kind.rawValue)
            .popover(isPresented: Binding(get: { anchored == kind }, set: { if !$0 && anchored == kind { anchored = nil } }), arrowEdge: .bottom) {
                pickerPopover(kind)
            }
    }
    private var visiblePickers: [ComposerPicker] {
        guard let view = model.view else { return [] }
        var kinds: [ComposerPicker] = []
        if model.chat.state.thread?.rows.isEmpty == true && model.chat.state.turn == nil { kinds.append(.provider) }
        kinds.append(.model)
        if !view.catalogs.efforts.isEmpty { kinds.append(.effort) }
        if view.catalogs.speeds.count > 1 { kinds.append(.speed) }
        if !view.catalogs.access.isEmpty { kinds.append(.access) }
        return kinds
    }
    @ViewBuilder private func pickerGlyph(_ kind: ComposerPicker, value: String) -> some View {
        if kind == .provider || kind == .model {
            ProviderGlyph(provider: kind == .provider ? value : model.displayedSelection?.provider)
        } else if let name = settingIcon(kind, value: value) {
            ComposerGlyph(name: name).opacity(0.32)
                .overlay(alignment: .bottom) {
                    ComposerGlyph(name: name).mask(alignment: .bottom) {
                        Rectangle().frame(height: 16 * settingFill(kind, value: value))
                    }
                }.frame(width: 16, height: 16).accessibilityHidden(true)
        }
    }
    private func selectedID(_ kind: ComposerPicker) -> String? {
        let s = model.displayedSelection
        switch kind {
        case .provider: return s?.provider
        case .model: return s?.model
        case .effort: return s?.effort
        case .access: return s?.access
        case .speed: return s?.speed
        }
    }
    private func selectionLabel(_ kind: ComposerPicker) -> String {
        let list = choices(kind)
        switch kind {
        case .access: return composerAccessLabel(list, value: selectedID(kind))
        case .model: return composerModelLabel(list, value: selectedID(kind), defaultLabel: model.view?.catalogs.default_model_label)
        case .effort: return composerEffortLabel(list, value: selectedID(kind), defaultLabel: model.view?.catalogs.default_effort_label)
        case .speed: return composerSpeedLabel(selectedID(kind))
        default: return composerChoiceLabel(list, value: selectedID(kind))
        }
    }
    /// What the picker's Default row runs, under its label ("Opus 5.5"; effort: "provider default").
    private func defaultSubtitle(_ kind: ComposerPicker) -> String? {
        switch kind {
        case .effort: return model.view?.catalogs.default_effort_label ?? "provider default"
        default: return nil
        }
    }

    /// Picker rows use the S25 words (I10-1, I10-2): effort's default row "Auto", the model's the
    /// model it runs, speed "Standard" / "Fast", and the host default marked "(default)".
    private func pickerChoice(_ kind: ComposerPicker, _ choice: ChatChoice) -> ChatChoice {
        var renamed = choice
        renamed.label = composerPickerLabel(kind, choice, defaultModel: model.view?.catalogs.default_model_label)
        return renamed
    }
    /// The chip's own text: the resolved value alone ("Full access").
    private func chipText(_ kind: ComposerPicker) -> String {
        let catalogs = model.view?.catalogs
        switch kind {
        case .access: return composerResolvedAccess(choices(kind), value: selectedID(kind))
        // S18: the chip shows the resolved value alone; the picker marks which row is the default.
        case .model: return composerResolvedModel(choices(kind), value: selectedID(kind), defaultLabel: catalogs?.default_model_label)
        case .effort: return composerResolvedEffort(choices(kind), value: selectedID(kind), defaultLabel: catalogs?.default_effort_label)
        default: return selectionLabel(kind)
        }
    }
    private func settingIcon(_ kind: ComposerPicker, value: String? = nil) -> String? {
        switch kind {
        case .effort: return "reasoning"
        case .access: return (value ?? selectedID(kind) ?? choices(kind).first?.id) == "full_access" ? "unlocked" : "locked"
        case .speed: return (value ?? selectedID(kind)) == "on" ? "fast" : "standard"
        default: return nil
        }
    }
    private func settingFill(_ kind: ComposerPicker, value: String? = nil) -> CGFloat {
        guard kind == .effort else { return 1 }
        let list = choices(kind)
        return CGFloat((list.firstIndex { $0.id == (value ?? selectedID(kind)) } ?? 0) + 1) / CGFloat(max(1, list.count))
    }
    private func choices(_ picker: ComposerPicker) -> [ChatChoice] {
        switch picker {
        case .provider: return ["codex", "claude", "cursor", "opencode", "pi", "fx", "grok", "antigravity", "muse"].map { ChatChoice(id: $0, label: $0.capitalized) }
        case .model: return model.view?.catalogs.models ?? []
        case .effort: return model.view?.catalogs.efforts ?? []
        case .access: return model.view?.catalogs.access ?? []
        case .speed: return model.view?.catalogs.speeds ?? []
        }
    }
    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { model.notice = "No camera is available."; return }
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            if allowed { camera = true } else { model.notice = "Allow camera access in Settings to take a photo." }
        }
    }
    private func prepare(_ image: UIImage) {
        guard let bytes = composerImage(image) else { model.notice = "This image is too large to attach."; return }
        model.attach(bytes)
    }
}

/// Re-encoding strips source metadata. 2048 points is the largest edge providers keep before
/// downscaling, so larger photos only cost upload time.
@MainActor
func composerImage(_ image: UIImage, maxBytes: Int = ComposerModel.maxImageBytes) -> Data? {
    guard image.size.width > 0, image.size.height > 0 else { return nil }
    var edge: CGFloat = 2048
    while edge >= 200 {
        let scale = min(1, edge / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size)); image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in [0.9, 0.75, 0.6, 0.45] {
            if let bytes = resized.jpegData(compressionQuality: quality), bytes.count <= maxBytes { return bytes }
        }
        edge *= 0.7
    }
    return nil
}

private struct ComposerText: UIViewRepresentable {
    let text: String
    let selection: NSRange
    let editable: Bool
    let edit: (String, NSRange) -> Void
    let focus: (Bool) -> Void
    /// The laid-out text height, reported after layout.
    var height: (CGFloat) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = MeasuredTextView()
        view.onContentHeight = { [weak coordinator = context.coordinator] height in coordinator?.parent.height(height) }
        view.delegate = context.coordinator; view.backgroundColor = .clear
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "NotoSans-Regular", size: 15) ?? .systemFont(ofSize: 15)); view.textColor = UIColor(VerdeTheme.text); view.tintColor = UIColor(VerdeTheme.accent); view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.accessibilityLabel = "Message"; view.accessibilityIdentifier = "composer-field"
        view.text = text; view.selectedRange = selection
        context.coordinator.applied = text
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.isEditable != editable { view.isEditable = editable }
        // Only a change of the model's text (a suggestion, a restored draft, a send) is pushed in.
        // An update rendered before the field reported its latest keystroke still carries the
        // previous text; applying it erased the first character typed right after focusing.
        guard text != context.coordinator.applied else { return }
        context.coordinator.applied = text
        // Never replace marked text while an IME is composing.
        if view.markedTextRange == nil && view.text != text { view.text = text; view.selectedRange = selection }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerText
        /// The model text the field was last updated with.
        var applied = ""
        init(_ parent: ComposerText) { self.parent = parent }
        func textViewDidBeginEditing(_ view: UITextView) { parent.focus(true) }
        func textViewDidEndEditing(_ view: UITextView) { parent.focus(false) }
        func textViewDidChange(_ view: UITextView) { parent.edit(view.text, view.selectedRange) }
        func textViewDidChangeSelection(_ view: UITextView) { parent.edit(view.text, view.selectedRange) }
    }
}

/// Reports its content height whenever layout changes it (text, width or Dynamic Type).
private final class MeasuredTextView: UITextView {
    var onContentHeight: ((CGFloat) -> Void)?
    private var reported: CGFloat = -1
    override func layoutSubviews() {
        super.layoutSubviews()
        let height = ceil(contentSize.height)
        guard abs(height - reported) > 0.5 else { return }
        reported = height
        let report = onContentHeight
        DispatchQueue.main.async { report?(height) }
    }
}

/// A picker sheet row: glyph, label, favourite star, reason and a checkmark on the current one.
private struct PickerRow: View {
    let glyph: AnyView
    let choice: ChatChoice
    let selected: Bool
    var subtitle: String? = nil

    var body: some View {
        HStack {
            glyph
            VStack(alignment: .leading, spacing: 1) {
                Text(choice.label).font(VerdeTheme.ui(15, bold: selected))
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted) }
            }
            if choice.favorite { Image(systemName: "star.fill").accessibilityLabel("Favorite") }
            Spacer()
            if let reason = choice.reason { Text(reason).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted) }
            if selected { Image(systemName: "checkmark").foregroundStyle(VerdeTheme.accent).accessibilityHidden(true) }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ComposerCamera: UIViewControllerRepresentable {
    let complete: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(complete) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let view = UIImagePickerController(); view.sourceType = .camera; view.delegate = context.coordinator; return view
    }
    func updateUIViewController(_ view: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let complete: (UIImage?) -> Void
        init(_ complete: @escaping (UIImage?) -> Void) { self.complete = complete }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { complete(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { complete(info[.originalImage] as? UIImage) }
    }
}

// Paths copied from Android composer_*.xml (desktop Symbols Nerd Font).
// See Resources/Licenses/SymbolsNerdFont-LICENSE.txt.
private struct ComposerGlyph: Shape {
    let name: String
    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch name {
        case "fast":
            path.move(to: CGPoint(x: 16.892744, y: 3.73943367))
            path.addLine(to: CGPoint(x: 13.885351, y: 10.7599386))
            path.addLine(to: CGPoint(x: 18.2499765, y: 10.7599386))
            path.addQuadCurve(to: CGPoint(x: 18.9676498, y: 10.9796345), control: CGPoint(x: 18.640547, y: 10.7599386))
            path.addQuadCurve(to: CGPoint(x: 19.421688, y: 11.5606082), control: CGPoint(x: 19.2947526, y: 11.1993305))
            path.addQuadCurve(to: CGPoint(x: 19.4607451, y: 12.3075743), control: CGPoint(x: 19.5583877, y: 11.9218859))
            path.addQuadCurve(to: CGPoint(x: 19.0701746, y: 12.9471335), control: CGPoint(x: 19.3631025, y: 12.6932627))
            path.addLine(to: CGPoint(x: 9.08133374, y: 21.695913))
            path.addQuadCurve(to: CGPoint(x: 8.30995698, y: 21.9986051), control: CGPoint(x: 8.7493488, y: 21.9790766))
            path.addQuadCurve(to: CGPoint(x: 7.50928743, y: 21.7642628), control: CGPoint(x: 7.87056515, y: 22.0181336))
            path.addQuadCurve(to: CGPoint(x: 7.03572068, y: 21.0856465), control: CGPoint(x: 7.1480097, y: 21.510392))
            path.addQuadCurve(to: CGPoint(x: 7.09918839, y: 20.2605663), control: CGPoint(x: 6.92343166, y: 20.6609011))
            path.addLine(to: CGPoint(x: 10.1065813, y: 13.2498256))
            path.addLine(to: CGPoint(x: 5.75172012, y: 13.2498256))
            path.addQuadCurve(to: CGPoint(x: 5.03892894, y: 13.0252476), control: CGPoint(x: 5.36114961, y: 13.2498256))
            path.addQuadCurve(to: CGPoint(x: 4.58000859, y: 12.4393918), control: CGPoint(x: 4.71670827, y: 12.8006695))
            path.addQuadCurve(to: CGPoint(x: 4.5360694, y: 11.6924257), control: CGPoint(x: 4.44330891, y: 12.0683498))
            path.addQuadCurve(to: CGPoint(x: 4.92175778, y: 11.0626308), control: CGPoint(x: 4.6288299, y: 11.3165016))
            path.addLine(to: CGPoint(x: 14.9301272, y: 2.3138513))
            path.addQuadCurve(to: CGPoint(x: 15.6917397, y: 2.00139489), control: CGPoint(x: 15.2621121, y: 2.02092342))
            path.addQuadCurve(to: CGPoint(x: 16.4826449, y: 2.2357372), control: CGPoint(x: 16.1213672, y: 1.98186637))
            path.addQuadCurve(to: CGPoint(x: 16.9562117, y: 2.91435347), control: CGPoint(x: 16.8439227, y: 2.48960803))
            path.addQuadCurve(to: CGPoint(x: 16.892744, y: 3.73943367), control: CGPoint(x: 17.0685007, y: 3.3390989))
            path.closeSubpath()
        case "standard":
            path.move(to: CGPoint(x: 12, y: 22))
            path.addQuadCurve(to: CGPoint(x: 17, y: 20.6621094), control: CGPoint(x: 14.65625, y: 22))
            path.addQuadCurve(to: CGPoint(x: 20.6523438, y: 17), control: CGPoint(x: 19.3242188, y: 19.3242188))
            path.addQuadCurve(to: CGPoint(x: 22, y: 12), control: CGPoint(x: 22, y: 14.6660156))
            path.addQuadCurve(to: CGPoint(x: 20.6523438, y: 7), control: CGPoint(x: 22, y: 9.33398438))
            path.addQuadCurve(to: CGPoint(x: 17, y: 3.33789062), control: CGPoint(x: 19.3242188, y: 4.67578125))
            path.addQuadCurve(to: CGPoint(x: 11.9951172, y: 2), control: CGPoint(x: 14.65625, y: 2))
            path.addQuadCurve(to: CGPoint(x: 7, y: 3.33789062), control: CGPoint(x: 9.33398438, y: 2))
            path.addQuadCurve(to: CGPoint(x: 3.328125, y: 7), control: CGPoint(x: 4.66601562, y: 4.67578125))
            path.addQuadCurve(to: CGPoint(x: 2, y: 12), control: CGPoint(x: 2, y: 9.32421875))
            path.addQuadCurve(to: CGPoint(x: 3.328125, y: 17), control: CGPoint(x: 2, y: 14.6757812))
            path.addQuadCurve(to: CGPoint(x: 7, y: 20.6621094), control: CGPoint(x: 4.66601562, y: 19.3242188))
            path.addQuadCurve(to: CGPoint(x: 12, y: 22), control: CGPoint(x: 9.33398438, y: 22))
            path.closeSubpath()
            path.move(to: CGPoint(x: 18.5429688, y: 12))
            path.addQuadCurve(to: CGPoint(x: 16.609375, y: 16.609375), control: CGPoint(x: 18.5429688, y: 14.6757812))
            path.addQuadCurve(to: CGPoint(x: 12, y: 18.5429688), control: CGPoint(x: 14.6757812, y: 18.5429688))
            path.addQuadCurve(to: CGPoint(x: 7.390625, y: 16.609375), control: CGPoint(x: 9.32421875, y: 18.5429688))
            path.addQuadCurve(to: CGPoint(x: 5.45703125, y: 12), control: CGPoint(x: 5.45703125, y: 14.6757812))
            path.addQuadCurve(to: CGPoint(x: 7.390625, y: 7.390625), control: CGPoint(x: 5.45703125, y: 9.32421875))
            path.addQuadCurve(to: CGPoint(x: 12, y: 5.45703125), control: CGPoint(x: 9.32421875, y: 5.45703125))
            path.addQuadCurve(to: CGPoint(x: 16.609375, y: 7.390625), control: CGPoint(x: 14.6757812, y: 5.45703125))
            path.addQuadCurve(to: CGPoint(x: 18.5429688, y: 12), control: CGPoint(x: 18.5429688, y: 9.32421875))
            path.closeSubpath()
            path.move(to: CGPoint(x: 12, y: 5.06640625))
            path.closeSubpath()
        case "reasoning":
            path.move(to: CGPoint(x: 21.259621, y: 13.3447288))
            path.addQuadCurve(to: CGPoint(x: 20.8200032, y: 15.5232793), control: CGPoint(x: 21.2986982, y: 14.4975044))
            path.addQuadCurve(to: CGPoint(x: 19.4229955, y: 17.2426733), control: CGPoint(x: 20.3217697, y: 16.5685927))
            path.addLine(to: CGPoint(x: 20.1556919, y: 18.6689889))
            path.addQuadCurve(to: CGPoint(x: 20.2240769, y: 20.100189), control: CGPoint(x: 20.5171554, y: 19.3919159))
            path.addQuadCurve(to: CGPoint(x: 19.198302, y: 21.0917714), control: CGPoint(x: 19.9309983, y: 20.8084622))
            path.addLine(to: CGPoint(x: 18.4167592, y: 21.3262342))
            path.addQuadCurve(to: CGPoint(x: 17.8696793, y: 21.4141578), control: CGPoint(x: 18.1822964, y: 21.4141578))
            path.addQuadCurve(to: CGPoint(x: 16.5801338, y: 20.769385), control: CGPoint(x: 17.0783673, y: 21.4141578))
            path.addLine(to: CGPoint(x: 14.5188147, y: 18.3466025))
            path.addQuadCurve(to: CGPoint(x: 12.1351093, y: 17.2915197), control: CGPoint(x: 13.190192, y: 18.1121396))
            path.addQuadCurve(to: CGPoint(x: 10.6697166, y: 17.4771361), control: CGPoint(x: 11.4219515, y: 17.4771361))
            path.addQuadCurve(to: CGPoint(x: 8.24693408, y: 16.7444398), control: CGPoint(x: 9.34109394, y: 17.4771361))
            path.addQuadCurve(to: CGPoint(x: 6.64477142, y: 16.9202869), control: CGPoint(x: 7.50446846, y: 16.9593641))
            path.addQuadCurve(to: CGPoint(x: 4.41737456, y: 16.4904384), control: CGPoint(x: 5.462688, y: 16.9593641))
            path.addQuadCurve(to: CGPoint(x: 2.69798049, y: 15.0641229), control: CGPoint(x: 3.34275326, y: 16.0019742))
            path.addQuadCurve(to: CGPoint(x: 2.01413057, y: 12.9832653), control: CGPoint(x: 2.05320771, y: 14.1262716))
            path.addQuadCurve(to: CGPoint(x: 2.38536338, y: 10.9219463), control: CGPoint(x: 1.92620701, y: 11.8891054))
            path.addQuadCurve(to: CGPoint(x: 2.28767054, y: 8.6261644), control: CGPoint(x: 1.92620701, y: 9.7594014))
            path.addQuadCurve(to: CGPoint(x: 4.21221958, y: 6.42807539), control: CGPoint(x: 2.84451975, y: 7.19007958))
            path.addQuadCurve(to: CGPoint(x: 5.70692011, y: 4.45467992), control: CGPoint(x: 4.62252953, y: 5.19714554))
            path.addQuadCurve(to: CGPoint(x: 8.1101641, y: 3.80990714), control: CGPoint(x: 6.77177212, y: 3.72198358))
            path.addQuadCurve(to: CGPoint(x: 10.9041795, y: 2.59851587), control: CGPoint(x: 9.29224752, y: 2.71574728))
            path.addQuadCurve(to: CGPoint(x: 13.7861184, y: 3.44844362), control: CGPoint(x: 12.4965728, y: 2.48128445))
            path.addQuadCurve(to: CGPoint(x: 15.0756639, y: 3.26282721), control: CGPoint(x: 14.4113526, y: 3.26282721))
            path.addQuadCurve(to: CGPoint(x: 16.9709051, y: 3.67313716), control: CGPoint(x: 16.072131, y: 3.26282721))
            path.addQuadCurve(to: CGPoint(x: 18.5046828, y: 4.86498987), control: CGPoint(x: 17.8501407, y: 4.07367783))
            path.addQuadCurve(to: CGPoint(x: 20.9567732, y: 6.47692181), control: CGPoint(x: 19.9603062, y: 5.26553053))
            path.addQuadCurve(to: CGPoint(x: 21.9923174, y: 9.22209075), control: CGPoint(x: 21.9434709, y: 7.66877452))
            path.addQuadCurve(to: CGPoint(x: 21.1619282, y: 12.2896461), control: CGPoint(x: 22.0802409, y: 10.912177))
            path.addQuadCurve(to: CGPoint(x: 21.259621, y: 13.3447288), control: CGPoint(x: 21.259621, y: 12.905111))
            path.closeSubpath()
            path.move(to: CGPoint(x: 16.3554402, y: 11.977029))
            path.addQuadCurve(to: CGPoint(x: 17.0881365, y: 12.3189539), control: CGPoint(x: 16.8048273, y: 12.0161061))
            path.addQuadCurve(to: CGPoint(x: 17.3616765, y: 13.0223424), control: CGPoint(x: 17.3616765, y: 12.6022632))
            path.addQuadCurve(to: CGPoint(x: 17.0881365, y: 13.7159616), control: CGPoint(x: 17.3616765, y: 13.4424217))
            path.addQuadCurve(to: CGPoint(x: 16.4042866, y: 13.9895016), control: CGPoint(x: 16.8145966, y: 13.9895016))
            path.addLine(to: CGPoint(x: 15.7595139, y: 13.9895016))
            path.addQuadCurve(to: CGPoint(x: 14.2061976, y: 16.236437), control: CGPoint(x: 15.3003575, y: 15.3669707))
            path.addLine(to: CGPoint(x: 14.938894, y: 16.4611306))
            path.addQuadCurve(to: CGPoint(x: 18.9638392, y: 14.9566607), control: CGPoint(x: 17.99668, y: 16.4122841))
            path.addQuadCurve(to: CGPoint(x: 19.3741491, y: 13.3056517), control: CGPoint(x: 19.4620727, y: 14.175118))
            path.addLine(to: CGPoint(x: 19.3741491, y: 13.2568052))
            path.addQuadCurve(to: CGPoint(x: 18.5535292, y: 11.5178726), control: CGPoint(x: 19.3253027, y: 12.2505689))
            path.addQuadCurve(to: CGPoint(x: 16.7169037, y: 10.8242534), control: CGPoint(x: 17.7719865, y: 10.775407))
            path.addQuadCurve(to: CGPoint(x: 16.0525924, y: 10.5507134), control: CGPoint(x: 16.3359016, y: 10.8242534))
            path.addQuadCurve(to: CGPoint(x: 15.7595139, y: 9.86686353), control: CGPoint(x: 15.7595139, y: 10.2674042))
            path.addQuadCurve(to: CGPoint(x: 16.0525924, y: 9.17324433), control: CGPoint(x: 15.7595139, y: 9.4467843))
            path.addQuadCurve(to: CGPoint(x: 16.7169037, y: 8.89970436), control: CGPoint(x: 16.3359016, y: 8.89970436))
            path.addQuadCurve(to: CGPoint(x: 20.0189219, y: 10.1404035), control: CGPoint(x: 18.5828371, y: 8.9387815))
            path.addQuadCurve(to: CGPoint(x: 20.0677683, y: 9.27093718), control: CGPoint(x: 20.0677683, y: 9.68124712))
            path.addQuadCurve(to: CGPoint(x: 19.471842, y: 7.66877452), control: CGPoint(x: 20.0189219, y: 8.26470087))
            path.addQuadCurve(to: CGPoint(x: 17.2737529, y: 6.78953891), control: CGPoint(x: 18.7782228, y: 6.97515532))
            path.addQuadCurve(to: CGPoint(x: 16.0819002, y: 5.42183909), control: CGPoint(x: 16.8732123, y: 5.83214903))
            path.addQuadCurve(to: CGPoint(x: 14.6555847, y: 5.18737626), control: CGPoint(x: 15.4371275, y: 5.05060627))
            path.addQuadCurve(to: CGPoint(x: 13.463732, y: 5.69537905), control: CGPoint(x: 13.9717348, y: 5.31437696))
            path.addQuadCurve(to: CGPoint(x: 12.9654985, y: 6.42807539), control: CGPoint(x: 12.9654985, y: 6.05684258))
            path.addQuadCurve(to: CGPoint(x: 13.053422, y: 6.83838534), control: CGPoint(x: 12.9654985, y: 6.55507609))
            path.addQuadCurve(to: CGPoint(x: 13.190192, y: 7.16077173), control: CGPoint(x: 13.1413456, y: 7.10215602))
            path.addQuadCurve(to: CGPoint(x: 13.9033498, y: 7.43431169), control: CGPoint(x: 13.6102713, y: 7.16077173))
            path.addQuadCurve(to: CGPoint(x: 14.2061976, y: 8.11816161), control: CGPoint(x: 14.2061976, y: 7.71762094))
            path.addQuadCurve(to: CGPoint(x: 13.9033498, y: 8.83131937), control: CGPoint(x: 14.2061976, y: 8.52847155))
            path.addQuadCurve(to: CGPoint(x: 13.190192, y: 9.13416719), control: CGPoint(x: 13.600502, y: 9.13416719))
            path.addQuadCurve(to: CGPoint(x: 11.8224922, y: 8.57731798), control: CGPoint(x: 12.4379571, y: 9.08532077))
            path.addQuadCurve(to: CGPoint(x: 10.2594067, y: 9.13416719), control: CGPoint(x: 11.1093344, y: 9.04624363))
            path.addQuadCurve(to: CGPoint(x: 9.52671035, y: 8.8801658), control: CGPoint(x: 9.84909673, y: 9.13416719))
            path.addQuadCurve(to: CGPoint(x: 9.18478539, y: 8.23539302), control: CGPoint(x: 9.21409324, y: 8.63593368))
            path.addQuadCurve(to: CGPoint(x: 9.40947893, y: 7.52223525), control: CGPoint(x: 9.15547754, y: 7.84462164))
            path.addQuadCurve(to: CGPoint(x: 10.0737903, y: 7.16077173), control: CGPoint(x: 9.65371105, y: 7.19984886))
            path.addQuadCurve(to: CGPoint(x: 10.5817931, y: 7.02400174), control: CGPoint(x: 10.3180224, y: 7.12169459))
            path.addQuadCurve(to: CGPoint(x: 10.992103, y: 6.42807539), control: CGPoint(x: 10.992103, y: 6.78953891))
            path.addQuadCurve(to: CGPoint(x: 11.6368758, y: 4.64029633), control: CGPoint(x: 10.992103, y: 5.4120698))
            path.addQuadCurve(to: CGPoint(x: 8.79401401, y: 5.92007259), control: CGPoint(x: 10.1617138, y: 4.26906352))
            path.addQuadCurve(to: CGPoint(x: 6.7815414, y: 6.03730401), control: CGPoint(x: 7.44585275, y: 5.68560977))
            path.addQuadCurve(to: CGPoint(x: 5.72645868, y: 7.8055445), control: CGPoint(x: 6.13676863, y: 6.36945968))
            path.addQuadCurve(to: CGPoint(x: 4.67137595, y: 8.48939442), control: CGPoint(x: 4.94491592, y: 8.16700803))
            path.addQuadCurve(to: CGPoint(x: 4.12429602, y: 9.54447714), control: CGPoint(x: 4.25129672, y: 8.86062723))
            path.addQuadCurve(to: CGPoint(x: 7.24069778, y: 9.76917068), control: CGPoint(x: 5.74599725, y: 9.21232147))
            path.addQuadCurve(to: CGPoint(x: 7.78777771, y: 10.2771735), control: CGPoint(x: 7.58262273, y: 9.8864021))
            path.addQuadCurve(to: CGPoint(x: 7.83662413, y: 11.0294084), control: CGPoint(x: 7.97339411, y: 10.6288677))
            path.addQuadCurve(to: CGPoint(x: 7.32862134, y: 11.5862576), control: CGPoint(x: 7.69985415, y: 11.4201798))
            path.addQuadCurve(to: CGPoint(x: 6.54707858, y: 11.6057962), control: CGPoint(x: 6.96715781, y: 11.7425662))
            path.addQuadCurve(to: CGPoint(x: 4.30991243, y: 11.5569497), control: CGPoint(x: 5.44314943, y: 11.1466398))
            path.addQuadCurve(to: CGPoint(x: 4.02660318, y: 12.113799), control: CGPoint(x: 4.11452674, y: 11.7523354))
            path.addLine(to: CGPoint(x: 4.02660318, y: 12.8464953))
            path.addQuadCurve(to: CGPoint(x: 4.28060457, y: 13.833193), control: CGPoint(x: 4.02660318, y: 13.3349595))
            path.addQuadCurve(to: CGPoint(x: 4.99376234, y: 14.5854279), control: CGPoint(x: 4.5150674, y: 14.2923494))
            path.addQuadCurve(to: CGPoint(x: 6.64477142, y: 14.9957379), control: CGPoint(x: 5.76553582, y: 14.9957379))
            path.addQuadCurve(to: CGPoint(x: 6.30284646, y: 14.2141951), control: CGPoint(x: 6.49823215, y: 14.7221979))
            path.addQuadCurve(to: CGPoint(x: 6.32238503, y: 13.4131138), control: CGPoint(x: 6.13676863, y: 13.7941159))
            path.addQuadCurve(to: CGPoint(x: 6.89877282, y: 12.8855724), control: CGPoint(x: 6.51777072, y: 13.0125731))
            path.addQuadCurve(to: CGPoint(x: 7.67054629, y: 12.9344189), control: CGPoint(x: 7.2895442, y: 12.7488025))
            path.addQuadCurve(to: CGPoint(x: 8.19808766, y: 13.5303452), control: CGPoint(x: 8.07108696, y: 13.1200353))
            path.addQuadCurve(to: CGPoint(x: 9.16036218, y: 14.9078143), control: CGPoint(x: 8.47162762, y: 14.3509651))
            path.addQuadCurve(to: CGPoint(x: 10.7674095, y: 15.5525871), control: CGPoint(x: 9.84909673, y: 15.4646635))
            path.addQuadCurve(to: CGPoint(x: 12.5942657, y: 14.9273529), control: CGPoint(x: 11.7541072, y: 15.5037407))
            path.addQuadCurve(to: CGPoint(x: 13.8838112, y: 13.4424217), control: CGPoint(x: 13.4441934, y: 14.3314265))
            path.addQuadCurve(to: CGPoint(x: 14.7532776, y: 12.2017225), control: CGPoint(x: 14.0108119, y: 12.5241089))
            path.addQuadCurve(to: CGPoint(x: 16.3554402, y: 11.977029), control: CGPoint(x: 15.2319725, y: 11.977029))
            path.closeSubpath()
            path.move(to: CGPoint(x: 18.3288357, y: 19.3039923))
            path.addLine(to: CGPoint(x: 17.7329093, y: 18.0242161))
            path.addLine(to: CGPoint(x: 17.0392901, y: 18.1609861))
            path.addLine(to: CGPoint(x: 18.0064493, y: 19.4016852))
            path.closeSubpath()
            path.move(to: CGPoint(x: 13.7861184, y: 10.8730998))
            path.addQuadCurve(to: CGPoint(x: 13.5418863, y: 10.2087885), control: CGPoint(x: 13.7861184, y: 10.4920977))
            path.addQuadCurve(to: CGPoint(x: 12.8775749, y: 9.86686353), control: CGPoint(x: 13.2878849, y: 9.90594067))
            path.addQuadCurve(to: CGPoint(x: 10.992103, y: 10.501867), control: CGPoint(x: 11.8029536, y: 9.81801711))
            path.addQuadCurve(to: CGPoint(x: 10.1714831, y: 12.6608789), control: CGPoint(x: 10.1226367, y: 11.4201798))
            path.addQuadCurve(to: CGPoint(x: 10.4645617, y: 13.3447288), control: CGPoint(x: 10.1714831, y: 13.0614196))
            path.addQuadCurve(to: CGPoint(x: 11.1777194, y: 13.6182688), control: CGPoint(x: 10.7478709, y: 13.6182688))
            path.addQuadCurve(to: CGPoint(x: 11.8615693, y: 13.3447288), control: CGPoint(x: 11.5880294, y: 13.6182688))
            path.addQuadCurve(to: CGPoint(x: 12.1351093, y: 12.6608789), control: CGPoint(x: 12.1351093, y: 13.0711888))
            path.addQuadCurve(to: CGPoint(x: 12.3695721, y: 11.9281826), control: CGPoint(x: 12.1351093, y: 12.2505689))
            path.addQuadCurve(to: CGPoint(x: 12.7798821, y: 11.7914126), control: CGPoint(x: 12.5649578, y: 11.7914126))
            path.addQuadCurve(to: CGPoint(x: 13.4930399, y: 11.5374112), control: CGPoint(x: 13.190192, y: 11.7914126))
            path.addQuadCurve(to: CGPoint(x: 13.7861184, y: 10.8730998), control: CGPoint(x: 13.7861184, y: 11.2834098))
            path.closeSubpath()
        case "locked":
            path.move(to: CGPoint(x: 19.1386719, y: 10.5449219))
            path.addLine(to: CGPoint(x: 17.6835938, y: 10.5449219))
            path.addLine(to: CGPoint(x: 17.6835938, y: 7.73242188))
            path.addQuadCurve(to: CGPoint(x: 16.921875, y: 4.82226562), control: CGPoint(x: 17.6835938, y: 6.12109375))
            path.addQuadCurve(to: CGPoint(x: 14.8222656, y: 2.76171875), control: CGPoint(x: 16.1699219, y: 3.53320312))
            path.addQuadCurve(to: CGPoint(x: 11.9609375, y: 2), control: CGPoint(x: 13.484375, y: 2))
            path.addQuadCurve(to: CGPoint(x: 9.09960938, y: 2.76171875), control: CGPoint(x: 10.4375, y: 2))
            path.addQuadCurve(to: CGPoint(x: 7.00976562, y: 4.82226562), control: CGPoint(x: 7.77148438, y: 3.5234375))
            path.addQuadCurve(to: CGPoint(x: 6.23828125, y: 7.73242188), control: CGPoint(x: 6.23828125, y: 6.140625))
            path.addLine(to: CGPoint(x: 6.23828125, y: 10.5449219))
            path.addLine(to: CGPoint(x: 4.78320312, y: 10.5449219))
            path.addLine(to: CGPoint(x: 3.41601562, y: 12))
            path.addLine(to: CGPoint(x: 3.41601562, y: 20.5546875))
            path.addLine(to: CGPoint(x: 4.78320312, y: 22))
            path.addLine(to: CGPoint(x: 19.1386719, y: 22))
            path.addLine(to: CGPoint(x: 20.5839844, y: 20.5546875))
            path.addLine(to: CGPoint(x: 20.5839844, y: 12))
            path.closeSubpath()
            path.move(to: CGPoint(x: 7.69335938, y: 7.73242188))
            path.addQuadCurve(to: CGPoint(x: 8.953125, y: 4.66601562), control: CGPoint(x: 7.69335938, y: 5.89648438))
            path.addQuadCurve(to: CGPoint(x: 11.9609375, y: 3.40625), control: CGPoint(x: 10.2128906, y: 3.43554688))
            path.addQuadCurve(to: CGPoint(x: 14.9785156, y: 4.63671875), control: CGPoint(x: 13.71875, y: 3.37695312))
            path.addQuadCurve(to: CGPoint(x: 16.2382812, y: 7.73242188), control: CGPoint(x: 16.2382812, y: 5.89648438))
            path.addLine(to: CGPoint(x: 16.2382812, y: 10.5449219))
            path.addLine(to: CGPoint(x: 7.69335938, y: 10.5449219))
            path.closeSubpath()
            path.move(to: CGPoint(x: 19.1386719, y: 20.5546875))
            path.addLine(to: CGPoint(x: 4.78320312, y: 20.5546875))
            path.addLine(to: CGPoint(x: 4.78320312, y: 12))
            path.addLine(to: CGPoint(x: 19.1386719, y: 12))
            path.closeSubpath()
        case "unlocked":
            path.move(to: CGPoint(x: 7.69293046, y: 10.5535476))
            path.addLine(to: CGPoint(x: 7.69293046, y: 7.74076751))
            path.addQuadCurve(to: CGPoint(x: 8.68912342, y: 4.9572872), control: CGPoint(x: 7.69293046, y: 6.1585787))
            path.addQuadCurve(to: CGPoint(x: 11.2382054, y: 3.50206416), control: CGPoint(x: 9.67554977, y: 3.76576229))
            path.addQuadCurve(to: CGPoint(x: 14.1388849, y: 4.02946043), control: CGPoint(x: 12.8203942, y: 3.23836602))
            path.addQuadCurve(to: CGPoint(x: 16.0140716, y: 6.28554447), control: CGPoint(x: 15.4769087, y: 4.83032143))
            path.addLine(to: CGPoint(x: 17.5278942, y: 6.28554447))
            path.addQuadCurve(to: CGPoint(x: 15.1643776, y: 3.00396768), control: CGPoint(x: 16.9125986, y: 4.23455898))
            path.addQuadCurve(to: CGPoint(x: 11.2772718, y: 2.04684112), control: CGPoint(x: 13.4356898, y: 1.78314298))
            path.addQuadCurve(to: CGPoint(x: 7.69293046, y: 3.92202785), control: CGPoint(x: 9.1579201, y: 2.31053925))
            path.addQuadCurve(to: CGPoint(x: 6.24747402, y: 7.74076751), control: CGPoint(x: 6.24747402, y: 5.51398326))
            path.addLine(to: CGPoint(x: 6.24747402, y: 10.5535476))
            path.addLine(to: CGPoint(x: 4.79225098, y: 10.5535476))
            path.addLine(to: CGPoint(x: 3.41516072, y: 12.0087707))
            path.addLine(to: CGPoint(x: 3.41516072, y: 20.5643102))
            path.addLine(to: CGPoint(x: 4.79225098, y: 22))
            path.addLine(to: CGPoint(x: 19.1393828, y: 22))
            path.addLine(to: CGPoint(x: 20.5848393, y: 20.5643102))
            path.addLine(to: CGPoint(x: 20.5848393, y: 12.0087707))
            path.addLine(to: CGPoint(x: 19.1393828, y: 10.5535476))
            path.closeSubpath()
            path.move(to: CGPoint(x: 16.2289368, y: 12.0087707))
            path.addLine(to: CGPoint(x: 19.1393828, y: 12.0087707))
            path.addLine(to: CGPoint(x: 19.1393828, y: 20.5643102))
            path.addLine(to: CGPoint(x: 4.79225098, y: 20.5643102))
            path.addLine(to: CGPoint(x: 4.79225098, y: 12.0087707))
            path.closeSubpath()
        default: break
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// `available` comes from the keyboard-adjusted conversation container. Reserve
/// space for controls and visible conversation even while the prompt is expanded.
/// I12-6: the field never takes more than 40% of the height (large text, keyboard up); longer text
/// scrolls inside it.
func composerPromptHeight(_ requested: CGFloat, available: CGFloat, minimum: CGFloat = 56) -> CGFloat {
    let maximum = max(minimum, min(available * 0.4, available - 200))
    return min(maximum, max(minimum, requested))
}
