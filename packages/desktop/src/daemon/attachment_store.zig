//! Durable chat-image store and message-scoped image reads.
//!
//! Staged uploads live in a scratch directory the daemon wipes on start, so
//! claimed images are copied here (owner-only) when a turn accepts them. Detached
//! clients (phones, web) then fetch an image only by naming the message that
//! carries it: `chat.attachment.read` never accepts a path, and resolves the
//! file from that message's own durable row — a `verde-attachment:<id>` token
//! maps into this store; a desktop-local absolute path is served as-is only
//! because the row already references it.

const std = @import("std");
const builtin = @import("builtin");
const zqlite = @import("zqlite");

const log = std.log.scoped(.attachment_store);

pub const METHOD_READ = "chat.attachment.read";
pub const DIR_NAME = "attachment-store";
pub const REFERENCE_PREFIX = "verde-attachment:";
/// Largest chunk returned per read (raw bytes, before base64).
pub const MAX_CHUNK_BYTES: usize = 512 * 1024;
pub const MAX_IMAGE_BYTES: usize = 16 * 1024 * 1024;
/// Images older than this are pruned at daemon start.
pub const RETENTION_MS: i64 = 90 * 24 * 60 * 60 * 1000;

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}

pub fn storePathAlloc(allocator: std.mem.Allocator, pref_path: []const u8, id: []const u8) ![]u8 {
    if (!validId(id)) return error.InvalidParams;
    return std.fs.path.join(allocator, &.{ pref_path, DIR_NAME, id });
}

/// Copies a claimed staged image into the durable store. Best effort: a
/// failed copy only means that image has no preview later.
pub fn persistClaimed(allocator: std.mem.Allocator, pref_path: []const u8, id: []const u8, staged_path: []const u8) void {
    if (pref_path.len == 0 or !validId(id)) return;
    persistClaimedOrError(allocator, pref_path, id, staged_path) catch |err| {
        log.warn("could not keep chat image {s}: {s}", .{ id, @errorName(err) });
    };
}

fn persistClaimedOrError(allocator: std.mem.Allocator, pref_path: []const u8, id: []const u8, staged_path: []const u8) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    const dir_path = try std.fs.path.join(allocator, &.{ pref_path, DIR_NAME });
    defer allocator.free(dir_path);
    var dir = try cwd.createDirPathOpen(io, dir_path, .{});
    dir.close(io);
    const target = try storePathAlloc(allocator, pref_path, id);
    defer allocator.free(target);
    const bytes = try cwd.readFileAlloc(io, staged_path, allocator, .limited(MAX_IMAGE_BYTES));
    defer allocator.free(bytes);
    var file = try cwd.createFile(io, target, .{ .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600) });
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

/// Deletes stored images older than the retention window.
pub fn prune(allocator: std.mem.Allocator, pref_path: []const u8, now_ms: i64) void {
    if (pref_path.len == 0) return;
    const dir_path = std.fs.path.join(allocator, &.{ pref_path, DIR_NAME }) catch return;
    defer allocator.free(dir_path);
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
        const modified_ms: i64 = @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_ms));
        if (now_ms - modified_ms > RETENTION_MS) dir.deleteFile(io, entry.name) catch {};
    }
}

pub const Resolved = struct {
    path: []u8,
    mime: []u8,
};

const ExtraImage = struct { path: []const u8 = "", mime: []const u8 = "", byte_size: usize = 0, attachment_id: ?[]const u8 = null };

/// Finds image `index` of a message in a thread and maps it to a readable
/// file. Null when the message, image, or stored bytes do not exist.
pub fn resolveForMessage(
    conn: zqlite.Conn,
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    message_id: []const u8,
    index: usize,
) !?Resolved {
    var row = (try conn.row(
        "select m.image_path, m.image_mime, m.extra_images_json from messages m join threads t on t.id = m.thread_id join workspaces w on w.id = t.workspace_id where w.workspace_id = ?1 and t.local_thread_id = ?2 and m.message_id = ?3",
        .{ workspace_id, local_thread_id, message_id },
    )) orelse return null;
    defer row.deinit();

    var path: ?[]const u8 = null;
    var mime: []const u8 = "";
    var position: usize = 0;
    if (row.nullableText(0)) |first| {
        if (first.len > 0) {
            if (index == 0) {
                path = first;
                mime = row.nullableText(1) orelse "";
            }
            position = 1;
        }
    }
    var parsed: ?std.json.Parsed([]ExtraImage) = null;
    defer if (parsed) |*value| value.deinit();
    if (path == null) {
        if (row.nullableText(2)) |raw| if (raw.len > 0) {
            parsed = std.json.parseFromSlice([]ExtraImage, allocator, raw, .{ .ignore_unknown_fields = true }) catch null;
            if (parsed) |value| {
                if (index >= position and index - position < value.value.len) {
                    const extra = value.value[index - position];
                    path = extra.path;
                    mime = extra.mime;
                }
            }
        };
    }
    const reference = path orelse return null;
    if (mime.len > 0 and !std.mem.startsWith(u8, mime, "image/")) return null;
    const file_path = if (std.mem.startsWith(u8, reference, REFERENCE_PREFIX))
        storePathAlloc(allocator, pref_path, reference[REFERENCE_PREFIX.len..]) catch return null
    else if (std.fs.path.isAbsolute(reference))
        try allocator.dupe(u8, reference)
    else
        return null;
    errdefer allocator.free(file_path);
    return .{ .path = file_path, .mime = try allocator.dupe(u8, if (mime.len > 0) mime else "image/png") };
}

pub const Chunk = struct {
    total: usize,
    data: []u8,
};

/// Reads up to `length` bytes at `offset` (bounded by MAX_CHUNK_BYTES).
pub fn readChunk(allocator: std.mem.Allocator, path: []const u8, offset: usize, length: usize) !Chunk {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const total: usize = @intCast(stat.size);
    if (total > MAX_IMAGE_BYTES) return error.FileTooBig;
    if (offset > total) return error.InvalidParams;
    const want = @min(@min(length, MAX_CHUNK_BYTES), total - offset);
    const data = try allocator.alloc(u8, want);
    errdefer allocator.free(data);
    var reader_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    try reader.seekTo(offset);
    try reader.interface.readSliceAll(data);
    return .{ .total = total, .data = data };
}

test "message images resolve only through their own message row" {
    const allocator = std.testing.allocator;
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    try conn.execNoArgs("create table workspaces (id integer primary key, workspace_id text)");
    try conn.execNoArgs("create table threads (id integer primary key, workspace_id integer, local_thread_id text)");
    try conn.execNoArgs("create table messages (id integer primary key, thread_id integer, message_id text, image_path text, image_mime text, extra_images_json text)");
    try conn.execNoArgs("insert into workspaces values (1,'ws')");
    try conn.execNoArgs("insert into threads values (1,1,'chat-1')");
    try conn.execNoArgs(
        \\insert into messages values (1,1,'m1','verde-attachment:abc123','image/jpeg','[{"path":"/home/me/pic.png","mime":"image/png","byte_size":4}]'),
        \\ (2,1,'m2',null,null,'[{"path":"relative.png","mime":"image/png"},{"path":"/etc/passwd","mime":"text/plain"}]')
    );
    const first = (try resolveForMessage(conn, allocator, "/pref", "ws", "chat-1", "m1", 0)).?;
    defer allocator.free(first.path);
    defer allocator.free(first.mime);
    try std.testing.expectEqualStrings("/pref/attachment-store/abc123", first.path);
    try std.testing.expectEqualStrings("image/jpeg", first.mime);
    const second = (try resolveForMessage(conn, allocator, "/pref", "ws", "chat-1", "m1", 1)).?;
    defer allocator.free(second.path);
    defer allocator.free(second.mime);
    try std.testing.expectEqualStrings("/home/me/pic.png", second.path);
    try std.testing.expect((try resolveForMessage(conn, allocator, "/pref", "ws", "chat-1", "m1", 2)) == null);
    try std.testing.expect((try resolveForMessage(conn, allocator, "/pref", "ws", "chat-1", "m2", 0)) == null); // relative path
    try std.testing.expect((try resolveForMessage(conn, allocator, "/pref", "ws", "chat-1", "m2", 1)) == null); // not an image
    try std.testing.expect((try resolveForMessage(conn, allocator, "/pref", "ws", "other", "m1", 0)) == null);
    try std.testing.expectError(error.InvalidParams, storePathAlloc(allocator, "/pref", "../escape"));
}

test "persisted images read back in bounded chunks" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "staged.jpg", .data = "0123456789" });
    const staged = try std.fs.path.join(allocator, &.{ dir, "staged.jpg" });
    defer allocator.free(staged);
    persistClaimed(allocator, dir, "abc123", staged);
    const stored = try storePathAlloc(allocator, dir, "abc123");
    defer allocator.free(stored);
    const chunk = try readChunk(allocator, stored, 4, 3);
    defer allocator.free(chunk.data);
    try std.testing.expectEqual(@as(usize, 10), chunk.total);
    try std.testing.expectEqualStrings("456", chunk.data);
    const tail = try readChunk(allocator, stored, 8, 100);
    defer allocator.free(tail.data);
    try std.testing.expectEqualStrings("89", tail.data);
    prune(allocator, dir, 0);
    const still = try readChunk(allocator, stored, 0, 1);
    allocator.free(still.data);
}
