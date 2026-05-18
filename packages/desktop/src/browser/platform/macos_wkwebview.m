#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#include <stdlib.h>
#include <string.h>

enum VerdeMacBrowserEventKind {
    VERDE_MAC_BROWSER_EVENT_OPENED = 1,
    VERDE_MAC_BROWSER_EVENT_CLOSED = 2,
    VERDE_MAC_BROWSER_EVENT_NAVIGATED = 3,
    VERDE_MAC_BROWSER_EVENT_TITLE_CHANGED = 4,
    VERDE_MAC_BROWSER_EVENT_DOCUMENT_LOADED = 5,
    VERDE_MAC_BROWSER_EVENT_JS_MESSAGE = 6,
    VERDE_MAC_BROWSER_EVENT_EVAL_RESULT = 7,
    VERDE_MAC_BROWSER_EVENT_FAILED = 8,
};

@interface VerdeMacBrowserEvent : NSObject
@property(nonatomic) int kind;
@property(nonatomic, copy, nullable) NSString *payload;
+ (instancetype)eventWithKind:(int)kind payload:(nullable NSString *)payload;
@end

@implementation VerdeMacBrowserEvent
+ (instancetype)eventWithKind:(int)kind payload:(nullable NSString *)payload {
    VerdeMacBrowserEvent *event = [[VerdeMacBrowserEvent alloc] init];
    event.kind = kind;
    event.payload = payload;
    return event;
}
@end

@interface VerdeMacBrowser : NSObject <WKScriptMessageHandler, WKNavigationDelegate>
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, strong) NSView *container;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) NSMutableArray<VerdeMacBrowserEvent *> *events;
@property(nonatomic) BOOL visible;
@property(nonatomic) BOOL invalidated;
- (instancetype)initWithWindow:(NSWindow *)window;
- (void)invalidate;
- (void)queueEvent:(int)kind payload:(nullable NSString *)payload;
- (void)setScreenX:(int)x y:(int)y width:(int)width height:(int)height;
@end

static NSString *VerdeMacStringFromCString(const char *value) {
    if (value == NULL) return @"";
    return [NSString stringWithUTF8String:value] ?: @"";
}

static NSString *VerdeMacJSONOrDescription(id value) {
    if (value == nil || value == [NSNull null]) return @"null";
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];
    if (data != nil) {
        NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (json != nil) return json;
    }
    return [value description] ?: @"null";
}

@implementation VerdeMacBrowser

- (instancetype)initWithWindow:(NSWindow *)window {
    self = [super init];
    if (self == nil) return nil;

    _window = window;
    _events = [NSMutableArray array];

    WKUserContentController *contentController = [[WKUserContentController alloc] init];
    WKUserScript *bridgeScript = [[WKUserScript alloc]
        initWithSource:@"(function(){"
                       "const bridge={postMessage:function(payload){window.webkit.messageHandlers.verde.postMessage(String(payload));}};"
                       "window.__VERDE_BROWSER_IPC__=bridge;"
                       "window.__VERDE_CEF_IPC__=bridge;"
                       "window.verde=bridge;"
                       "})();"
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:NO];
    [contentController addUserScript:bridgeScript];
    [contentController addScriptMessageHandler:self name:@"verde"];

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.userContentController = contentController;
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = YES;

    _container = [[NSView alloc] initWithFrame:NSZeroRect];
    _container.hidden = YES;
    _container.autoresizesSubviews = YES;

    _webView = [[WKWebView alloc] initWithFrame:_container.bounds configuration:configuration];
    _webView.navigationDelegate = self;
    _webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_container addSubview:_webView];

    NSView *contentView = window.contentView;
    [contentView addSubview:_container positioned:NSWindowAbove relativeTo:nil];
    [_webView addObserver:self forKeyPath:@"title" options:NSKeyValueObservingOptionNew context:NULL];
    [_webView addObserver:self forKeyPath:@"URL" options:NSKeyValueObservingOptionNew context:NULL];
    [_webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]]];
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (void)invalidate {
    if (self.invalidated) return;
    self.invalidated = YES;
    @try {
        [_webView removeObserver:self forKeyPath:@"title"];
        [_webView removeObserver:self forKeyPath:@"URL"];
    } @catch (__unused NSException *exception) {
    }
    _webView.navigationDelegate = nil;
    [_webView.configuration.userContentController removeScriptMessageHandlerForName:@"verde"];
    [_webView stopLoading];
    [_container removeFromSuperview];
}

- (void)queueEvent:(int)kind payload:(nullable NSString *)payload {
    if (self.invalidated) return;
    @synchronized(self.events) {
        [self.events addObject:[VerdeMacBrowserEvent eventWithKind:kind payload:payload]];
    }
}

- (void)setScreenX:(int)x y:(int)y width:(int)width height:(int)height {
    if (width <= 0 || height <= 0 || self.window == nil || self.window.contentView == nil) return;

    CGFloat scale = self.window.backingScaleFactor > 0.0 ? self.window.backingScaleFactor : 1.0;
    CGFloat pointHeight = MAX((CGFloat)height / scale, 1.0);
    CGFloat pointWidth = MAX((CGFloat)width / scale, 1.0);
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    CGFloat screenTop = NSMaxY(screen.frame);
    NSRect targetScreenRect = NSMakeRect(
        (CGFloat)x / scale,
        screenTop - ((CGFloat)y / scale) - pointHeight,
        pointWidth,
        pointHeight);
    NSRect contentWindowRect = [self.window.contentView convertRect:self.window.contentView.bounds toView:nil];
    NSRect contentScreenRect = [self.window convertRectToScreen:contentWindowRect];

    self.container.frame = NSMakeRect(
        targetScreenRect.origin.x - contentScreenRect.origin.x,
        targetScreenRect.origin.y - contentScreenRect.origin.y,
        pointWidth,
        pointHeight);
    self.webView.frame = self.container.bounds;
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)userContentController;
    NSString *payload = [message.body isKindOfClass:[NSString class]] ? (NSString *)message.body : VerdeMacJSONOrDescription(message.body);
    [self queueEvent:VERDE_MAC_BROWSER_EVENT_JS_MESSAGE payload:payload];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)webView;
    (void)navigation;
    [self queueEvent:VERDE_MAC_BROWSER_EVENT_DOCUMENT_LOADED payload:nil];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)webView;
    (void)navigation;
    [self queueEvent:VERDE_MAC_BROWSER_EVENT_FAILED payload:error.localizedDescription ?: @"Navigation failed"];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)webView;
    (void)navigation;
    [self queueEvent:VERDE_MAC_BROWSER_EVENT_FAILED payload:error.localizedDescription ?: @"Navigation failed"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    (void)object;
    (void)change;
    (void)context;
    if ([keyPath isEqualToString:@"title"]) {
        if (self.webView.title.length > 0) {
            [self queueEvent:VERDE_MAC_BROWSER_EVENT_TITLE_CHANGED payload:self.webView.title];
        }
    } else if ([keyPath isEqualToString:@"URL"]) {
        NSString *absolute = self.webView.URL.absoluteString;
        if (absolute.length > 0) {
            [self queueEvent:VERDE_MAC_BROWSER_EVENT_NAVIGATED payload:absolute];
        }
    }
}

@end

void *verde_macos_webview_create(void *ns_window) {
    if (ns_window == NULL) return NULL;
    NSWindow *window = (__bridge NSWindow *)ns_window;
    VerdeMacBrowser *browser = [[VerdeMacBrowser alloc] initWithWindow:window];
    return (__bridge_retained void *)browser;
}

void verde_macos_webview_destroy(void *handle) {
    if (handle == NULL) return;
    VerdeMacBrowser *browser = (__bridge VerdeMacBrowser *)handle;
    [browser invalidate];
    CFBridgingRelease(handle);
}

int verde_macos_webview_show(void *handle) {
    if (handle == NULL) return 0;
    VerdeMacBrowser *browser = (__bridge VerdeMacBrowser *)handle;
    if (!browser.visible) {
        browser.visible = YES;
        [browser queueEvent:VERDE_MAC_BROWSER_EVENT_OPENED payload:nil];
    }
    browser.container.hidden = NO;
    [browser.window makeFirstResponder:browser.webView];
    return 1;
}

int verde_macos_webview_hide(void *handle) {
    if (handle == NULL) return 0;
    VerdeMacBrowser *browser = (__bridge VerdeMacBrowser *)handle;
    if (browser.visible) {
        browser.visible = NO;
        [browser queueEvent:VERDE_MAC_BROWSER_EVENT_CLOSED payload:nil];
    }
    browser.container.hidden = YES;
    return 1;
}

int verde_macos_webview_set_bounds(void *handle, int x, int y, int width, int height) {
    if (handle == NULL) return 0;
    VerdeMacBrowser *browser = (__bridge VerdeMacBrowser *)handle;
    [browser setScreenX:x y:y width:width height:height];
    return 1;
}

int verde_macos_webview_navigate(void *handle, const char *url) {
    if (handle == NULL || url == NULL) return 0;
    VerdeMacBrowser *browser = (__bridge VerdeMacBrowser *)handle;
    NSString *urlString = VerdeMacStringFromCString(url);
    NSURL *nsURL = [NSURL URLWithString:urlString];
    if (nsURL == nil) {
        [browser queueEvent:VERDE_MAC_BROWSER_EVENT_FAILED payload:@"Invalid URL"];
        return 0;
    }
    [browser.webView loadRequest:[NSURLRequest requestWithURL:nsURL]];
    return 1;
}

int verde_macos_webview_eval(void *handle, const char *js) {
    if (handle == NULL || js == NULL) return 0;
    VerdeMacBrowser *browser = (__bridge VerdeMacBrowser *)handle;
    NSString *script = VerdeMacStringFromCString(js);
    [browser.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (error != nil) {
            [browser queueEvent:VERDE_MAC_BROWSER_EVENT_FAILED payload:error.localizedDescription ?: @"JavaScript evaluation failed"];
            return;
        }
        [browser queueEvent:VERDE_MAC_BROWSER_EVENT_EVAL_RESULT payload:VerdeMacJSONOrDescription(result)];
    }];
    return 1;
}

int verde_macos_webview_post_json(void *handle, const char *json) {
    if (handle == NULL || json == NULL) return 0;
    VerdeMacBrowser *browser = (__bridge VerdeMacBrowser *)handle;
    NSString *payload = VerdeMacStringFromCString(json);
    NSString *script = [NSString stringWithFormat:
        @"(function(){const payload=%@;window.dispatchEvent(new MessageEvent('verde-host-message',{data:payload}));})()",
        payload];
    [browser.webView evaluateJavaScript:script completionHandler:^(__unused id result, NSError *error) {
        if (error != nil) {
            [browser queueEvent:VERDE_MAC_BROWSER_EVENT_FAILED payload:error.localizedDescription ?: @"Browser JSON dispatch failed"];
        }
    }];
    return 1;
}

int verde_macos_webview_go_back(void *handle) {
    if (handle == NULL) return 0;
    VerdeMacBrowser *browser = (__bridge VerdeMacBrowser *)handle;
    if (browser.webView.canGoBack) [browser.webView goBack];
    return 1;
}

int verde_macos_webview_go_forward(void *handle) {
    if (handle == NULL) return 0;
    VerdeMacBrowser *browser = (__bridge VerdeMacBrowser *)handle;
    if (browser.webView.canGoForward) [browser.webView goForward];
    return 1;
}

int verde_macos_webview_reload(void *handle) {
    if (handle == NULL) return 0;
    VerdeMacBrowser *browser = (__bridge VerdeMacBrowser *)handle;
    [browser.webView reload];
    return 1;
}

int verde_macos_webview_focus(void *handle) {
    if (handle == NULL) return 0;
    VerdeMacBrowser *browser = (__bridge VerdeMacBrowser *)handle;
    [browser.window makeFirstResponder:browser.webView];
    return 1;
}

int verde_macos_webview_blur(void *handle) {
    if (handle == NULL) return 0;
    VerdeMacBrowser *browser = (__bridge VerdeMacBrowser *)handle;
    [browser.window makeFirstResponder:browser.window.contentView];
    return 1;
}

int verde_macos_webview_pop_event(void *handle, int *kind, char **payload) {
    if (handle == NULL || kind == NULL || payload == NULL) return 0;
    VerdeMacBrowser *browser = (__bridge VerdeMacBrowser *)handle;
    VerdeMacBrowserEvent *event = nil;
    @synchronized(browser.events) {
        if (browser.events.count == 0) return 0;
        event = browser.events.firstObject;
        [browser.events removeObjectAtIndex:0];
    }
    *kind = event.kind;
    *payload = event.payload != nil ? strdup(event.payload.UTF8String) : NULL;
    return 1;
}

void verde_macos_webview_free_string(char *value) {
    free(value);
}
