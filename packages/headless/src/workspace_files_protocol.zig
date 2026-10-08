//! Read-only workspace file browsing: a lazy directory tree and file preview
//! confined to a workspace's folders. Client-agnostic (desktop, web, mobile).
//!
//! Roots are the workspace home plus the enabled extra folders from its
//! `verde.toml` (`[folders.*]`), resolved on the daemon that owns the
//! workspace. Clients address entries as `(root, path)`: an opaque root id
//! and a `/`-separated path relative to that root ("" is the root itself).
//! Every request is re-confined beneath the root without following symlinks
//! out of it, so a client path can never widen access. `Root.path` is the
//! daemon host's absolute folder, informational only (agent prompts, local
//! "open externally"); requests never accept absolute paths.
//!
//! Methods (paired-device scope `repository:read`; read-only, never drained):
//! - `workspace.files.list` ListRequest -> ListResult
//! - `workspace.files.read` ReadRequest -> ReadResult
//!
//! `list` without `root` returns only `roots`. With `root` it also returns
//! the children of `path`: directories first, then files, each group
//! name-sorted case-insensitively, at most `limit` entries (`truncated` set
//! when more exist). `.git` is never listed; gitignored entries carry
//! `ignored = true` so clients can dim them. Symlinks are listed only when
//! they resolve beneath the same root.
//!
//! `read` classifies by extension and content (`kindForPath` + NUL/UTF-8
//! sniff). Text and markdown return UTF-8 `content` up to `max_bytes`, cut
//! on a codepoint boundary with `truncated` set. Images return base64
//! `content` when the file is at most `max_image_bytes`, else `too_large`.
//! Binary, PDF, Office, SVG and archive files return no content; clients
//! offer to open them externally. Clients with a 1 MiB transport cap (paired
//! web/mobile) should pass `max_bytes` and `max_image_bytes` that leave room
//! for JSON escaping and base64 (4/3) overhead.
//!
//! Error codes (stable): `invalid_params` (missing/absolute/`..` path),
//! `resource_not_found` (unknown workspace), `store_unavailable`,
//! `root_not_found`, `not_found`, `not_directory`, `not_file`,
//! `path_outside_roots` (symlink escape or unreadable).

const std = @import("std");

pub const METHOD_LIST: []const u8 = "workspace.files.list";
pub const METHOD_READ: []const u8 = "workspace.files.read";

pub const ERR_ROOT_NOT_FOUND: []const u8 = "root_not_found";
pub const ERR_PATH_OUTSIDE_ROOTS: []const u8 = "path_outside_roots";
pub const ERR_NOT_FOUND: []const u8 = "not_found";
pub const ERR_NOT_DIRECTORY: []const u8 = "not_directory";
pub const ERR_NOT_FILE: []const u8 = "not_file";

/// Root id of the workspace home; extra folders use their verde.toml name.
pub const HOME_ROOT_ID: []const u8 = "home";

/// Default and maximum children returned for one directory.
pub const DEFAULT_LIST_ENTRIES: u32 = 2000;
pub const MAX_LIST_ENTRIES: u32 = 5000;
/// Default and maximum text bytes in one `read` response.
pub const DEFAULT_TEXT_BYTES: u64 = 2 * 1024 * 1024;
pub const MAX_TEXT_BYTES: u64 = 4 * 1024 * 1024;
/// Default and maximum raw image bytes returned (base64 grows them by 4/3).
pub const DEFAULT_IMAGE_BYTES: u64 = 4 * 1024 * 1024;
pub const MAX_IMAGE_BYTES: u64 = 6 * 1024 * 1024;
/// Leading bytes inspected for NUL when sniffing binary content.
pub const SNIFF_BYTES: usize = 8192;

pub const EntryKind = enum { directory, file };

pub const Root = struct {
    /// Opaque, stable for the workspace configuration: `HOME_ROOT_ID` or the
    /// verde.toml folder name.
    id: []const u8,
    /// Display name: folder name from verde.toml, or the home's basename.
    name: []const u8,
    /// Absolute path on the daemon host (informational).
    path: []const u8,
};

pub const Entry = struct {
    name: []const u8,
    /// Root-relative path of this entry.
    path: []const u8,
    kind: EntryKind,
    /// File size in bytes; 0 for directories.
    size: u64 = 0,
    /// Matched by the repository's ignore rules (and not tracked).
    ignored: bool = false,
    symlink: bool = false,
};

pub const ListRequest = struct {
    workspace_id: []const u8,
    /// Root id; null lists only the roots.
    root: ?[]const u8 = null,
    /// Root-relative directory; "" or null is the root itself.
    path: ?[]const u8 = null,
    /// Entry cap, clamped to `MAX_LIST_ENTRIES`.
    limit: ?u32 = null,
};

pub const ListResult = struct {
    roots: []const Root = &.{},
    root: ?[]const u8 = null,
    path: ?[]const u8 = null,
    entries: []const Entry = &.{},
    truncated: bool = false,
};

pub const ContentKind = enum {
    text,
    markdown,
    image,
    /// Non-text content (NUL bytes or invalid UTF-8).
    binary,
    /// Known document/archive/media types shown externally (PDF, Office, SVG).
    external,
    /// An image above the request's `max_image_bytes`.
    too_large,
};

pub const Encoding = enum { none, utf8, base64 };

pub const ReadRequest = struct {
    workspace_id: []const u8,
    root: []const u8,
    /// Root-relative file path.
    path: []const u8,
    /// Text byte cap, clamped to `MAX_TEXT_BYTES`.
    max_bytes: ?u64 = null,
    /// Raw image byte cap, clamped to `MAX_IMAGE_BYTES`.
    max_image_bytes: ?u64 = null,
};

pub const ReadResult = struct {
    root: []const u8,
    path: []const u8,
    name: []const u8,
    size: u64,
    kind: ContentKind,
    mime: ?[]const u8 = null,
    encoding: Encoding = .none,
    content: []const u8 = "",
    truncated: bool = false,
};

/// Normalises a client root-relative path: strips `.` components and
/// redundant slashes. Null for absolute paths, `..`, NUL or backslashes.
/// Returns "" for the root itself.
pub fn normalizeRelative(arena: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!?[]const u8 {
    if (raw.len > std.fs.max_path_bytes) return null;
    if (raw.len > 0 and raw[0] == '/') return null;
    if (std.mem.indexOfAny(u8, raw, "\\\x00") != null) return null;
    var out: std.ArrayList(u8) = .empty;
    var parts = std.mem.tokenizeScalar(u8, raw, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return null;
        if (out.items.len > 0) try out.append(arena, '/');
        try out.appendSlice(arena, part);
    }
    return out.items;
}

const image_exts = [_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "bmp" };
const markdown_exts = [_][]const u8{ "md", "markdown", "mdx" };
const external_exts = [_][]const u8{ "pdf", "svg", "pptx", "ppt", "odp", "docx", "doc", "odt", "xlsx", "xls", "ods", "rtf", "zip", "gz", "tgz", "xz", "zst", "7z", "rar", "jar", "exe", "dll", "so", "dylib", "o", "a", "wasm", "mp3", "mp4", "mov", "webm", "wav", "ogg", "flac", "ttf", "otf", "woff", "woff2", "ico", "sqlite", "db" };

/// Lower-case extension without the dot; empty for none or dotfiles.
pub fn extension(path: []const u8, buffer: *[16]u8) []const u8 {
    const name = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0 or name.len - dot - 1 > buffer.len) return "";
    return std.ascii.lowerString(buffer, name[dot + 1 ..]);
}

/// Kind implied by the file name alone; `text` still needs a content sniff.
pub fn kindForPath(path: []const u8) ContentKind {
    var buffer: [16]u8 = undefined;
    const ext = extension(path, &buffer);
    for (image_exts) |candidate| if (std.mem.eql(u8, ext, candidate)) return .image;
    for (markdown_exts) |candidate| if (std.mem.eql(u8, ext, candidate)) return .markdown;
    for (external_exts) |candidate| if (std.mem.eql(u8, ext, candidate)) return .external;
    return .text;
}

pub fn mimeForPath(path: []const u8) ?[]const u8 {
    var buffer: [16]u8 = undefined;
    const ext = extension(path, &buffer);
    const table = [_]struct { []const u8, []const u8 }{
        .{ "png", "image/png" },     .{ "jpg", "image/jpeg" },       .{ "jpeg", "image/jpeg" },
        .{ "gif", "image/gif" },     .{ "webp", "image/webp" },      .{ "bmp", "image/bmp" },
        .{ "svg", "image/svg+xml" }, .{ "pdf", "application/pdf" }, .{ "md", "text/markdown" },
        .{ "markdown", "text/markdown" },
    };
    for (table) |row| if (std.mem.eql(u8, ext, row[0])) return row[1];
    return null;
}

/// True when the leading bytes look like text (no NUL).
pub fn looksTextual(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, SNIFF_BYTES)], 0) == null;
}

/// Longest prefix of `bytes` that ends on a UTF-8 codepoint boundary.
pub fn utf8Prefix(bytes: []const u8) []const u8 {
    var end = bytes.len;
    var back: usize = 0;
    while (end > 0 and back < 4) : (back += 1) {
        const byte = bytes[end - 1];
        if (byte & 0x80 == 0) return bytes;
        if (byte & 0xc0 == 0xc0) {
            const need = std.unicode.utf8ByteSequenceLength(byte) catch return bytes[0 .. end - 1];
            return if (bytes.len - (end - 1) >= need) bytes else bytes[0 .. end - 1];
        }
        end -= 1;
    }
    return bytes;
}

test "kind and mime classification follow the shared preview rules" {
    try std.testing.expectEqual(ContentKind.image, kindForPath("/a/Logo.PNG"));
    try std.testing.expectEqual(ContentKind.markdown, kindForPath("/a/README.md"));
    try std.testing.expectEqual(ContentKind.external, kindForPath("/a/spec.pdf"));
    try std.testing.expectEqual(ContentKind.external, kindForPath("/a/icon.svg"));
    try std.testing.expectEqual(ContentKind.text, kindForPath("/a/main.zig"));
    try std.testing.expectEqual(ContentKind.text, kindForPath("/a/.gitignore"));
    try std.testing.expectEqualStrings("image/jpeg", mimeForPath("x.jpg").?);
    try std.testing.expect(mimeForPath("x.zig") == null);
}

test "relative paths normalise and reject escapes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("", (try normalizeRelative(a, "")).?);
    try std.testing.expectEqualStrings("", (try normalizeRelative(a, "./")).?);
    try std.testing.expectEqualStrings("src/main.zig", (try normalizeRelative(a, "./src//main.zig/")).?);
    try std.testing.expect((try normalizeRelative(a, "/etc/passwd")) == null);
    try std.testing.expect((try normalizeRelative(a, "src/../../x")) == null);
    try std.testing.expect((try normalizeRelative(a, "a\\b")) == null);
    try std.testing.expect((try normalizeRelative(a, "a\x00b")) == null);
}

test "utf8 prefix never splits a codepoint" {
    try std.testing.expectEqualStrings("ab", utf8Prefix("ab"));
    try std.testing.expectEqualStrings("a", utf8Prefix("a\xc3"));
    try std.testing.expectEqualStrings("a\xc3\xa9", utf8Prefix("a\xc3\xa9"));
    try std.testing.expectEqualStrings("a", utf8Prefix("a\xe2\x82"));
    try std.testing.expect(looksTextual("hello"));
    try std.testing.expect(!looksTextual("he\x00llo"));
}
