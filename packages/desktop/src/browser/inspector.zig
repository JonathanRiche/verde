//! Browser inspector bundle helpers shared by the desktop browser UI.

const std = @import("std");
const inspector_bundle = @import("browser_inspector_bundle");

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

/// Wraps the bundled inspector runtime with the bridge expected by the CEF renderer process.
pub fn enableScriptAlloc(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\(function() {{
        \\  window.__VERDE_INSPECTOR_BRIDGE__ = {{
        \\    postMessage: function(event) {{
        \\      if (window.__VERDE_CEF_IPC__ && typeof window.__VERDE_CEF_IPC__.postMessage === "function") {{
        \\        window.__VERDE_CEF_IPC__.postMessage(JSON.stringify(event));
        \\      }}
        \\    }}
        \\  }};
        \\  if (!window.VerdeInspector) {{
        \\{s}
        \\  }}
        \\  const handle = window.VerdeInspector && window.VerdeInspector.get ? window.VerdeInspector.get() : null;
        \\  if (handle && typeof handle.enable === "function") {{
        \\    handle.enable();
        \\    return "enabled";
        \\  }}
        \\  if (window.VerdeInspector && typeof window.VerdeInspector.mount === "function") {{
        \\    window.VerdeInspector.mount();
        \\    return "mounted";
        \\  }}
        \\  return "unavailable";
        \\}})();
    ,
        .{bundle},
    );
}
