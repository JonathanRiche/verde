//! Workspace explorer: the read-only file tree and preview
//! (`workspace.files.list`, `workspace.files.read`) and the workspace-wide
//! Changes view (`git.changes.workspace`, `git.changes.file_patch`).
//!
//! Files are addressed as (root id, root-relative path): `home` is the
//! workspace home, other roots are verde.toml folder names, and "" is the
//! root itself. Absolute host paths (`Root.path`) are informational and are
//! never sent. Directories load lazily, one request per expanded folder.
//! Changes refresh only for the watched workspace, on open, chat-turn changes
//! and foreground; nothing is polled. The file preview and the patch keep only
//! the newest request, and `workspace_preview_close` drops their bodies.
const std = @import("std");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const m = @import("git_models.zig");
const clone = @import("state_clone.zig");
const add = @import("chat_catalogs.zig").append;
const A = std.mem.Allocator;
const V = std.json.Value;
const E = h.ApiError;
const eq = h.eq;

/// Workspaces with a cached tree or changes list; the oldest is evicted.
pub const MAX_WORKSPACES = 8;
/// Loaded directories per workspace.
pub const MAX_DIRS = 512;
/// Matches the daemon's `MAX_LIST_ENTRIES`.
pub const MAX_ENTRIES = 5000;
pub const MAX_PATH_BYTES = 4096;
pub const MAX_ROOT_ID_BYTES = 256;
/// Enough unchanged context to show a whole file around its changes.
pub const MAX_CONTEXT_LINES: u32 = 1_000_000;
/// Paired clients have a 1 MiB transport cap: leave room for JSON escaping
/// and base64's 4/3 growth.
pub const READ_TEXT_BYTES: u64 = 512 * 1024;
pub const READ_IMAGE_BYTES: u64 = 600 * 1024;
pub const HOME_ROOT_ID = "home";

pub const Root = struct {
    /// Opaque: `home`, or the verde.toml folder name. Sent back as `root`.
    id: []const u8,
    /// Display name (folder name, or the home directory's basename).
    name: []const u8,
    /// Absolute path on the host; informational (agent prompts), never sent.
    path: []const u8 = "",
    /// The workspace home; other roots prefix display paths with `name`.
    home: bool = false,
};

pub const Entry = struct {
    name: []const u8,
    /// Root-relative.
    path: []const u8,
    /// `directory` or `file`.
    kind: []const u8,
    size: u64 = 0,
    /// Gitignored and untracked: shown dimmed.
    ignored: bool = false,
    symlink: bool = false,
};

pub const Dir = struct {
    root: []const u8,
    /// Root-relative; "" is the root itself.
    path: []const u8,
    entries: []const Entry = &.{},
    /// More children exist than were returned.
    truncated: bool = false,
    loading: bool = false,
    loaded: bool = false,
    @"error": ?h.LocalError = null,
};

/// `workspace_files:<workspace_id>`.
pub const FilesView = struct {
    workspace_id: []const u8,
    supported: bool = true,
    loading: bool = false,
    loaded: bool = false,
    roots: []const Root = &.{},
    /// Every directory requested so far; expansion state belongs to the UI.
    dirs: []const Dir = &.{},
    @"error": ?h.LocalError = null,
};

/// `workspace_changes:<workspace_id>`.
pub const ChangesView = struct {
    workspace_id: []const u8,
    supported: bool = true,
    loading: bool = false,
    loaded: bool = false,
    /// Claims revision; unchanged revision and repos mean unchanged data.
    revision: u64 = 0,
    repos: []const m.WorkspaceRepo = &.{},
    @"error": ?h.LocalError = null,
};

/// `workspace.files.read` result: `text`/`markdown` carry UTF-8 `content`,
/// `image` base64 `content`; `binary`, `external` and `too_large` none.
pub const ReadResult = struct {
    root: []const u8,
    path: []const u8,
    name: []const u8 = "",
    size: u64 = 0,
    kind: []const u8,
    mime: ?[]const u8 = null,
    /// `none`, `utf8` or `base64`.
    encoding: []const u8 = "none",
    content: []const u8 = "",
    truncated: bool = false,
};

/// `workspace_file`: the latest requested file preview only.
pub const FileView = struct {
    workspace_id: []const u8 = "",
    root: []const u8 = "",
    path: []const u8 = "",
    supported: bool = true,
    loading: bool = false,
    result: ?ReadResult = null,
    @"error": ?h.LocalError = null,
};

/// `workspace_patch`: the latest requested file patch only.
pub const PatchView = struct {
    workspace_id: []const u8 = "",
    root: []const u8 = "",
    path: []const u8 = "",
    context_lines: ?u32 = null,
    supported: bool = true,
    loading: bool = false,
    result: ?m.FilePatchResult = null,
    @"error": ?h.LocalError = null,
};

const Kind = enum { roots, dir, read, changes, patch };
const Request = struct { id: u64, kind: Kind, intent_id: []const u8, workspace_id: []const u8, root: []const u8 = "", path: []const u8 = "" };
const Changes = struct { view: ChangesView, dirty: bool = false, in_flight: bool = false };

pub const State = struct {
    files: []const FilesView = &.{},
    changes: []const Changes = &.{},
    patch: PatchView = .{},
    patch_id: ?u64 = null,
    file: FileView = .{},
    file_id: ?u64 = null,
    /// The workspace whose Changes view is on screen.
    watched: []const u8 = "",
    requests: []const Request = &.{},
};

const tags = [_][]const u8{ "workspace_files_list", "workspace_file_read", "workspace_preview_close", "workspace_changes_open", "workspace_changes_close", "workspace_file_patch" };

pub fn owns(tag: []const u8) bool {
    for (tags) |t| if (eq(t, tag)) return true;
    return false;
}

pub fn receiptFields(tag: []const u8) ?[]const u8 {
    if (eq(tag, "workspace_files_list") or eq(tag, "workspace_file_read")) return "workspace_id root path";
    if (eq(tag, "workspace_changes_open") or eq(tag, "workspace_changes_close") or eq(tag, "workspace_preview_close")) return "workspace_id";
    if (eq(tag, "workspace_file_patch")) return "workspace_id root path context_lines";
    return null;
}

const ListIntent = struct { root: ?[]const u8 = null, path: ?[]const u8 = null };
const ReadIntent = struct { root: []const u8, path: []const u8 };

pub fn validate(a: A, tag: []const u8, v: V) E!void {
    const ws = try h.string(v, "workspace_id");
    if (ws.len == 0 or ws.len > 256) return error.InvalidArgument;
    if (eq(tag, "workspace_files_list")) {
        _ = try h.decode(ListIntent, a, v);
    } else if (eq(tag, "workspace_file_read")) {
        _ = try h.decode(ReadIntent, a, v);
    } else if (eq(tag, "workspace_file_patch")) {
        _ = try h.decode(m.FilePatchRequest, a, v);
    }
}

pub fn intent(tx: *h.Transaction, tag: []const u8, v: V) E!void {
    if (!owns(tag)) return;
    const a = tx.allocator();
    const id = try h.string(v, "intent_id");
    const ws = try h.string(v, "workspace_id");
    const s = &tx.state.explorer;
    if (eq(tag, "workspace_changes_close")) {
        if (eq(s.watched, ws)) s.watched = "";
        return receipt(tx, id, "succeeded", null);
    }
    if (eq(tag, "workspace_preview_close")) {
        // Drops (possibly large) bodies; a response still in flight is ignored.
        if (eq(s.file.workspace_id, ws)) {
            s.file = .{ .supported = s.file.supported };
            s.file_id = null;
        }
        if (eq(s.patch.workspace_id, ws)) {
            s.patch = .{ .supported = s.patch.supported };
            s.patch_id = null;
        }
        return receipt(tx, id, "succeeded", null);
    }
    if (!scoped(&tx.state, "repository:read")) return receipt(tx, id, "failed", failure("scope_denied", "This device can't browse workspace files."));
    if (!online(&tx.state)) return receipt(tx, id, "failed", failure("offline", "Connect to the host to browse this workspace."));
    if (eq(tag, "workspace_files_list")) {
        const r = try h.decode(ListIntent, a, v);
        const path = std.mem.trimEnd(u8, r.path orelse "", "/");
        if (r.root) |root| if (!validRoot(root) or !relative(path)) return receipt(tx, id, "failed", failure("invalid_path", "This folder can't be opened."));
        const f = try filesFor(tx, ws);
        if (!f.supported) return receipt(tx, id, "failed", failure("unsupported", "Update Verde on the computer to browse files."));
        const root = r.root orelse {
            if (f.loading) return receipt(tx, id, "succeeded", null);
            f.loading = true;
            return track(tx, .roots, id, ws, "", "", try rpc.request(tx, "workspace.files.list", .{ .workspace_id = ws }, read));
        };
        const d = try dirFor(tx, f, root, path) orelse return receipt(tx, id, "failed", failure("resource_limit", "Collapse some folders first."));
        if (d.loading) return receipt(tx, id, "succeeded", null);
        d.loading = true;
        return track(tx, .dir, id, ws, d.root, d.path, try rpc.request(tx, "workspace.files.list", .{ .workspace_id = ws, .root = d.root, .path = d.path }, read));
    }
    if (eq(tag, "workspace_file_read")) {
        const r = try h.decode(ReadIntent, a, v);
        if (!validRoot(r.root) or r.path.len == 0 or !relative(r.path)) return receipt(tx, id, "failed", failure("invalid_path", "This file can't be opened."));
        if (!s.file.supported) return receipt(tx, id, "failed", failure("unsupported", "Update Verde on the computer to preview files."));
        // A newer preview replaces the one on screen; the older response is dropped.
        s.file = .{ .workspace_id = try a.dupe(u8, ws), .root = r.root, .path = r.path, .loading = true };
        s.file_id = try rpc.request(tx, "workspace.files.read", .{ .workspace_id = ws, .root = r.root, .path = r.path, .max_bytes = READ_TEXT_BYTES, .max_image_bytes = READ_IMAGE_BYTES }, read);
        return track(tx, .read, id, ws, r.root, r.path, s.file_id.?);
    }
    if (eq(tag, "workspace_changes_open")) {
        s.watched = try a.dupe(u8, ws);
        const c = try changesFor(tx, ws);
        if (!c.view.supported) return receipt(tx, id, "failed", failure("unsupported", "Update Verde on the computer to see workspace changes."));
        if (c.in_flight) {
            // Coalesce: one trailing refresh after the read in flight.
            c.dirty = true;
            return receipt(tx, id, "succeeded", null);
        }
        return requestChanges(tx, c, id);
    }
    // workspace_file_patch
    const r = try h.decode(m.FilePatchRequest, a, v);
    if (!opaqueRoot(r.root) or r.path.len == 0 or !relative(r.path))
        return receipt(tx, id, "failed", failure("invalid_path", "This file can't be shown."));
    if (!s.patch.supported) return receipt(tx, id, "failed", failure("unsupported", "Update Verde on the computer to see diffs."));
    const context: ?u32 = if (r.context_lines) |n| @min(n, MAX_CONTEXT_LINES) else null;
    // A newer patch replaces the one on screen; the older response is dropped.
    s.patch = .{ .workspace_id = r.workspace_id, .root = r.root, .path = r.path, .context_lines = context, .loading = true };
    s.patch_id = try rpc.request(tx, "git.changes.file_patch", m.FilePatchRequest{ .workspace_id = r.workspace_id, .root = r.root, .path = r.path, .context_lines = context }, read);
    try track(tx, .patch, id, r.workspace_id, "", "", s.patch_id.?);
}

/// Drains `@explore` RPC outcomes, then sends the watched workspace's
/// trailing refresh when one is due.
pub fn pump(tx: *h.Transaction) E!void {
    const s = &tx.state.explorer;
    const a = tx.allocator();
    const count = tx.state.rpc.results.len;
    for (0..count) |_| {
        const result = rpc.takeResult(tx).?;
        if (result.intent_id == null or !eq(result.intent_id.?, "@explore")) {
            try add(rpc.Result, a, &tx.state.rpc.results, result);
            continue;
        }
        var request: ?Request = null;
        for (s.requests, 0..) |r, i| if (r.id == result.id) {
            request = r;
            const next = try a.alloc(Request, s.requests.len - 1);
            @memcpy(next[0..i], s.requests[0..i]);
            @memcpy(next[i..], s.requests[i + 1 ..]);
            s.requests = next;
            break;
        };
        const r = request orelse continue;
        tx.changed = true;
        switch (r.kind) {
            .roots => try listedRoots(tx, r, result),
            .dir => try listedDir(tx, r, result),
            .read => try readFile(tx, r, result),
            .changes => try changed(tx, r, result),
            .patch => try patched(tx, r, result),
        }
    }
    if (s.watched.len == 0 or !online(&tx.state) or !scoped(&tx.state, "repository:read")) return;
    for (@constCast(s.changes)) |*c| if (eq(c.view.workspace_id, s.watched) and c.dirty and !c.in_flight and c.view.supported) {
        try requestChanges(tx, c, "");
    };
}

/// Chat turns are what edit files: refresh the watched Changes list.
pub fn turnChanged(tx: *h.Transaction) void {
    const s = &tx.state.explorer;
    for (@constCast(s.changes)) |*c| if (eq(c.view.workspace_id, s.watched)) {
        c.dirty = true;
    };
}

pub fn observe(tx: *h.Transaction, event: V) E!void {
    const s = &tx.state.explorer;
    if (tx.state.auth.credential == null) {
        if (s.files.len > 0 or s.changes.len > 0 or s.patch.path.len > 0 or s.file.path.len > 0 or s.watched.len > 0) {
            tx.state.explorer = .{};
            tx.changed = true;
        }
        return;
    }
    if (eq(p.s(event, "type"), "foreground")) turnChanged(tx);
}

pub fn query(a: A, s: *const h.State, selector: []const u8) E!?V {
    const e = &s.explorer;
    if (std.mem.startsWith(u8, selector, "workspace_files:")) {
        const ws = selector["workspace_files:".len..];
        for (e.files) |f| if (eq(f.workspace_id, ws)) return try h.parse(a, try h.encode(a, f));
        return try h.parse(a, try h.encode(a, FilesView{ .workspace_id = ws }));
    }
    if (std.mem.startsWith(u8, selector, "workspace_changes:")) {
        const ws = selector["workspace_changes:".len..];
        for (e.changes) |c| if (eq(c.view.workspace_id, ws)) return try h.parse(a, try h.encode(a, c.view));
        return try h.parse(a, try h.encode(a, ChangesView{ .workspace_id = ws }));
    }
    if (eq(selector, "workspace_patch")) return try h.parse(a, try h.encode(a, e.patch));
    if (eq(selector, "workspace_file")) return try h.parse(a, try h.encode(a, e.file));
    return null;
}

pub fn scopes(a: A, before: *const h.State, after: *const h.State) E![]const []const u8 {
    var out: []const []const u8 = &.{};
    const b = &before.explorer;
    const n = &after.explorer;
    if (!clone.equal(PatchView, b.patch, n.patch)) try add([]const u8, a, &out, "workspace_patch");
    if (!clone.equal(FileView, b.file, n.file)) try add([]const u8, a, &out, "workspace_file");
    for (n.files) |f| {
        var same = false;
        for (b.files) |old| if (eq(old.workspace_id, f.workspace_id)) {
            same = clone.equal(FilesView, old, f);
        };
        if (!same) try add([]const u8, a, &out, try std.fmt.allocPrint(a, "workspace_files:{s}", .{f.workspace_id}));
    }
    for (b.files) |old| if (!hasFiles(n, old.workspace_id)) try add([]const u8, a, &out, try std.fmt.allocPrint(a, "workspace_files:{s}", .{old.workspace_id}));
    for (n.changes) |c| {
        var same = false;
        for (b.changes) |old| if (eq(old.view.workspace_id, c.view.workspace_id)) {
            same = clone.equal(ChangesView, old.view, c.view);
        };
        if (!same) try add([]const u8, a, &out, try std.fmt.allocPrint(a, "workspace_changes:{s}", .{c.view.workspace_id}));
    }
    for (b.changes) |old| if (!hasChanges(n, old.view.workspace_id)) try add([]const u8, a, &out, try std.fmt.allocPrint(a, "workspace_changes:{s}", .{old.view.workspace_id}));
    return out;
}

fn hasFiles(s: *const State, ws: []const u8) bool {
    for (s.files) |f| if (eq(f.workspace_id, ws)) return true;
    return false;
}
fn hasChanges(s: *const State, ws: []const u8) bool {
    for (s.changes) |c| if (eq(c.view.workspace_id, ws)) return true;
    return false;
}

const read: rpc.Options = .{ .mutation = false, .intent_id = "@explore" };

fn track(tx: *h.Transaction, kind: Kind, intent_id: []const u8, ws: []const u8, root: []const u8, path: []const u8, id: u64) E!void {
    try add(Request, tx.allocator(), &tx.state.explorer.requests, .{ .id = id, .kind = kind, .intent_id = intent_id, .workspace_id = ws, .root = root, .path = path });
    if (intent_id.len > 0) receipt(tx, intent_id, "pending", null);
}

fn requestChanges(tx: *h.Transaction, c: *Changes, intent_id: []const u8) E!void {
    c.dirty = false;
    c.in_flight = true;
    c.view.loading = true;
    try track(tx, .changes, intent_id, c.view.workspace_id, "", "", try rpc.request(tx, "git.changes.workspace", m.WorkspaceRequest{ .workspace_id = c.view.workspace_id }, read));
}

fn listedRoots(tx: *h.Transaction, r: Request, result: rpc.Result) E!void {
    const f = findFiles(tx, r.workspace_id) orelse return receipt(tx, r.intent_id, "failed", failure("superseded", "This workspace was closed."));
    f.loading = false;
    if (result.@"error") |e| {
        f.@"error" = named(e);
        if (eq(f.@"error".?.code, "method_not_found")) f.supported = false;
        return receipt(tx, r.intent_id, "failed", f.@"error");
    }
    const Wire = struct { roots: []const struct { id: []const u8, name: []const u8 = "", path: []const u8 = "" } = &.{} };
    const data = h.decode(Wire, tx.allocator(), result.value orelse .null) catch |err| {
        if (err == error.OutOfMemory) return err;
        f.@"error" = failure("invalid_response", "Could not read the workspace folders.");
        return receipt(tx, r.intent_id, "failed", f.@"error");
    };
    var roots: []const Root = &.{};
    for (data.roots) |root| {
        if (!validRoot(root.id) or roots.len >= 64) continue;
        // The path only feeds agent prompts; drop one that isn't absolute.
        const path = if (validPath(root.path)) root.path else "";
        const name = if (root.name.len > 0) root.name else root.id;
        try add(Root, tx.allocator(), &roots, .{ .id = root.id, .name = name, .path = path, .home = eq(root.id, HOME_ROOT_ID) });
    }
    f.roots = roots;
    f.loaded = true;
    f.@"error" = null;
    receipt(tx, r.intent_id, "succeeded", null);
}

fn listedDir(tx: *h.Transaction, r: Request, result: rpc.Result) E!void {
    const f = findFiles(tx, r.workspace_id) orelse return receipt(tx, r.intent_id, "failed", failure("superseded", "This workspace was closed."));
    var dir: ?*Dir = null;
    for (@constCast(f.dirs)) |*d| if (eq(d.root, r.root) and eq(d.path, r.path)) {
        dir = d;
    };
    const d = dir orelse return receipt(tx, r.intent_id, "failed", failure("superseded", "This folder was closed."));
    d.loading = false;
    if (result.@"error") |e| {
        d.@"error" = named(e);
        if (eq(d.@"error".?.code, "method_not_found")) f.supported = false;
        return receipt(tx, r.intent_id, "failed", d.@"error");
    }
    const Wire = struct { entries: []const Entry = &.{}, truncated: bool = false };
    const data = h.decode(Wire, tx.allocator(), result.value orelse .null) catch |err| {
        if (err == error.OutOfMemory) return err;
        d.@"error" = failure("invalid_response", "Could not read this folder.");
        return receipt(tx, r.intent_id, "failed", d.@"error");
    };
    var entries: std.ArrayList(Entry) = .empty;
    for (data.entries) |entry| {
        if (entries.items.len >= MAX_ENTRIES) break;
        if (entry.name.len == 0 or entry.path.len == 0 or !relative(entry.path) or !(eq(entry.kind, "directory") or eq(entry.kind, "file"))) continue;
        // Defence in depth: the daemon never lists `.git`.
        if (eq(entry.name, ".git")) continue;
        try entries.append(tx.allocator(), entry);
    }
    d.entries = entries.items;
    d.truncated = data.truncated or data.entries.len > MAX_ENTRIES;
    d.loaded = true;
    d.@"error" = null;
    receipt(tx, r.intent_id, "succeeded", null);
}

fn readFile(tx: *h.Transaction, r: Request, result: rpc.Result) E!void {
    const s = &tx.state.explorer;
    if (s.file_id == null or s.file_id.? != r.id) return receipt(tx, r.intent_id, "failed", failure("superseded", "A newer preview replaced this one."));
    s.file_id = null;
    s.file.loading = false;
    if (result.@"error") |e| {
        s.file.@"error" = named(e);
        if (eq(s.file.@"error".?.code, "method_not_found")) s.file.supported = false;
        return receipt(tx, r.intent_id, "failed", s.file.@"error");
    }
    const data = h.decode(ReadResult, tx.allocator(), result.value orelse .null) catch |err| {
        if (err == error.OutOfMemory) return err;
        s.file.@"error" = failure("invalid_response", "Could not read this file.");
        return receipt(tx, r.intent_id, "failed", s.file.@"error");
    };
    const known = for ([_][]const u8{ "text", "markdown", "image", "binary", "external", "too_large" }) |k| {
        if (eq(k, data.kind)) break true;
    } else false;
    if (!eq(data.root, s.file.root) or !eq(data.path, s.file.path) or !known) {
        s.file.@"error" = failure("invalid_response", "Could not read this file.");
        return receipt(tx, r.intent_id, "failed", s.file.@"error");
    }
    s.file.result = data;
    s.file.@"error" = null;
    receipt(tx, r.intent_id, "succeeded", null);
}

fn changed(tx: *h.Transaction, r: Request, result: rpc.Result) E!void {
    var found: ?*Changes = null;
    for (@constCast(tx.state.explorer.changes)) |*c| if (eq(c.view.workspace_id, r.workspace_id)) {
        found = c;
    };
    const c = found orelse return receipt(tx, r.intent_id, "failed", failure("superseded", "This workspace was closed."));
    c.in_flight = false;
    c.view.loading = false;
    if (result.@"error") |e| {
        c.view.@"error" = named(e);
        if (eq(c.view.@"error".?.code, "method_not_found")) c.view.supported = false;
        // A cancelled read (background, network change) refreshes on reconnect.
        if (eq(e.code, "cancelled")) c.dirty = true;
        return receipt(tx, r.intent_id, "failed", c.view.@"error");
    }
    const data = h.decode(m.WorkspaceResult, tx.allocator(), result.value orelse .null) catch |err| {
        if (err == error.OutOfMemory) return err;
        c.view.@"error" = failure("invalid_response", "Could not read changes.");
        return receipt(tx, r.intent_id, "failed", c.view.@"error");
    };
    if (!eq(data.workspace_id, r.workspace_id)) {
        c.view.@"error" = failure("invalid_response", "Could not read changes.");
        return receipt(tx, r.intent_id, "failed", c.view.@"error");
    }
    c.view.repos = data.repos;
    c.view.revision = data.revision;
    c.view.loaded = true;
    c.view.@"error" = null;
    receipt(tx, r.intent_id, "succeeded", null);
}

fn patched(tx: *h.Transaction, r: Request, result: rpc.Result) E!void {
    const s = &tx.state.explorer;
    if (s.patch_id == null or s.patch_id.? != r.id) return receipt(tx, r.intent_id, "failed", failure("superseded", "A newer diff replaced this one."));
    s.patch_id = null;
    s.patch.loading = false;
    if (result.@"error") |e| {
        s.patch.@"error" = named(e);
        if (eq(s.patch.@"error".?.code, "method_not_found")) s.patch.supported = false;
        return receipt(tx, r.intent_id, "failed", s.patch.@"error");
    }
    const data = h.decode(m.FilePatchResult, tx.allocator(), result.value orelse .null) catch |err| {
        if (err == error.OutOfMemory) return err;
        s.patch.@"error" = failure("invalid_response", "Could not read this diff.");
        return receipt(tx, r.intent_id, "failed", s.patch.@"error");
    };
    if (!eq(data.root, s.patch.root) or !eq(data.path, s.patch.path)) {
        s.patch.@"error" = failure("invalid_response", "Could not read this diff.");
        return receipt(tx, r.intent_id, "failed", s.patch.@"error");
    }
    s.patch.result = data;
    s.patch.@"error" = null;
    receipt(tx, r.intent_id, "succeeded", null);
}

fn findFiles(tx: *h.Transaction, ws: []const u8) ?*FilesView {
    for (@constCast(tx.state.explorer.files)) |*f| if (eq(f.workspace_id, ws)) return f;
    return null;
}

fn filesFor(tx: *h.Transaction, ws: []const u8) E!*FilesView {
    if (findFiles(tx, ws)) |f| return f;
    const s = &tx.state.explorer;
    const keep = if (s.files.len >= MAX_WORKSPACES) s.files[1..] else s.files;
    const next = try tx.allocator().alloc(FilesView, keep.len + 1);
    @memcpy(next[0..keep.len], keep);
    next[keep.len] = .{ .workspace_id = try tx.allocator().dupe(u8, ws) };
    s.files = next;
    return &next[keep.len];
}

fn dirFor(tx: *h.Transaction, f: *FilesView, root: []const u8, path: []const u8) E!?*Dir {
    for (@constCast(f.dirs)) |*d| if (eq(d.root, root) and eq(d.path, path)) return d;
    if (f.dirs.len >= MAX_DIRS) return null;
    const next = try tx.allocator().alloc(Dir, f.dirs.len + 1);
    @memcpy(next[0..f.dirs.len], f.dirs);
    next[f.dirs.len] = .{ .root = try tx.allocator().dupe(u8, root), .path = try tx.allocator().dupe(u8, path) };
    f.dirs = next;
    return &next[f.dirs.len - 1];
}

fn changesFor(tx: *h.Transaction, ws: []const u8) E!*Changes {
    const s = &tx.state.explorer;
    for (@constCast(s.changes)) |*c| if (eq(c.view.workspace_id, ws)) return c;
    const keep = if (s.changes.len >= MAX_WORKSPACES) s.changes[1..] else s.changes;
    const next = try tx.allocator().alloc(Changes, keep.len + 1);
    @memcpy(next[0..keep.len], keep);
    next[keep.len] = .{ .view = .{ .workspace_id = try tx.allocator().dupe(u8, ws) } };
    s.changes = next;
    return &next[keep.len];
}

fn scoped(s: *const h.State, name: []const u8) bool {
    const credential = s.auth.credential orelse return false;
    for (credential.scopes) |scope| if (eq(scope, name)) return true;
    return false;
}

fn online(s: *const h.State) bool {
    return s.lifecycle == .foreground and s.network_available and s.rpc.phase == .ready and s.rpc.bearer != null;
}

/// `WorkspaceRepo.root`: opaque, echoed back verbatim.
fn opaqueRoot(root: []const u8) bool {
    if (root.len == 0 or root.len > MAX_PATH_BYTES or !std.unicode.utf8ValidateSlice(root)) return false;
    for (root) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// Absolute host path (informational root paths).
fn validPath(path: []const u8) bool {
    if (path.len < 1 or path.len > MAX_PATH_BYTES or path[0] != '/') return false;
    return clean(path);
}

/// Root-relative: not absolute, no backslash, controls or `..` component
/// ("" is the root itself). The daemon re-confines every path.
fn relative(path: []const u8) bool {
    if (path.len > MAX_PATH_BYTES or (path.len > 0 and path[0] == '/')) return false;
    return clean(path);
}

fn clean(path: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(path)) return false;
    for (path) |c| if (c < 0x20 or c == 0x7f or c == '\\') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (eq(part, "..")) return false;
    return true;
}

/// Opaque root id: `home` or a folder name; never a path.
fn validRoot(id: []const u8) bool {
    if (id.len == 0 or id.len > MAX_ROOT_ID_BYTES or !std.unicode.utf8ValidateSlice(id)) return false;
    for (id) |c| if (c < 0x20 or c == 0x7f or c == '/' or c == '\\') return false;
    return !eq(id, ".") and !eq(id, "..");
}

fn failure(code: []const u8, message: []const u8) h.LocalError {
    return .{ .domain = "explorer", .code = code, .message = message };
}

/// Daemon codes the UI acts on become the local code; everything else keeps
/// a readable message without raw host text.
fn named(e: h.LocalError) h.LocalError {
    const code = e.rpc_code orelse e.code;
    const message = if (eq(code, "method_not_found"))
        "Update Verde on the computer to use this."
    else if (eq(code, "path_outside_roots"))
        "This path is outside the workspace folders."
    else if (eq(code, "not_found"))
        "This no longer exists on the host."
    else if (eq(code, "not_directory"))
        "This is not a folder."
    else if (eq(code, "not_file"))
        "This is not a file."
    else if (eq(code, "root_not_found"))
        "This folder is no longer part of the workspace."
    else if (eq(code, "invalid_params"))
        "This path can't be opened."
    else if (eq(code, "resource_not_found"))
        "This workspace is no longer on the host."
    else if (eq(code, "cancelled") or eq(code, "offline"))
        "Connect to the host to refresh."
    else
        "The host couldn't read this workspace.";
    return .{ .domain = "explorer", .code = code, .message = message, .retryable = e.retryable };
}

fn receipt(tx: *h.Transaction, id: []const u8, state: []const u8, err: ?h.LocalError) void {
    if (id.len == 0) return;
    for (@constCast(tx.state.receipts)) |*r| if (eq(r.operation.intent_id, id)) {
        r.operation.state = state;
        r.operation.@"error" = err;
    };
    tx.changed = true;
}
