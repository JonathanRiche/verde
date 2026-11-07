import SwiftUI
import WebKit
import UniformTypeIdentifiers

func previewPath(_ path: String) -> String? {
    guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || $0.value == 92 }) else { return nil }
    var parts: [String] = []
    for part in path.split(separator: "/") {
        if part == "." { continue }
        if part == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() }
        else { parts.append(String(part)) }
    }
    return "/" + parts.joined(separator: "/")
}
struct PreviewLocation {
    let document: String
    let root: String
    var url: URL { var u = URLComponents(); u.scheme = "verde-preview"; u.host = "workspace"; u.path = document; return u.url! }
    init(document: String, root: String?) {
        let documentPath = previewPath(document) ?? "/invalid"
        self.document = documentPath
        let candidate = root.flatMap(previewPath)
        self.root = candidate.flatMap { documentPath == $0 || $0 == "/" || documentPath.hasPrefix($0 + "/") ? $0 : nil }
            ?? previewPath((documentPath as NSString).deletingLastPathComponent) ?? documentPath
    }
    func resolve(_ url: URL) -> String? {
        guard url.scheme == "verde-preview", url.host == "workspace", url.port == nil, url.user == nil, url.password == nil,
              let path = previewPath(url.path), root == "/" || path == root || path.hasPrefix(root + "/") else { return nil }
        return path
    }
}
func previewMime(_ path: String, reported: String?) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    return ["wasm":"application/wasm", "json":"application/json", "css":"text/css", "js":"text/javascript", "mjs":"text/javascript", "cjs":"text/javascript", "html":"text/html", "htm":"text/html", "svg":"image/svg+xml", "mp3":"audio/mpeg", "m4a":"audio/mp4", "wav":"audio/wav", "ogg":"audio/ogg", "woff":"font/woff", "woff2":"font/woff2", "ttf":"font/ttf", "otf":"font/otf"][ext]
        ?? UTType(filenameExtension: ext)?.preferredMIMEType ?? reported ?? "application/octet-stream"
}
let previewCSP = "default-src 'none'; script-src verde-preview: https: http: 'unsafe-inline' 'unsafe-eval' blob:; style-src verde-preview: https: http: 'unsafe-inline'; img-src verde-preview: https: http: data: blob:; media-src verde-preview: https: http: data: blob:; font-src verde-preview: https: http: data:; connect-src verde-preview: https: http:; frame-src 'none'; object-src 'none'; base-uri verde-preview:; form-action 'none'"
func isolatedHTML(_ source: String) -> String {
    #"<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content=""# + previewCSP + #""><meta name="viewport" content="width=device-width, initial-scale=1">"# + previewFailureScript + source
}

private let previewFailureScript = #"""

<script>(()=>{
 const failed=new Set(); let note;
 function render(){if(!document.body)return;if(!note){note=document.createElement('div');note.setAttribute('role','status');note.setAttribute('aria-live','polite');note.tabIndex=0;note.style.cssText='position:fixed!important;bottom:8px!important;left:8px!important;right:8px!important;z-index:2147483647!important;padding:8px!important;background:#fff4d6!important;color:#352800!important;font:13px system-ui!important;-webkit-user-select:text!important;user-select:text!important;border-radius:6px!important';document.body.appendChild(note)}note.textContent=failed.size+(failed.size===1?" linked file couldn't load":" linked files couldn't load");}
 addEventListener('error',e=>{const t=e.target;if(t&&t!==window&&/^(IMG|SCRIPT|LINK|AUDIO|VIDEO|SOURCE)$/.test(t.tagName)){failed.add(t.currentSrc||t.src||t.href||t.tagName);render()}},true);
 addEventListener('DOMContentLoaded',()=>{if(failed.size)render();if(document.fonts)document.fonts.addEventListener('loadingerror',e=>{for(const f of e.fontfaces)failed.add('font:'+f.family);render()})});
})();</script>

"""#

struct HTMLPreview: UIViewRepresentable {
    @Environment(\.dynamicTypeSize) private var textSize
    let source: String
    let location: PreviewLocation
    let access: PreviewAccess?
    func makeCoordinator() -> Coordinator { Coordinator(location: location, access: access) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController = WKUserContentController() // No native message handlers.
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "verde-preview")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsLinkPreview = false
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        _ = textSize
        view.pageZoom = UIFont.preferredFont(forTextStyle: .body).pointSize / 17
        let html = isolatedHTML(source)
        if context.coordinator.html != html { context.coordinator.html = html; view.loadHTMLString(html, baseURL: location.url) }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil; coordinator.cancelAll() }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
        var html: String?
        let location: PreviewLocation
        let access: PreviewAccess?
        private var jobs: [ObjectIdentifier: Job] = [:]
        private final class Job {
            let task: WKURLSchemeTask
            var transfer: UUID?
            init(_ task: WKURLSchemeTask) { self.task = task }
        }
        init(location: PreviewLocation, access: PreviewAccess?) { self.location = location; self.access = access }
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            let request = urlSchemeTask.request
            guard let url = request.url else { return }
            let method = request.httpMethod ?? "GET"
            guard let path = location.resolve(url), ["GET", "HEAD", "OPTIONS"].contains(method), let access else {
                reject(urlSchemeTask, url: url, status: 403); return
            }
            if method == "OPTIONS" { reject(urlSchemeTask, url: url, status: 204); return }
            let job = Job(urlSchemeTask), key = ObjectIdentifier(urlSchemeTask)
            jobs[key] = job
            let stream = HTTPStream(response: { [weak self, weak job] response in
                DispatchQueue.main.sync {
                    guard let self, let job, self.jobs[key] === job else { return }
                    var headers = ["Cache-Control":"no-store", "Access-Control-Allow-Origin":"*", "Access-Control-Expose-Headers":"Content-Length, Content-Range, Accept-Ranges, Last-Modified, ETag", "Content-Security-Policy":previewCSP]
                    for name in ["Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag"] {
                        if let value = response.value(forHTTPHeaderField: name) { headers[name] = value }
                    }
                    headers["Content-Type"] = previewMime(path, reported: response.mimeType)
                    let status = (300..<400).contains(response.statusCode) ? 502 : response.statusCode
                    job.task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
                }
            }, data: { [weak self, weak job] data in
                // Backpressure: at most one URLSession chunk waits for WebKit, rather than queueing a file in memory.
                DispatchQueue.main.sync { guard let self, let job, self.jobs[key] === job else { return }; job.task.didReceive(data) }
            }, complete: { [weak self, weak job] error in
                DispatchQueue.main.sync {
                    guard let self, let job, self.jobs.removeValue(forKey: key) === job else { return }
                    if let error { job.task.didFailWithError(error) } else { job.task.didFinish() }
                }
            })
            job.transfer = access.open(path: path, method: method, range: request.value(forHTTPHeaderField: "Range"), stream: stream)
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            if let transfer = jobs.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.transfer { access?.cancel(transfer) }
        }
        func cancelAll() { jobs.removeAll(); access?.cancelAll() }
        private func reject(_ task: WKURLSchemeTask, url: URL, status: Int) {
            task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Access-Control-Allow-Origin":"*", "Access-Control-Allow-Headers":"Range", "Access-Control-Allow-Methods":"GET, HEAD, OPTIONS"])!)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if let url = action.request.url, location.resolve(url) != nil || url.absoluteString == "about:blank" { return .allow }
            if action.navigationType == .linkActivated, let url = action.request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") { await UIApplication.shared.open(url) }
            return .cancel
        }
    }
}
