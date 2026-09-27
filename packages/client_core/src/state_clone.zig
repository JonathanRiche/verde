//! Deep-copy the core's value-only state between transaction arenas without
//! serializing/parsing the entire chat/catalog history on every keystroke.
const std = @import("std");
const A = std.mem.Allocator;
const V = std.json.Value;

/// Destination must be an arena: failed partial copies are reclaimed together.
/// No pointers into the source arena (including JSON keys) may escape.
pub fn clone(comptime T: type, a: A, source: T) error{OutOfMemory}!T {
    if (T == V) return cloneJson(a, source);
    return switch (@typeInfo(T)) {
        .optional => |info| if (source) |v| try clone(info.child, a, v) else null,
        .pointer => |info| blk: {
            if (info.size != .slice or info.sentinel_ptr != null) @compileError("state clone requires unsentinelled value slices");
            if (info.child == u8) break :blk try a.dupe(u8, source);
            const dest = try a.alloc(info.child, source.len);
            for (source, dest) |v, *out| out.* = try clone(info.child, a, v);
            break :blk dest;
        },
        .@"struct" => |info| blk: {
            var dest: T = undefined;
            inline for (info.fields) |field| {
                if (field.is_comptime) @compileError("state clone does not support comptime fields");
                @field(dest, field.name) = try clone(field.type, a, @field(source, field.name));
            }
            break :blk dest;
        },
        .array => |info| blk: {
            var dest: T = undefined;
            for (source, &dest) |v, *out| out.* = try clone(info.child, a, v);
            break :blk dest;
        },
        .@"union" => |info| blk: {
            if (info.tag_type == null) @compileError("state clone requires tagged unions");
            inline for (info.fields) |field| {
                if (std.meta.activeTag(source) == @field(info.tag_type.?, field.name))
                    break :blk @unionInit(T, field.name, try clone(field.type, a, @field(source, field.name)));
            }
            unreachable;
        },
        .int, .float, .bool, .@"enum", .void, .null => source,
        else => @compileError("unsupported state clone type: " ++ @typeName(T)),
    };
}

fn cloneJson(a: A, source: V) error{OutOfMemory}!V {
    return switch (source) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .array => |items| blk: {
            var dest = try std.json.Array.initCapacity(a, items.items.len);
            for (items.items) |v| dest.appendAssumeCapacity(try cloneJson(a, v));
            break :blk .{ .array = dest };
        },
        .object => |object| blk: {
            var dest: std.json.ObjectMap = .empty;
            try dest.ensureTotalCapacity(a, object.count());
            var it = object.iterator();
            while (it.next()) |entry| {
                dest.putAssumeCapacity(try a.dupe(u8, entry.key_ptr.*), try cloneJson(a, entry.value_ptr.*));
            }
            break :blk .{ .object = dest };
        },
        else => source,
    };
}

const Fixture = struct {
    name: []const u8,
    nested: []const []const u8,
    optional: ?[]const u8,
    choice: union(enum) { text: []const u8, count: u64 },
    bytes: [3]u8,
    json: V,
};

fn fixture(a: A) !Fixture {
    const names = try a.alloc([]const u8, 2);
    names[0] = try a.dupe(u8, "first");
    names[1] = try a.dupe(u8, "second");
    return .{
        .name = try a.dupe(u8, "name"),
        .nested = names,
        .optional = try a.dupe(u8, "optional"),
        .choice = .{ .text = try a.dupe(u8, "tagged") },
        .bytes = .{ 1, 2, 3 },
        .json = try std.json.parseFromSliceLeaky(V, a, "{\"key\":[\"escaped\\ntext\",null,true,42,1.5,1e999]}", .{ .allocate = .alloc_always }),
    };
}

test "state copies own nested slices JSON containers keys and tagged payloads" {
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    const source = try fixture(source_arena.allocator());
    var dest_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer dest_arena.deinit();
    const a = dest_arena.allocator();
    const dest = try clone(Fixture, a, source);
    try std.testing.expect(equal(Fixture, source, dest));
    const expected = try std.json.Stringify.valueAlloc(a, source, .{});
    try std.testing.expectEqualStrings(expected, try std.json.Stringify.valueAlloc(a, dest, .{}));
    try std.testing.expect(dest.name.ptr != source.name.ptr);
    try std.testing.expect(dest.nested.ptr != source.nested.ptr);
    try std.testing.expect(dest.nested[0].ptr != source.nested[0].ptr);
    try std.testing.expect(dest.optional.?.ptr != source.optional.?.ptr);
    try std.testing.expect(dest.choice.text.ptr != source.choice.text.ptr);
    try std.testing.expect(dest.json.object.keys()[0].ptr != source.json.object.keys()[0].ptr);
    // Releasing the source must not invalidate any retained transaction state.
    @constCast(source.name)[0] = 'X';
    try std.testing.expect(!equal(Fixture, source, dest));
    _ = source_arena.reset(.free_all);
    try std.testing.expectEqualStrings(expected, try std.json.Stringify.valueAlloc(a, dest, .{}));
}

fn allocationScenario(a: A) !void {
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    const source = try fixture(source_arena.allocator());
    var dest_arena = std.heap.ArenaAllocator.init(a);
    defer dest_arena.deinit();
    const dest = try clone(Fixture, dest_arena.allocator(), source);
    try std.testing.expectEqualStrings("name", dest.name);
    try std.testing.expectEqualStrings("first", source.nested[0]);
}

test "partial state copies release all allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

/// Structural equality for value state; pointers and container capacity are not data.
pub fn equal(comptime T: type, left: T, right: T) bool {
    if (T == V) {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .string => |v| std.mem.eql(u8, v, right.string),
            .number_string => |v| std.mem.eql(u8, v, right.number_string),
            .array => |v| equal([]const V, v.items, right.array.items),
            .object => |v| blk: {
                if (v.count() != right.object.count()) break :blk false;
                var it = v.iterator();
                while (it.next()) |entry| {
                    const other = right.object.get(entry.key_ptr.*) orelse break :blk false;
                    if (!equal(V, entry.value_ptr.*, other)) break :blk false;
                }
                break :blk true;
            },
            .null => true,
            .bool => |v| v == right.bool,
            .integer => |v| v == right.integer,
            .float => |v| v == right.float,
        };
    }
    return switch (@typeInfo(T)) {
        .optional => |info| if (left == null or right == null) left == null and right == null else equal(info.child, left.?, right.?),
        .pointer => |info| blk: {
            if (info.size != .slice) @compileError("state equality requires value slices");
            if (info.child == u8) break :blk std.mem.eql(u8, left, right);
            if (left.len != right.len) break :blk false;
            for (left, right) |l, r| if (!equal(info.child, l, r)) break :blk false;
            break :blk true;
        },
        .@"struct" => |info| inline for (info.fields) |field| {
            if (!equal(field.type, @field(left, field.name), @field(right, field.name))) break false;
        } else true,
        .array => |info| for (left, right) |l, r| {
            if (!equal(info.child, l, r)) break false;
        } else true,
        .@"union" => |info| blk: {
            if (std.meta.activeTag(left) != std.meta.activeTag(right)) break :blk false;
            inline for (info.fields) |field| {
                if (std.meta.activeTag(left) == @field(info.tag_type.?, field.name))
                    break :blk equal(field.type, @field(left, field.name), @field(right, field.name));
            }
            unreachable;
        },
        else => left == right,
    };
}
