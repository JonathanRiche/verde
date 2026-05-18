//! Browser inspector bundle helpers shared by the desktop browser UI.

const std = @import("std");
const inspector_bundle = @import("browser_inspector_bundle");
const browser_runtime = @import("mod.zig");

pub const bundle = inspector_bundle.bundle;

pub const disable_script =
    \\(function() {
    \\  const handle = window.VerdeInspector && window.VerdeInspector.get ? window.VerdeInspector.get() : null;
    \\  if (handle && typeof handle.disable === "function") {
    \\    handle.disable();
    \\    return "disabled";
    \\  }
    \\  return "noop";
    \\})();
;

/// Wraps the bundled inspector runtime with the backend-neutral browser bridge.
pub fn enableScriptAlloc(allocator: std.mem.Allocator, mode: browser_runtime.InspectorMode) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\(function() {{
        \\  const mode = "{s}";
        \\  const postToBridge = function(payload) {{
        \\    if (window.__VERDE_BROWSER_IPC__ && typeof window.__VERDE_BROWSER_IPC__.postMessage === "function") {{
        \\      window.__VERDE_BROWSER_IPC__.postMessage(payload);
        \\      return true;
        \\    }}
        \\    if (window.__VERDE_CEF_IPC__ && typeof window.__VERDE_CEF_IPC__.postMessage === "function") {{
        \\      window.__VERDE_CEF_IPC__.postMessage(payload);
        \\      return true;
        \\    }}
        \\    if (window.verde && typeof window.verde.postMessage === "function") {{
        \\      window.verde.postMessage(payload);
        \\      return true;
        \\    }}
        \\    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.verde) {{
        \\      window.webkit.messageHandlers.verde.postMessage(payload);
        \\      return true;
        \\    }}
        \\    return false;
        \\  }};
        \\  window.__VERDE_INSPECTOR_BRIDGE__ = {{
        \\    postMessage: function(event) {{
        \\      postToBridge(JSON.stringify(event));
        \\    }}
        \\  }};
        \\  if (!window.VerdeInspector) {{
        \\{s}
        \\  }}
        \\  const handle = window.VerdeInspector && window.VerdeInspector.get ? window.VerdeInspector.get() : null;
        \\  if (handle && typeof handle.setMode === "function") {{
        \\    handle.setMode(mode);
        \\  }}
        \\  if (handle && typeof handle.enable === "function") {{
        \\    handle.enable();
        \\    return "enabled";
        \\  }}
        \\  if (window.VerdeInspector && typeof window.VerdeInspector.mount === "function") {{
        \\    window.VerdeInspector.mount({{ mode: mode }});
        \\    return "mounted";
        \\  }}
        \\  return "unavailable";
        \\}})();
    ,
        .{ mode.jsValue(), bundle },
    );
}
