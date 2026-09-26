import SwiftUI
import PDFKit
import ImageIO
import Observation

struct FileProblem: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension CoreHost {
    /// Wait for the core's receipt, then consume the platform-only buffer exactly once.
    func fetchFile(path: String, kind: FileKind, limit: UInt32) async throws -> FileBytes {
        let id = UUID().uuidString
        defer { discardFile(id) }
        try await send(.file_open(EventFileOpen(now_ms: 0, wall_time_ms: 0, intent_id: id, path: path, kind: kind, max_bytes: limit)))
        let deadline = ContinuousClock.now.advanced(by: .seconds(kind == .preview ? 125 : 40))
        repeat {
            try Task.checkCancellation()
            let result = try JSONDecoder().decode(OperationsQuery.self, from: query("operations"))
            if let op = result.data?.items.first(where: { $0.intent_id == id }) {
                if op.state == "failed" { throw FileProblem(message: op.error?.message ?? "The host couldn't open this file.") }
                if op.state == "succeeded" {
                    guard let bytes = takeFile(id) else { throw FileProblem(message: "The file expired. Try opening it again.") }
                    return bytes
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw FileProblem(message: "The host took too long to respond.")
    }
}

enum ViewerKind { case text, markdown, image, pdf, office
    var limit: UInt32 {
        switch self { case .text, .markdown: return 2 * 1024 * 1024; case .image: return 16 * 1024 * 1024; case .pdf, .office: return 32 * 1024 * 1024 }
    }
    static func of(_ path: String) -> ViewerKind {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "webp", "gif", "bmp": return .image
        case "md", "markdown": return .markdown
        case "pdf": return .pdf
        case "pptx", "ppt", "odp", "docx", "doc", "odt", "xlsx", "xls", "ods", "rtf": return .office
        default: return .text
        }
    }
}

func resolveFilePath(_ path: String, root: String?) -> String? {
    let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty, !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), !path.split(separator: "/").contains("..") else { return nil }
    if path.hasPrefix("/") { return path }
    guard let root, root.hasPrefix("/") else { return nil }
    return root.trimmingSuffix("/") + "/" + (path.hasPrefix("./") ? String(path.dropFirst(2)) : path)
}
private extension String { func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self } }

func fileLineRange(_ text: String, line: UInt64?, end: UInt64?) -> NSRange? {
    guard let line, line > 0, line <= UInt64(Int.max) else { return nil }
    let units = Array(text.utf16)
    var starts = [0]
    for (i, unit) in units.enumerated() where unit == 10 { starts.append(i + 1) }
    guard line <= starts.count else { return nil }
    let first = Int(line - 1), last = Int(min(max(end ?? line, line), UInt64(starts.count)))
    let stop = last < starts.count ? starts[last] : units.count
    return NSRange(location: starts[first], length: stop - starts[first])
}

@MainActor @Observable
final class FileViewerModel: HighlightSource {
    var loading = false
    var problem: String?
    var text: String?
    var blocks: [MdBlock]?
    var image: UIImage?
    var pdf: PDFDocument?
    private(set) var bytes: Data?
    private var host: CoreHost?
    private var highlights = RenderLRU<RenderResult<[RenderSpan]>>(32)
    func clear() { bytes = nil; text = nil; blocks = nil; image = nil; pdf = nil; host = nil; highlights = RenderLRU(32) }
    func load(host: CoreHost, path: String) async {
        clear(); self.host = host; loading = true; problem = nil
        defer { loading = false }
        do {
            let kind = ViewerKind.of(path)
            let file = try await host.fetchFile(path: path, kind: kind == .office ? .preview : .file, limit: kind.limit)
            try Task.checkCancellation()
            bytes = file.data
            switch kind {
            case .pdf, .office:
                guard let document = PDFDocument(data: file.data), document.pageCount > 0 else { throw FileProblem(message: "This PDF couldn't be read.") }
                pdf = document
            case .image:
                guard let source = CGImageSourceCreateWithData(file.data as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else { throw FileProblem(message: "This image couldn't be read.") }
                image = UIImage(cgImage: thumbnail)
            case .text, .markdown:
                guard !file.data.contains(0), let decoded = String(data: file.data, encoding: .utf8) else { throw FileProblem(message: "This file isn't UTF-8 text.") }
                text = decoded
                if kind == .markdown, decoded.utf8.count <= 64 * 1024,
                   let data = await utility("markdown", decoded), let parsed = try? JSONDecoder().decode(MarkdownQuery.self, from: data).data {
                    blocks = markdownBlocks(parsed.nodes)
                }
            }
        } catch is CancellationError { clear() }
        catch { clear(); problem = (error as? FileProblem)?.message ?? "This host isn't connected. Try again." }
    }
    private func utility(_ utility: String, _ text: String, language: String? = nil) async -> Data? {
        guard let host, text.utf8.count <= 64 * 1024 else { return nil }
        var payload = ["utility": utility, "text": text]
        payload["language"] = language
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let selector = String(data: data, encoding: .utf8) else { return nil }
        return try? await host.query(selector)
    }
    func cachedHighlight(_ code: String, language: String) -> RenderResult<[RenderSpan]>? { highlights[language + "\u{0}" + code] }
    func highlight(_ code: String, language: String) async -> RenderResult<[RenderSpan]> {
        let key = language + "\u{0}" + code
        if let cached = highlights[key] { return cached }
        let data = await utility("highlight", code, language: language)
        let result = RenderResult(data.flatMap { try? JSONDecoder().decode(HighlightQuery.self, from: $0).data?.spans })
        highlights[key] = result
        return result
    }
}

struct ViewerRequest: Identifiable { let id = UUID(); let citation: FileCitation }
struct FileViewer: View {
    let browse: BrowseModel
    let workspaceID: String
    let citation: FileCitation
    @Environment(\.dismiss) private var dismiss
    @State private var model = FileViewerModel()
    @State private var source = false
    @State private var attempt = 0
    @State private var share: SharedFile?
    private var path: String? { resolveFilePath(citation.path, root: browse.state.workspaces?.items.first { $0.workspace_id == workspaceID }?.path) }
    var body: some View {
        NavigationStack {
            Group {
                if model.loading { ProgressView("Loading file…") }
                else if let problem = model.problem { VStack(spacing: 16) { Text(problem); Button("Retry") { attempt += 1 } }.padding() }
                else if let pdf = model.pdf { NativePDF(document: pdf) }
                else if let image = model.image { ZoomImage(image: image) }
                else if let blocks = model.blocks, !source { ScrollView { MarkdownBlocks(blocks: blocks, source: model).padding() } }
                else if let text = model.text { FileText(text: text, target: fileLineRange(text, line: citation.line, end: citation.end_line)) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(VerdeTheme.background)
            .navigationTitle((citation.path as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.blocks != nil { Button(source ? "Preview" : "Source") { source.toggle() } }
                    if model.bytes != nil { Button { export() } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share or open file") }
                }
            }
        }
        .tint(VerdeTheme.accent).foregroundStyle(VerdeTheme.text).font(VerdeTheme.ui())
        .task(id: attempt) {
            source = citation.line != nil
            guard let path, let session = browse.session else { model.problem = "This file link can't be resolved in this workspace."; return }
            await session.start()
            guard let host = session.host else { model.problem = "This host isn't connected."; return }
            await model.load(host: host, path: path)
        }
        .onChange(of: browse.hostID) { dismiss(); model.clear() }
        .onChange(of: browse.state.host?.auth_state) { _, state in if state != "paired" { dismiss(); model.clear() } }
        .onDisappear { model.clear(); share?.remove() }
        .sheet(item: $share, onDismiss: { SharedFile.cleanup() }) { file in ShareFile(url: file.url) }
        .environment(\.openURL, OpenURLAction { url in safeLinkUrl(url.absoluteString) != nil ? .systemAction : .discarded })
    }
    private func export() {
        guard let bytes = model.bytes else { return }
        do { share = try SharedFile(bytes, name: ViewerKind.of(citation.path) == .office ? "preview.pdf" : (citation.path as NSString).lastPathComponent) }
        catch { model.problem = "Couldn't prepare a private copy for sharing." }
    }
}

private struct NativePDF: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView { let v = PDFView(); v.autoScales = true; v.displayMode = .singlePageContinuous; v.backgroundColor = UIColor(VerdeTheme.background); return v }
    func updateUIView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
}
private struct FileText: UIViewRepresentable {
    let text: String
    let target: NSRange?
    func makeUIView(context: Context) -> UITextView { let v = UITextView(); v.isEditable = false; v.font = UIFont(name: "JetBrainsMonoNF-Regular", size: 13); v.backgroundColor = UIColor(VerdeTheme.background); v.textColor = UIColor(VerdeTheme.text); v.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12); return v }
    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text; if let target { view.selectedRange = target; DispatchQueue.main.async { view.scrollRangeToVisible(target) } } }
    }
}
private struct ZoomImage: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let view = UIScrollView(); view.minimumZoomScale = 1; view.maximumZoomScale = 6; view.delegate = context.coordinator
        let imageView = UIImageView(image: image); imageView.contentMode = .scaleAspectFit; imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(imageView); context.coordinator.image = imageView
        return view
    }
    func updateUIView(_ view: UIScrollView, context: Context) { context.coordinator.image?.image = image; context.coordinator.image?.frame = view.bounds }
    final class Coordinator: NSObject, UIScrollViewDelegate { var image: UIImageView?; func viewForZooming(in scrollView: UIScrollView) -> UIView? { image } }
}

/// An explicit Share action is the only disk write. Files are protected and excluded
/// from backups; dismissal/sign-out removes them, and next launch sweeps crashes.
struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("verde-share", isDirectory: true) }
    init(_ data: Data, name: String) throws {
        let folder = Self.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var target = folder.appendingPathComponent(name.isEmpty ? "file" : (name as NSString).lastPathComponent)
        do {
            try data.write(to: target, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try target.setResourceValues(values)
            url = target
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    func remove() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    static func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
private struct ShareFile: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ view: UIActivityViewController, context: Context) {}
}
