import AppKit
import Foundation
import WebKit

private enum VerdeMacBrowserEventKind: Int32 {
    case opened = 1
    case closed = 2
    case navigated = 3
    case titleChanged = 4
    case documentLoaded = 5
    case jsMessage = 6
    case evalResult = 7
    case failed = 8
}

private final class VerdeMacBrowserEvent {
    let kind: Int32
    let payload: String?

    init(kind: VerdeMacBrowserEventKind, payload: String? = nil) {
        self.kind = kind.rawValue
        self.payload = payload
    }
}

private final class VerdeFocusSinkView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private final class VerdeMacBrowser: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private weak var window: NSWindow?
    private let focusSink: VerdeFocusSinkView
    private let container: NSView
    private let webView: WKWebView
    private var events: [VerdeMacBrowserEvent] = []
    private let eventLock = NSLock()
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private var visible = false
    private var invalidated = false

    init(window: NSWindow) {
        self.window = window
        Self.configureForegroundApp(window: window)

        let contentController = WKUserContentController()
        let bridgeScript = """
        (function(){
          const bridge={postMessage:function(payload){window.webkit.messageHandlers.verde.postMessage(String(payload));}};
          window.__VERDE_BROWSER_IPC__=bridge;
          window.__VERDE_CEF_IPC__=bridge;
          window.verde=bridge;
        })();
        """
        contentController.addUserScript(WKUserScript(source: bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        self.focusSink = VerdeFocusSinkView(frame: .zero)
        self.container = NSView(frame: .zero)
        self.container.isHidden = true
        self.container.autoresizesSubviews = true
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView.autoresizingMask = [.width, .height]

        super.init()

        contentController.add(self, name: "verde")
        self.webView.navigationDelegate = self
        self.container.addSubview(self.webView)
        window.contentView?.addSubview(self.focusSink, positioned: .below, relativeTo: nil)
        window.contentView?.addSubview(self.container, positioned: .above, relativeTo: nil)

        self.titleObservation = self.webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            guard let self, !self.invalidated, let title = webView.title, !title.isEmpty else { return }
            self.queueEvent(.titleChanged, payload: title)
        }
        self.urlObservation = self.webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            guard let self, !self.invalidated, let absolute = webView.url?.absoluteString, !absolute.isEmpty else { return }
            self.queueEvent(.navigated, payload: absolute)
        }
        self.webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        if invalidated { return }
        invalidated = true
        titleObservation?.invalidate()
        titleObservation = nil
        urlObservation?.invalidate()
        urlObservation = nil
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "verde")
        webView.stopLoading()
        focusSink.removeFromSuperview()
        container.removeFromSuperview()
    }

    func queueEvent(_ kind: VerdeMacBrowserEventKind, payload: String? = nil) {
        if invalidated { return }
        eventLock.lock()
        events.append(VerdeMacBrowserEvent(kind: kind, payload: payload))
        eventLock.unlock()
    }

    func popEvent() -> VerdeMacBrowserEvent? {
        eventLock.lock()
        defer { eventLock.unlock() }
        if events.isEmpty { return nil }
        return events.removeFirst()
    }

    func setBounds(x: Int32, y: Int32, width: Int32, height: Int32) {
        guard width > 0, height > 0, let window, let contentView = window.contentView else { return }
        let scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 1.0
        let pointWidth = max(CGFloat(width) / scale, 1.0)
        let pointHeight = max(CGFloat(height) / scale, 1.0)
        let screen = window.screen ?? NSScreen.main
        let screenTop = screen?.frame.maxY ?? 0
        let targetScreenRect = NSRect(x: CGFloat(x) / scale, y: screenTop - (CGFloat(y) / scale) - pointHeight, width: pointWidth, height: pointHeight)
        let contentWindowRect = contentView.convert(contentView.bounds, to: nil)
        let contentScreenRect = window.convertToScreen(contentWindowRect)

        container.frame = NSRect(
            x: targetScreenRect.origin.x - contentScreenRect.origin.x,
            y: targetScreenRect.origin.y - contentScreenRect.origin.y,
            width: pointWidth,
            height: pointHeight
        )
        webView.frame = container.bounds
    }

    func show() {
        Self.configureForegroundApp(window: window)
        if !visible {
            visible = true
            queueEvent(.opened)
        }
        container.isHidden = false
    }

    func hide() {
        if visible {
            visible = false
            queueEvent(.closed)
        }
        container.isHidden = true
    }

    func navigate(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else {
            queueEvent(.failed, payload: "Invalid URL")
            return false
        }
        webView.load(URLRequest(url: url))
        return true
    }

    func eval(_ script: String) {
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self, !self.invalidated else { return }
            if let error {
                self.queueEvent(.failed, payload: error.localizedDescription)
                return
            }
            self.queueEvent(.evalResult, payload: Self.jsonOrDescription(result))
        }
    }

    func postJson(_ json: String) {
        let script = "(function(){const payload=\(json);window.dispatchEvent(new MessageEvent('verde-host-message',{data:payload}));})()"
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let self, !self.invalidated, let error else { return }
            self.queueEvent(.failed, payload: error.localizedDescription)
        }
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    func goForward() {
        if webView.canGoForward { webView.goForward() }
    }

    func reload() {
        webView.reload()
    }

    func focus() {
        guard let window else { return }
        Self.configureForegroundApp(window: window)
        window.makeFirstResponder(webView)
    }

    func blur() {
        window?.makeFirstResponder(focusSink)
    }

    func hasFocus() -> Bool {
        guard let window, window.isKeyWindow, NSApp.isActive, let responder = window.firstResponder else { return false }
        if responder === webView { return true }
        if let view = responder as? NSView {
            return view === webView || view.isDescendant(of: webView)
        }
        return false
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let payload = (message.body as? String) ?? Self.jsonOrDescription(message.body)
        queueEvent(.jsMessage, payload: payload)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        queueEvent(.documentLoaded)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        queueEvent(.failed, payload: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        queueEvent(.failed, payload: error.localizedDescription)
    }

    private static func jsonOrDescription(_ value: Any?) -> String {
        guard let value else { return "null" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        if let string = value as? String {
            return string
        }
        return String(describing: value)
    }

    static func configureForegroundApp(window: NSWindow? = nil) {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)

        if let window {
            window.canHide = false
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.setIsVisible(true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
        }

        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
    }

    func appKitDiagnostics() -> String {
        return Self.appKitDiagnostics(window: window, webView: webView, container: container)
    }

    static func appKitDiagnostics(window: NSWindow?, webView: WKWebView? = nil, container: NSView? = nil) -> String {
        let responderDescription: String
        if let responder = window?.firstResponder {
            responderDescription = String(describing: type(of: responder))
        } else {
            responderDescription = "null"
        }

        var payload: [String: Any] = [
            "appActive": NSApp.isActive,
            "activationPolicy": NSApp.activationPolicy().rawValue,
            "appWindowCount": NSApp.windows.count,
            "runningApplicationActive": NSRunningApplication.current.isActive,
            "hasKeyWindow": NSApp.keyWindow != nil,
            "hasMainWindow": NSApp.mainWindow != nil,
        ]

        if let window {
            payload["windowPresent"] = true
            payload["windowTitle"] = window.title
            payload["windowIsVisible"] = window.isVisible
            payload["windowIsKey"] = window.isKeyWindow
            payload["windowIsMain"] = window.isMainWindow
            payload["windowCanBecomeKey"] = window.canBecomeKey
            payload["windowCanBecomeMain"] = window.canBecomeMain
            payload["windowIsMiniaturized"] = window.isMiniaturized
            payload["windowCanHide"] = window.canHide
            payload["windowStyleMask"] = window.styleMask.rawValue
            payload["windowLevel"] = window.level.rawValue
            payload["windowFrame"] = [
                "x": window.frame.origin.x,
                "y": window.frame.origin.y,
                "width": window.frame.size.width,
                "height": window.frame.size.height,
            ]
            payload["contentViewSubviewCount"] = window.contentView?.subviews.count ?? 0
            payload["firstResponder"] = responderDescription
        } else {
            payload["windowPresent"] = false
        }

        if let webView {
            payload["webViewWindowAttached"] = webView.window != nil
            payload["webViewHidden"] = webView.isHidden
            payload["webViewFrame"] = [
                "x": webView.frame.origin.x,
                "y": webView.frame.origin.y,
                "width": webView.frame.size.width,
                "height": webView.frame.size.height,
            ]
        }

        if let container {
            payload["containerWindowAttached"] = container.window != nil
            payload["containerHidden"] = container.isHidden
            payload["containerFrame"] = [
                "x": container.frame.origin.x,
                "y": container.frame.origin.y,
                "width": container.frame.size.width,
                "height": container.frame.size.height,
            ]
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

private func onMain<T>(_ body: @escaping () -> T) -> T {
    if Thread.isMainThread {
        return body()
    }
    return DispatchQueue.main.sync(execute: body)
}

private func stringFromCString(_ value: UnsafePointer<CChar>?) -> String {
    guard let value else { return "" }
    return String(cString: value)
}

private func browserFromOpaque(_ handle: UnsafeMutableRawPointer?) -> VerdeMacBrowser? {
    guard let handle else { return nil }
    return Unmanaged<VerdeMacBrowser>.fromOpaque(handle).takeUnretainedValue()
}

@_cdecl("verde_macos_webview_create")
public func verde_macos_webview_create(_ nsWindow: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let nsWindow else { return nil }
    return onMain {
        let window = Unmanaged<NSWindow>.fromOpaque(nsWindow).takeUnretainedValue()
        let browser = VerdeMacBrowser(window: window)
        return Unmanaged.passRetained(browser).toOpaque()
    }
}

@_cdecl("verde_macos_app_configure_foreground")
public func verde_macos_app_configure_foreground() {
    onMain {
        VerdeMacBrowser.configureForegroundApp()
    }
}

@_cdecl("verde_macos_webview_appkit_diagnostics")
public func verde_macos_webview_appkit_diagnostics(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
    onMain {
        let json: String
        if let browser = browserFromOpaque(handle) {
            json = browser.appKitDiagnostics()
        } else {
            json = VerdeMacBrowser.appKitDiagnostics(window: nil)
        }
        return strdup(json)
    }
}

@_cdecl("verde_macos_webview_destroy")
public func verde_macos_webview_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    onMain {
        let browser = Unmanaged<VerdeMacBrowser>.fromOpaque(handle).takeRetainedValue()
        browser.invalidate()
    }
}

@_cdecl("verde_macos_webview_show")
public func verde_macos_webview_show(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    onMain {
        guard let browser = browserFromOpaque(handle) else { return 0 }
        browser.show()
        return 1
    }
}

@_cdecl("verde_macos_webview_hide")
public func verde_macos_webview_hide(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    onMain {
        guard let browser = browserFromOpaque(handle) else { return 0 }
        browser.hide()
        return 1
    }
}

@_cdecl("verde_macos_webview_set_bounds")
public func verde_macos_webview_set_bounds(_ handle: UnsafeMutableRawPointer?, _ x: Int32, _ y: Int32, _ width: Int32, _ height: Int32) -> Int32 {
    onMain {
        guard let browser = browserFromOpaque(handle) else { return 0 }
        browser.setBounds(x: x, y: y, width: width, height: height)
        return 1
    }
}

@_cdecl("verde_macos_webview_navigate")
public func verde_macos_webview_navigate(_ handle: UnsafeMutableRawPointer?, _ url: UnsafePointer<CChar>?) -> Int32 {
    onMain {
        guard let browser = browserFromOpaque(handle), let url else { return 0 }
        return browser.navigate(stringFromCString(url)) ? 1 : 0
    }
}

@_cdecl("verde_macos_webview_eval")
public func verde_macos_webview_eval(_ handle: UnsafeMutableRawPointer?, _ js: UnsafePointer<CChar>?) -> Int32 {
    onMain {
        guard let browser = browserFromOpaque(handle), let js else { return 0 }
        browser.eval(stringFromCString(js))
        return 1
    }
}

@_cdecl("verde_macos_webview_post_json")
public func verde_macos_webview_post_json(_ handle: UnsafeMutableRawPointer?, _ json: UnsafePointer<CChar>?) -> Int32 {
    onMain {
        guard let browser = browserFromOpaque(handle), let json else { return 0 }
        browser.postJson(stringFromCString(json))
        return 1
    }
}

@_cdecl("verde_macos_webview_go_back")
public func verde_macos_webview_go_back(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    onMain {
        guard let browser = browserFromOpaque(handle) else { return 0 }
        browser.goBack()
        return 1
    }
}

@_cdecl("verde_macos_webview_go_forward")
public func verde_macos_webview_go_forward(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    onMain {
        guard let browser = browserFromOpaque(handle) else { return 0 }
        browser.goForward()
        return 1
    }
}

@_cdecl("verde_macos_webview_reload")
public func verde_macos_webview_reload(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    onMain {
        guard let browser = browserFromOpaque(handle) else { return 0 }
        browser.reload()
        return 1
    }
}

@_cdecl("verde_macos_webview_focus")
public func verde_macos_webview_focus(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    onMain {
        guard let browser = browserFromOpaque(handle) else { return 0 }
        browser.focus()
        return 1
    }
}

@_cdecl("verde_macos_webview_blur")
public func verde_macos_webview_blur(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    onMain {
        guard let browser = browserFromOpaque(handle) else { return 0 }
        browser.blur()
        return 1
    }
}

@_cdecl("verde_macos_webview_has_focus")
public func verde_macos_webview_has_focus(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    onMain {
        guard let browser = browserFromOpaque(handle) else { return 0 }
        return browser.hasFocus() ? 1 : 0
    }
}

@_cdecl("verde_macos_webview_pop_event")
public func verde_macos_webview_pop_event(_ handle: UnsafeMutableRawPointer?, _ kind: UnsafeMutablePointer<Int32>?, _ payload: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    guard let kind, let payload else { return 0 }
    return onMain {
        guard let browser = browserFromOpaque(handle), let event = browser.popEvent() else { return 0 }
        kind.pointee = event.kind
        payload.pointee = event.payload.flatMap { strdup($0) }
        return 1
    }
}

@_cdecl("verde_macos_webview_free_string")
public func verde_macos_webview_free_string(_ value: UnsafeMutablePointer<CChar>?) {
    free(value)
}
