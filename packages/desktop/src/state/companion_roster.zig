//! Machine-wide Companion roster: the named characters that orchestrate all of
//! Verde. One roster exists per machine (persisted beside Verde's data), not
//! per workspace. Each companion owns one durable chat thread that lives in a
//! "home" workspace only because chat threads need a working directory; the
//! companion itself is not scoped to that workspace.

const Self = @This();

const std = @import("std");
const app_config = @import("../app/config.zig");

const log = std.log.scoped(.companion_roster);

pub const FILE_NAME = "companions.json";
pub const MAX_COMPANIONS: usize = 8;
pub const NAME_CAPACITY: usize = 32;
const ID_CAPACITY: usize = 48;
const REF_CAPACITY: usize = 160;
const PROVIDER_CAPACITY: usize = 24;
const MODEL_CAPACITY: usize = 160;
pub const ORDERS_CAPACITY: usize = 1024;
const MAX_FILE_BYTES: usize = 64 * 1024;

/// Fixed-capacity, value-owned text so roster entries copy freely and never
/// need allocator ownership.
pub fn Text(comptime capacity: usize) type {
    return struct {
        const TextSelf = @This();
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *TextSelf, value: []const u8) void {
            const clipped = utf8Prefix(value, capacity);
            @memcpy(self.bytes[0..clipped.len], clipped);
            self.len = clipped.len;
        }

        pub fn slice(self: *const TextSelf) []const u8 {
            return self.bytes[0..@min(self.len, capacity)];
        }

        pub fn isEmpty(self: *const TextSelf) bool {
            return self.len == 0;
        }

        pub fn eql(self: *const TextSelf, value: []const u8) bool {
            return std.mem.eql(u8, self.slice(), value);
        }
    };
}

pub const Name = Text(NAME_CAPACITY);

pub const Companion = struct {
    id: Text(ID_CAPACITY) = .{},
    name: Name = .{},
    character: app_config.CompanionCharacter = .sprout,
    /// Workspace hosting the companion's chat thread (its working directory).
    home_workspace_id: Text(REF_CAPACITY) = .{},
    /// Durable local thread id inside the home workspace; empty until the
    /// first draft or send creates the thread.
    thread_id: Text(REF_CAPACITY) = .{},
    /// Preferred brain for threads this companion creates. Empty means "use
    /// the new-chat defaults". The live thread remains the source of truth for
    /// an existing conversation.
    provider: Text(PROVIDER_CAPACITY) = .{},
    model: Text(MODEL_CAPACITY) = .{},
    /// Standing orders the user wrote for this companion; included in every
    /// turn's persona ("always run tests before calling work done").
    orders: Text(ORDERS_CAPACITY) = .{},

    pub fn hasThread(self: *const Companion, workspace_id: []const u8, thread_id: []const u8) bool {
        return !self.thread_id.isEmpty() and self.home_workspace_id.eql(workspace_id) and self.thread_id.eql(thread_id);
    }
};

entries: [MAX_COMPANIONS]Companion = [_]Companion{.{}} ** MAX_COMPANIONS,
count: usize = 0,
active_index: usize = 0,
/// True once the daemon roster arrived. Until then the GUI never invents
/// companions, so it cannot overwrite a roster another client saved.
loaded: bool = false,
/// True when neither the daemon nor a legacy file had a roster; the caller
/// may adopt legacy per-workspace Companion threads exactly once.
needs_legacy_adoption: bool = false,
/// Local edits not yet stored by the daemon.
dirty: bool = false,
/// Daemon revision this roster reflects (0 = never stored).
revision: i64 = 0,
id_counter: u32 = 0,

pub fn init() Self {
    return .{};
}

pub fn items(self: *const Self) []const Companion {
    return self.entries[0..@min(self.count, MAX_COMPANIONS)];
}

pub fn active(self: *Self) ?*Companion {
    if (self.count == 0) return null;
    if (self.active_index >= self.count) self.active_index = 0;
    return &self.entries[self.active_index];
}

pub fn activeConst(self: *const Self) ?*const Companion {
    if (self.count == 0) return null;
    return &self.entries[@min(self.active_index, self.count - 1)];
}

pub fn isFull(self: *const Self) bool {
    return self.count >= MAX_COMPANIONS;
}

/// Adds a companion and makes it active. Names default to the character's
/// display name and are de-duplicated with a numeric suffix.
pub fn add(self: *Self, character: app_config.CompanionCharacter, name: ?[]const u8, now_ms: i64) ?*Companion {
    if (self.isFull()) return null;
    var entry: Companion = .{ .character = character };
    var id_buffer: [ID_CAPACITY]u8 = undefined;
    self.id_counter +%= 1;
    const id = std.fmt.bufPrint(&id_buffer, "cmp-{d}-{d}", .{ now_ms, self.id_counter }) catch "cmp";
    entry.id.set(id);
    const base = cleanName(name orelse characterDisplayName(character));
    self.setUniqueName(&entry, if (base.len > 0) base else characterDisplayName(character), null);
    self.entries[self.count] = entry;
    self.active_index = self.count;
    self.count += 1;
    self.dirty = true;
    return &self.entries[self.active_index];
}

pub fn remove(self: *Self, index: usize) bool {
    if (index >= self.count) return false;
    var cursor = index;
    while (cursor + 1 < self.count) : (cursor += 1) self.entries[cursor] = self.entries[cursor + 1];
    self.count -= 1;
    self.entries[self.count] = .{};
    if (self.active_index > index or self.active_index >= self.count) self.active_index -|= 1;
    if (self.count == 0) self.active_index = 0;
    self.dirty = true;
    return true;
}

pub fn select(self: *Self, index: usize) bool {
    if (index >= self.count or index == self.active_index) return false;
    self.active_index = index;
    self.dirty = true;
    return true;
}

/// Cycles the active companion; returns false with fewer than two.
pub fn cycle(self: *Self, forward: bool) bool {
    if (self.count < 2) return false;
    self.active_index = if (forward)
        (self.active_index + 1) % self.count
    else
        (self.active_index + self.count - 1) % self.count;
    self.dirty = true;
    return true;
}

/// Renames the companion at `index`; empty or whitespace names are rejected.
pub fn rename(self: *Self, index: usize, name: []const u8) bool {
    if (index >= self.count) return false;
    const cleaned = cleanName(name);
    if (cleaned.len == 0) return false;
    self.setUniqueName(&self.entries[index], cleaned, index);
    self.dirty = true;
    return true;
}

pub fn setCharacter(self: *Self, index: usize, character: app_config.CompanionCharacter) bool {
    if (index >= self.count or self.entries[index].character == character) return false;
    self.entries[index].character = character;
    self.dirty = true;
    return true;
}

pub fn bindThread(self: *Self, index: usize, workspace_id: []const u8, thread_id: []const u8) void {
    if (index >= self.count) return;
    const entry = &self.entries[index];
    if (entry.home_workspace_id.eql(workspace_id) and entry.thread_id.eql(thread_id)) return;
    entry.home_workspace_id.set(workspace_id);
    entry.thread_id.set(thread_id);
    self.dirty = true;
}

pub fn clearThread(self: *Self, index: usize) void {
    if (index >= self.count or self.entries[index].thread_id.isEmpty()) return;
    self.entries[index].thread_id.set("");
    self.dirty = true;
}

/// Replaces standing orders; whitespace-only text clears them.
pub fn setOrders(self: *Self, index: usize, orders: []const u8) void {
    if (index >= self.count) return;
    self.entries[index].orders.set(std.mem.trim(u8, orders, " \t\r\n"));
    self.dirty = true;
}

pub fn setBrain(self: *Self, index: usize, provider: []const u8, model: ?[]const u8) void {
    if (index >= self.count) return;
    const entry = &self.entries[index];
    entry.provider.set(provider);
    entry.model.set(model orelse "");
    self.dirty = true;
}

/// Index of the companion that owns this thread, if any.
pub fn indexForThread(self: *const Self, workspace_id: []const u8, thread_id: []const u8) ?usize {
    for (self.items(), 0..) |*entry, index| {
        if (entry.hasThread(workspace_id, thread_id)) return index;
    }
    return null;
}

// ---- persistence ---------------------------------------------------------

const WireCompanion = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    character: []const u8 = "sprout",
    home_workspace_id: []const u8 = "",
    thread_id: []const u8 = "",
    provider: []const u8 = "",
    model: []const u8 = "",
    orders: []const u8 = "",
};

const WireRoster = struct {
    version: u32 = 1,
    active_id: []const u8 = "",
    companions: []const WireCompanion = &.{},
};

pub fn pathAlloc(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ pref_path, FILE_NAME });
}

/// Reads the pre-daemon `companions.json` (desktop-only builds wrote it) so
/// its companions migrate into the daemon roster. Returns false when absent
/// or unreadable.
pub fn loadLegacyFile(self: *Self, allocator: std.mem.Allocator, pref_path: []const u8) bool {
    const path = pathAlloc(allocator, pref_path) catch return false;
    defer allocator.free(path);
    var threaded = std.Io.Threaded.init_single_threaded;
    const bytes = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(MAX_FILE_BYTES)) catch return false;
    defer allocator.free(bytes);
    self.parse(allocator, bytes) catch |err| {
        log.warn("ignoring unreadable legacy companion roster: {s}", .{@errorName(err)});
        return false;
    };
    return self.count > 0;
}

pub fn parse(self: *Self, allocator: std.mem.Allocator, bytes: []const u8) !void {
    const parsed = try std.json.parseFromSlice(WireRoster, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    self.count = 0;
    self.active_index = 0;
    for (parsed.value.companions) |wire| {
        if (self.count >= MAX_COMPANIONS) break;
        var entry: Companion = .{
            .character = app_config.CompanionCharacter.parse(wire.character) orelse .sprout,
        };
        entry.id.set(wire.id);
        const name = cleanName(wire.name);
        entry.name.set(if (name.len > 0) name else characterDisplayName(entry.character));
        entry.home_workspace_id.set(wire.home_workspace_id);
        entry.thread_id.set(wire.thread_id);
        entry.provider.set(wire.provider);
        entry.model.set(wire.model);
        entry.orders.set(wire.orders);
        if (entry.id.isEmpty()) {
            var id_buffer: [ID_CAPACITY]u8 = undefined;
            entry.id.set(std.fmt.bufPrint(&id_buffer, "cmp-restored-{d}", .{self.count}) catch "cmp");
        }
        if (std.mem.eql(u8, entry.id.slice(), parsed.value.active_id)) self.active_index = self.count;
        self.entries[self.count] = entry;
        self.count += 1;
    }
}

pub fn encodeAlloc(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
    var wires: [MAX_COMPANIONS]WireCompanion = undefined;
    for (self.entries[0..self.count], 0..) |*entry, index| {
        wires[index] = .{
            .id = entry.id.slice(),
            .name = entry.name.slice(),
            .character = @tagName(entry.character),
            .home_workspace_id = entry.home_workspace_id.slice(),
            .thread_id = entry.thread_id.slice(),
            .provider = entry.provider.slice(),
            .model = entry.model.slice(),
            .orders = entry.orders.slice(),
        };
    }
    const wire: WireRoster = .{
        .active_id = if (self.activeConst()) |entry| entry.id.slice() else "",
        .companions = wires[0..self.count],
    };
    return std.json.Stringify.valueAlloc(allocator, wire, .{ .whitespace = .indent_2 });
}

// ---- helpers -------------------------------------------------------------

pub fn characterDisplayName(character: app_config.CompanionCharacter) []const u8 {
    return switch (character) {
        .sprout => "Sprout",
        .moss => "Moss",
        .vireo => "Vireo",
    };
}

/// One-line personality blurb per character. Characters double as an
/// autonomy preset in the persona note.
pub fn characterTagline(character: app_config.CompanionCharacter) []const u8 {
    return switch (character) {
        .sprout => "Careful · checks in before big moves",
        .moss => "Steady · does the work, then summarizes",
        .vireo => "Quick · runs ahead, pings only when it matters",
    };
}

/// Trims whitespace, drops control characters, and clips to capacity on a
/// UTF-8 boundary.
pub fn cleanName(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] >= 0x20 and trimmed[end] != 0x7f) end += 1;
    return std.mem.trimEnd(u8, utf8Prefix(trimmed[0..end], NAME_CAPACITY), " \t");
}

fn utf8Prefix(value: []const u8, capacity: usize) []const u8 {
    if (value.len <= capacity) return value;
    var end = capacity;
    while (end > 0 and (value[end] & 0xC0) == 0x80) end -= 1;
    return value[0..end];
}

fn setUniqueName(self: *const Self, entry: *Companion, base: []const u8, skip_index: ?usize) void {
    entry.name.set(base);
    var suffix: usize = 2;
    while (self.nameTaken(entry.name.slice(), skip_index) and suffix < 100) : (suffix += 1) {
        var buffer: [NAME_CAPACITY + 8]u8 = undefined;
        const clipped = utf8Prefix(base, NAME_CAPACITY - 3);
        entry.name.set(std.fmt.bufPrint(&buffer, "{s} {d}", .{ clipped, suffix }) catch base);
    }
}

fn nameTaken(self: *const Self, name: []const u8, skip_index: ?usize) bool {
    for (self.entries[0..self.count], 0..) |*entry, index| {
        if (skip_index != null and skip_index.? == index) continue;
        if (std.ascii.eqlIgnoreCase(entry.name.slice(), name)) return true;
    }
    return false;
}

test "roster add names companions after their character and de-duplicates" {
    var roster = Self.init();
    const first = roster.add(.moss, null, 1).?;
    try std.testing.expectEqualStrings("Moss", first.name.slice());
    const second = roster.add(.moss, null, 2).?;
    try std.testing.expectEqualStrings("Moss 2", second.name.slice());
    const third = roster.add(.vireo, "  Juniper\n", 3).?;
    try std.testing.expectEqualStrings("Juniper", third.name.slice());
    try std.testing.expectEqual(@as(usize, 2), roster.active_index);
    try std.testing.expect(roster.dirty);
}

test "roster rename rejects blank names and keeps names unique" {
    var roster = Self.init();
    _ = roster.add(.sprout, "Juniper", 1);
    _ = roster.add(.moss, "Fern", 2);
    try std.testing.expect(!roster.rename(1, "   "));
    try std.testing.expectEqualStrings("Fern", roster.entries[1].name.slice());
    try std.testing.expect(roster.rename(1, "juniper"));
    try std.testing.expectEqualStrings("juniper 2", roster.entries[1].name.slice());
    try std.testing.expect(roster.rename(1, "A name that is far longer than thirty-two bytes"));
    try std.testing.expect(roster.entries[1].name.len <= NAME_CAPACITY);
}

test "roster cycle select and remove keep the active index valid" {
    var roster = Self.init();
    try std.testing.expect(!roster.cycle(true));
    _ = roster.add(.sprout, null, 1);
    _ = roster.add(.moss, null, 2);
    _ = roster.add(.vireo, null, 3);
    try std.testing.expect(roster.cycle(true));
    try std.testing.expectEqual(@as(usize, 0), roster.active_index);
    try std.testing.expect(roster.cycle(false));
    try std.testing.expectEqual(@as(usize, 2), roster.active_index);
    try std.testing.expect(roster.remove(2));
    try std.testing.expectEqual(@as(usize, 1), roster.active_index);
    try std.testing.expect(roster.remove(0));
    try std.testing.expectEqual(@as(usize, 0), roster.active_index);
    try std.testing.expectEqualStrings("Moss", roster.active().?.name.slice());
    try std.testing.expect(roster.remove(0));
    try std.testing.expect(roster.active() == null);
}

test "roster thread binding resolves owners across workspaces" {
    var roster = Self.init();
    _ = roster.add(.sprout, null, 1);
    _ = roster.add(.moss, null, 2);
    roster.bindThread(0, "ws-a", "chat-1");
    roster.bindThread(1, "ws-b", "chat-2");
    try std.testing.expectEqual(@as(?usize, 0), roster.indexForThread("ws-a", "chat-1"));
    try std.testing.expectEqual(@as(?usize, 1), roster.indexForThread("ws-b", "chat-2"));
    try std.testing.expect(roster.indexForThread("ws-a", "chat-2") == null);
    roster.clearThread(0);
    try std.testing.expect(roster.indexForThread("ws-a", "chat-1") == null);
}

test "roster json round trip preserves companions, brains, and the active pick" {
    const allocator = std.testing.allocator;
    var roster = Self.init();
    _ = roster.add(.sprout, "Juniper", 1);
    _ = roster.add(.vireo, "Wren", 2);
    roster.bindThread(0, "ws-a", "chat-1");
    roster.setBrain(1, "claude", "opus");
    roster.setOrders(1, "  Run the tests before calling anything done.\n");
    _ = roster.select(0);
    const encoded = try roster.encodeAlloc(allocator);
    defer allocator.free(encoded);

    var restored = Self.init();
    try restored.parse(allocator, encoded);
    try std.testing.expectEqual(@as(usize, 2), restored.count);
    try std.testing.expectEqual(@as(usize, 0), restored.active_index);
    try std.testing.expectEqualStrings("Juniper", restored.entries[0].name.slice());
    try std.testing.expectEqualStrings("chat-1", restored.entries[0].thread_id.slice());
    try std.testing.expectEqual(app_config.CompanionCharacter.vireo, restored.entries[1].character);
    try std.testing.expectEqualStrings("claude", restored.entries[1].provider.slice());
    try std.testing.expectEqualStrings("opus", restored.entries[1].model.slice());
    try std.testing.expectEqualStrings("Run the tests before calling anything done.", restored.entries[1].orders.slice());
}

test "roster parse tolerates unknown characters, blank names, and extra fields" {
    const allocator = std.testing.allocator;
    var roster = Self.init();
    try roster.parse(allocator,
        \\{"version":1,"future":true,"companions":[{"name":"  ","character":"fern","extra":1}]}
    );
    try std.testing.expectEqual(@as(usize, 1), roster.count);
    try std.testing.expectEqual(app_config.CompanionCharacter.sprout, roster.entries[0].character);
    try std.testing.expectEqualStrings("Sprout", roster.entries[0].name.slice());
    try std.testing.expect(!roster.entries[0].id.isEmpty());
}

test "legacy roster file migrates and a missing file reports absent" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir_path);

    var missing = Self.init();
    try std.testing.expect(!missing.loadLegacyFile(allocator, dir_path));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = FILE_NAME, .data = "{\"companions\":[{\"id\":\"a\",\"name\":\"Fern\",\"character\":\"moss\"}]}" });
    var restored = Self.init();
    try std.testing.expect(restored.loadLegacyFile(allocator, dir_path));
    try std.testing.expectEqualStrings("Fern", restored.active().?.name.slice());
}
