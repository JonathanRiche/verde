import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

struct ChatComposer: View {
    let model: ComposerModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var picker: ComposerPicker?
    @State private var photo: PhotosPickerItem?
    @State private var files = false
    @State private var camera = false
    @State private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let followup = model.view?.followup {
                VStack(alignment: .leading) {
                    Text("\(followup.kind.capitalized) · \(followup.state)").font(.caption.bold())
                    Text(followup.text).lineLimit(3).font(.caption)
                    HStack {
                        if followup.can_retry { Button("Retry") { model.followup("retry", followup) } }
                        if followup.can_pull_back { Button("Pull back") { model.followup("pull", followup) } }
                        Button("Remove") { model.followup("cancel", followup) }
                    }.disabled(model.busy)
                }.accessibilityIdentifier("composer-followup")
            }
            if let notice = model.notice ?? model.view?.error?.message {
                Text(notice).font(.caption).foregroundStyle(.red).accessibilityIdentifier("composer-notice")
            }
            if let token = model.token {
                ScrollView(.horizontal) {
                    HStack {
                        if token.marker == "@" {
                            ForEach(model.view?.mentions ?? [], id: \.path) { item in Button(item.label) { model.accept(item.path) } }
                        } else {
                            ForEach((model.view?.catalogs.slash ?? []).filter { $0.label.localizedCaseInsensitiveContains(token.query) || token.query.isEmpty }, id: \.id) { item in
                                Button(item.label) { model.accept(item.label) }.disabled(!item.enabled)
                            }
                        }
                    }.font(.caption)
                }.accessibilityIdentifier("composer-suggestions")
            }
            if let attachments = model.view?.draft.attachments, !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(attachments, id: \.local_id) { item in
                            HStack {
                                if let data = model.previews[item.local_id], let image = UIImage(data: data) {
                                    Image(uiImage: image).resizable().scaledToFit().frame(width: 44, height: 44)
                                }
                                Text(item.name).font(.caption)
                                Button { model.detach(item.local_id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .accessibilityLabel("Remove \(item.name)").disabled(model.busy || model.pending)
                            }
                        }
                    }
                }
            }
            ComposerText(text: model.text, selection: model.selection, editable: !model.pending, edit: model.edit, focus: { focused = $0 })
                .frame(minHeight: 64, maxHeight: 120)
                .accessibilityIdentifier("composer-field")
            HStack {
                Menu {
                    PhotosPicker(selection: $photo, matching: .images) { Label("Photos", systemImage: "photo") }
                    Button("Camera", systemImage: "camera") { openCamera() }
                    Button("Files", systemImage: "folder") { files = true }
                } label: { Image(systemName: "paperclip").frame(width: 44, height: 44) }
                    .accessibilityLabel("Attach image").disabled(model.busy || model.pending)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ComposerPicker.allCases) { kind in
                            Button(selectionLabel(kind)) { picker = kind }.font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 8).background(.quaternary, in: Capsule())
                        }
                    }
                }
                if model.chat.state.turn != nil {
                    Button(action: model.chat.stopTurn) { Image(systemName: "stop.fill").frame(width: 44, height: 44) }
                        .tint(.yellow).disabled(!model.chat.state.canStop).accessibilityLabel("Stop")
                }
                Button(action: model.submit) {
                    Image(systemName: "arrow.up").font(.body.bold()).frame(width: 44, height: 44)
                }.buttonStyle(.borderedProminent).buttonBorderShape(.circle).tint(.green)
                    .disabled(!model.canSubmit).accessibilityLabel(sendLabel).accessibilityIdentifier("composer-send")
            }
            if model.chat.state.turn != nil { Text(sendLabel + " a follow-up while the agent works.").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(focused ? Color.green : Color.secondary.opacity(0.3), lineWidth: focused ? 1.5 : 1))
        .padding(8)
        .onAppear { model.adopt(model.chat.composer) }
        .onChange(of: model.chat.composer?.draft.revision) { model.adopt(model.chat.composer) }
        .onChange(of: model.chat.composer.map { try? JSONEncoder().encode($0) }) { model.adopt(model.chat.composer) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.flushNow() } }
        .onDisappear { model.flushNow() }
        .sheet(item: $picker) { kind in
            NavigationStack {
                List(choices(kind).sorted { $0.favorite && !$1.favorite }, id: \.id) { choice in
                    Button { model.select(kind, choice.id); picker = nil } label: {
                        HStack { Text(choice.label); if choice.favorite { Image(systemName: "star.fill") }; Spacer(); if let reason = choice.reason { Text(reason).font(.caption) } }
                    }.disabled(!choice.enabled)
                }.navigationTitle(kind.rawValue.capitalized).toolbar { Button("Done") { picker = nil } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $camera) { ComposerCamera { image in camera = false; if let image { prepare(image) } } }
        .sheet(isPresented: Binding(get: { model.view?.shell_confirmation != nil }, set: { shown in
            if !shown, let confirmation = model.view?.shell_confirmation { model.confirmShell(confirmation, accept: false) }
        })) {
            if let confirmation = model.view?.shell_confirmation {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Run this command on the host?").font(.headline)
                        Text(confirmation.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Text(confirmation.cwd).font(.caption)
                        HStack { Button("Cancel") { model.confirmShell(confirmation, accept: false) }; Spacer(); Button("Run") { model.confirmShell(confirmation, accept: true) }.buttonStyle(.borderedProminent) }
                    }.padding().disabled(model.busy)
                }.presentationDetents([.medium])
            }
        }
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

    private var sendLabel: String {
        guard model.chat.state.turn != nil else { return "Send" }
        return composerFollowupKind(provider: model.view?.selection.provider, images: model.view?.draft.attachments.isEmpty == false) == .steer ? "Steer" : "Queue"
    }
    private func selectionLabel(_ picker: ComposerPicker) -> String {
        let s = model.view?.selection
        switch picker {
        case .provider: return s?.provider ?? "Provider"
        case .model: return s?.model ?? "Model"
        case .effort: return s?.effort ?? "Effort"
        case .access: return s?.access ?? "Access"
        case .speed: return s?.speed ?? "Speed"
        }
    }
    private func choices(_ picker: ComposerPicker) -> [ChatChoice] {
        switch picker {
        case .provider: return ["codex", "claude", "cursor", "opencode", "pi", "fx", "grok", "muse"].map { ChatChoice(id: $0, label: $0.capitalized) }
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

/// Re-encoding strips source metadata; drafts respect the core's encrypted record limit.
@MainActor
func composerImage(_ image: UIImage) -> Data? {
    guard image.size.width > 0, image.size.height > 0 else { return nil }
    var edge: CGFloat = 1600
    while edge >= 200 {
        let scale = min(1, edge / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size)); image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in [0.85, 0.65, 0.45] {
            if let bytes = resized.jpegData(compressionQuality: quality), bytes.count <= ComposerModel.maxImageBytes { return bytes }
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
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator; view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body); view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.accessibilityLabel = "Message"; view.accessibilityIdentifier = "composer-field"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = editable
        // Never replace marked text while an IME is composing.
        if view.markedTextRange == nil && view.text != text { view.text = text; view.selectedRange = selection }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerText
        init(_ parent: ComposerText) { self.parent = parent }
        func textViewDidBeginEditing(_ view: UITextView) { parent.focus(true) }
        func textViewDidEndEditing(_ view: UITextView) { parent.focus(false) }
        func textViewDidChange(_ view: UITextView) { parent.edit(view.text, view.selectedRange) }
        func textViewDidChangeSelection(_ view: UITextView) { parent.edit(view.text, view.selectedRange) }
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
