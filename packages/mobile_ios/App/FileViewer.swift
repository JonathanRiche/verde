import SwiftUI
import PDFKit
import ImageIO
import Observation
import WebKit

/// Failure code from the core's file operation (`LocalError.code`), mapped to text by callers.
struct FileFetchFailure: Error { let code: String? }

/// Title/detail wording mirrors Android's `problemText`.
struct FileProblem: LocalizedError, Equatable {
    let title: String
    let detail: String
    var errorDescription: String? { detail }
    static func sizeLabel(_ bytes: UInt32) -> String { bytes >= 1024 * 1024 ? "\(bytes / (1024 * 1024)) MB" : "\(bytes / 1024) KB" }
    static func of(_ code: String?, limit: UInt32) -> FileProblem {
        switch code {
        case "offline", "cancelled", "timeout", "busy", "server_unavailable": return FileProblem(title: "Can't reach the host", detail: "Check your connection and try again.")
        case "forbidden": return FileProblem(title: "No access", detail: "This file is outside the host's shared workspaces.")
        case "not_found": return FileProblem(title: "File not found", detail: "It may have been moved or deleted on the host.")
        case "too_large": return FileProblem(title: "Too large to open", detail: "This file is over the \(sizeLabel(limit)) limit for viewing on the phone. Open it on the host.")
        case "unsupported": return FileProblem(title: "Can't show this file", detail: "The host doesn't serve this file type to the phone.")
        case "invalid_path": return unresolved
        case "preview_unavailable": return FileProblem(title: "No preview available", detail: "Office previews need LibreOffice on the host.")
        case "unavailable", "unauthorized": return unavailable
        default: return failed
        }
    }
    /// Download failures reuse the viewer wording except where "viewing" would be wrong.
    static func download(_ code: String?, limit: UInt32) -> FileProblem {
        code == "too_large" ? FileProblem(title: "Too large to download", detail: "This file is over the \(sizeLabel(limit)) download limit for the phone. Open it on the host.") : of(code, limit: limit)
    }
    static let binary = FileProblem(title: "Binary file", detail: "This file isn't text, so it can't be shown here.")
    static let unresolved = FileProblem(title: "Can't open this link", detail: "The path couldn't be resolved to a file in the workspace.")
    static let unreadable = FileProblem(title: "Can't display this file", detail: "The file couldn't be decoded.")
    static let unavailable = FileProblem(title: "Host not connected", detail: "Reconnect to the host to view files.")
    static let failed = FileProblem(title: "Couldn't open the file", detail: "Something went wrong loading it.")
    static let shareFailed = FileProblem(title: "Couldn't share the file", detail: "A private copy for sharing couldn't be prepared.")
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
                if op.state == "failed" { throw FileFetchFailure(code: op.error?.code) }
                if op.state == "succeeded" {
                    guard let bytes = takeFile(id) else { throw FileFetchFailure(code: nil) }
                    return bytes
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw FileFetchFailure(code: "timeout")
    }
}

enum ViewerKind { case text, markdown, image, svg, pdf, office
    /// Largest original file the Download/Share action fetches.
    static let downloadLimit: UInt32 = 32 * 1024 * 1024
    var limit: UInt32 {
        switch self { case .text, .markdown: return 2 * 1024 * 1024; case .image, .svg: return 16 * 1024 * 1024; case .pdf, .office: return 32 * 1024 * 1024 }
    }
    static func of(_ path: String) -> ViewerKind {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "webp", "gif", "bmp": return .image
        case "svg": return .svg
        case "md", "markdown": return .markdown
        case "pdf": return .pdf
        case "pptx", "ppt", "odp", "docx", "doc", "odt", "xlsx", "xls", "ods", "rtf": return .office
        default: return .text
        }
    }
    /// The gateway serves active content (SVG, HTML, scripts, WASM) only as attachments.
    static func fetchKind(_ path: String) -> FileKind {
        switch of(path) {
        case .office: return .preview
        case .svg: return .download
        default: return ["html", "htm", "js", "mjs", "cjs", "wasm"].contains((path as NSString).pathExtension.lowercased()) ? .download : .file
        }
    }
}

/// A static page that shows SVG only through `<img>` (no scripts, no fetches) under a
/// CSP that forbids everything but inline style and the data: image itself.
func svgPreviewHTML(_ data: Data) -> String {
    #"<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'"><meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=8, user-scalable=yes"><style>html,body{margin:0;height:100%;background:transparent}body{display:flex;align-items:center;justify-content:center}img{max-width:100%;max-height:100%;object-fit:contain;background:#fff}</style></head><body><img alt="" src="data:image/svg+xml;base64,"# + data.base64EncodedString() + #""></body></html>"#
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
    var problem: FileProblem?
    var text: String?
    var svg: Data?
    var blocks: [MdBlock]?
    var image: UIImage?
    var pdf: PDFDocument?
    private(set) var bytes: Data?
    /// False when `bytes` are a converted preview (office → PDF), not the original file.
    private(set) var original = false
    private var host: CoreHost?
    private var highlights = RenderLRU<RenderResult<[RenderSpan]>>(32)
    @ObservationIgnored private var cachedSplit: FileSplit?
    func clear() { bytes = nil; original = false; svg = nil; text = nil; blocks = nil; image = nil; pdf = nil; host = nil; highlights = RenderLRU(32); cachedSplit = nil }
    /// `text` split into display lines once, for the line-selectable viewer.
    func split() -> FileSplit? {
        guard let text else { return nil }
        if let cachedSplit, cachedSplit.text == text { return cachedSplit }
        let next = FileSplit(text)
        cachedSplit = next
        return next
    }
    /// `reader` replaces the path fetch (workspace Files reads by root and relative path); a nil
    /// outcome means the host can't serve that read, so the path fetch is used instead.
    func load(host: CoreHost, path: String, reader: ((CoreHost) async throws -> WorkspaceReadOutcome?)? = nil) async {
        clear(); self.host = host; loading = true; problem = nil
        defer { loading = false }
        do {
            let kind = ViewerKind.of(path)
            var read: Data?
            if let reader {
                switch try await reader(host) {
                case .bytes(let bytes): read = bytes
                case .problem(let problem): throw problem
                case nil: break
                }
            }
            let data: Data
            if let read { data = read }
            else {
                do { data = try await host.fetchFile(path: path, kind: ViewerKind.fetchKind(path), limit: kind.limit).data }
                catch let failure as FileFetchFailure { throw FileProblem.of(failure.code, limit: kind.limit) }
            }
            try Task.checkCancellation()
            bytes = data; original = kind != .office
            switch kind {
            case .pdf, .office:
                guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw FileProblem.unreadable }
                pdf = document
            case .svg:
                guard !data.isEmpty else { throw FileProblem.unreadable }
                svg = data
                text = String(data: data, encoding: .utf8)
            case .image:
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else { throw FileProblem.unreadable }
                image = UIImage(cgImage: thumbnail)
            case .text, .markdown:
                guard !data.contains(0), let decoded = String(data: data, encoding: .utf8) else { throw FileProblem.binary }
                text = decoded
                if kind == .markdown, decoded.utf8.count <= 64 * 1024,
                   let data = await utility("markdown", decoded), let parsed = try? JSONDecoder().decode(MarkdownQuery.self, from: data).data {
                    blocks = markdownBlocks(parsed.nodes)
                }
            }
        } catch is CancellationError { clear() }
        catch { clear(); problem = (error as? FileProblem) ?? .unavailable }
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
    /// Reads the file some other way than by path (see `FileViewerModel.load`).
    var reader: ((CoreHost) async throws -> WorkspaceReadOutcome?)? = nil
    /// Pushed inside a navigation stack (no own stack, no Done button).
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lineSelection) private var lineSelection
    @State private var model = FileViewerModel()
    @State private var source = false
    @State private var attempt = 0
    @State private var share: SharedFile?
    @State private var host: CoreHost?
    @State private var download: Task<Void, Never>?
    @State private var downloadProblem: FileProblem?
    private var path: String? { resolveFilePath(citation.path, root: browse.state.workspaces?.items.first { $0.workspace_id == workspaceID }?.path) }
    var body: some View {
        Group {
            if embedded { page } else { NavigationStack { page } }
        }
        .tint(VerdeTheme.accent).foregroundStyle(VerdeTheme.text).font(VerdeTheme.ui())
        .task(id: attempt) {
            source = citation.line != nil
            guard path != nil || reader != nil, let session = browse.session else { model.problem = .unresolved; return }
            await session.start()
            guard let host = session.host else { self.host = nil; model.problem = .unavailable; return }
            self.host = host
            await model.load(host: host, path: path ?? citation.path, reader: reader)
        }
        .onChange(of: browse.hostID) { dismiss(); model.clear(); host = nil; download?.cancel() }
        .onChange(of: browse.state.host?.auth_state) { _, state in if state != "paired" { dismiss(); model.clear(); host = nil; download?.cancel() } }
        .onDisappear { model.clear(); host = nil; download?.cancel(); share?.remove() }
        .sheet(item: $share, onDismiss: { SharedFile.cleanup() }) { file in ShareFile(url: file.url) }
        .alert(downloadProblem?.title ?? "", isPresented: Binding(get: { downloadProblem != nil }, set: { if !$0 { downloadProblem = nil } }), presenting: downloadProblem) { _ in
            Button("OK", role: .cancel) {}
        } message: { problem in Text(problem.detail) }
        .environment(\.openURL, OpenURLAction { url in safeLinkUrl(url.absoluteString) != nil ? .systemAction : .discarded })
    }
    private var page: some View {
        Group {
            if model.loading { ProgressView("Loading file…") }
            else if let problem = model.problem {
                VStack(spacing: 8) {
                    Text(problem.title).font(VerdeTheme.ui(17, bold: true)).multilineTextAlignment(.center)
                    Text(problem.detail).foregroundStyle(VerdeTheme.muted).multilineTextAlignment(.center)
                    if canDownload {
                        Button { export() } label: {
                            if download != nil { ProgressView() } else { Label("Download file", systemImage: "arrow.down.circle") }
                        }.buttonStyle(.borderedProminent).disabled(download != nil).padding(.top, 8)
                    }
                    Button("Retry") { attempt += 1 }.padding(.top, 4)
                }.padding()
            }
            else if let pdf = model.pdf { NativePDF(document: pdf) }
            else if let image = model.image { ZoomImage(image: image) }
            else if let svg = model.svg, !source || model.text == nil { SVGPreview(html: svgPreviewHTML(svg)) }
            else if let blocks = model.blocks, !source { ScrollView { MarkdownBlocks(blocks: blocks, source: model).padding() } }
            else if lineSelection != nil, let split = model.split() { SelectableFileText(split: split, target: citeLines) }
            else if let text = model.text { FileText(text: text, target: fileLineRange(text, line: citation.line, end: citation.end_line)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(VerdeTheme.background)
        .navigationTitle((citation.path as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embedded { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.blocks != nil || (model.svg != nil && model.text != nil) { Button(source ? "Preview" : "Source") { source.toggle() } }
                if canDownload {
                    if download != nil { ProgressView() }
                    else { Button { export() } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share or open file") }
                }
            }
        }
    }
    /// The cited lines (1-based), highlighted in the selectable viewer.
    private var citeLines: ClosedRange<Int>? {
        guard let line = citation.line, line > 0, line <= UInt64(Int.max) else { return nil }
        let first = Int(line)
        return first...max(first, Int(clamping: citation.end_line ?? line))
    }
    private var canDownload: Bool { path != nil && host != nil }
    /// Shares the original file (Save to Files included), reusing preview bytes when they are the original.
    private func export() {
        guard download == nil, let path, let host else { return }
        let name = (path as NSString).lastPathComponent
        if model.original, let bytes = model.bytes { return write(bytes, name: name) }
        download = Task {
            defer { download = nil }
            do {
                let file = try await host.fetchFile(path: path, kind: .download, limit: ViewerKind.downloadLimit)
                try Task.checkCancellation()
                write(file.data, name: name)
            } catch is CancellationError {
            } catch let failure as FileFetchFailure {
                if !Task.isCancelled { downloadProblem = .download(failure.code, limit: ViewerKind.downloadLimit) }
            } catch {
                if !Task.isCancelled { downloadProblem = .unavailable }
            }
        }
    }
    private func write(_ data: Data, name: String) {
        do { share = try SharedFile(data, name: name) } catch { downloadProblem = .shareFailed }
    }
}

private struct NativePDF: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView { let v = PDFView(); v.autoScales = true; v.displayMode = .singlePageContinuous; v.backgroundColor = UIColor(VerdeTheme.background); return v }
    func updateUIView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
}
/// JavaScript off, no persistent storage, no navigation beyond the initial static page.
private struct SVGPreview: UIViewRepresentable {
    let html: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsLinkPreview = false
        view.isOpaque = false
        view.backgroundColor = UIColor(VerdeTheme.background); view.scrollView.backgroundColor = UIColor(VerdeTheme.background)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        view.loadHTMLString(html, baseURL: nil)
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.request.url?.absoluteString == "about:blank" ? .allow : .cancel
        }
    }
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
