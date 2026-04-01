//! Platform-neutral configuration defaults for the future CEF browser runtime.

const build_options = @import("build_options");

/// Describes the runtime shape the desktop shell expects from the CEF backend.
pub const RuntimeConfig = struct {
    subprocess_name: []const u8 = "verde-browser-cef",
    supports_popout: bool = false,
    sdk_configured: bool = build_options.cef_sdk_configured,
    stub_preview: bool = build_options.cef_stub_preview,
};

/// Returns the default runtime config used by the desktop shell.
pub fn defaultRuntimeConfig() RuntimeConfig {
    return .{};
}
