//! Build-time Wayland protocol scanner (pure Zig, replaces `wayland-scanner`).
//!
//! Usage: wayland-scanner <out.zig> <protocol.xml>...
//!
//! Emits one self-contained Zig file (imports only `std`) containing, per interface:
//!   * a typed object id `enum(u32)` (`WlSurface`, `XdgToplevel`, ...) with
//!     - `interface_id`, `interface_name`, `version` (highest version in the XML)
//!     - protocol enums (`WlShm.Format`; bitfields as `u32` constant namespaces)
//!     - `Event`: a `union(enum)` whose tag order is the event opcode order and whose payload
//!       structs carry typed fields; decoding is done generically by the wire layer
//!     - one method per request taking `conn: anytype`; new_id requests allocate and return
//!       the new typed id. The connection type implements `request`, `newObject`,
//!       `objectVersion`.
//!   * runtime metadata (`interfaces`, signatures) for debug logging, fd counting and
//!     server-created object registration.
//! Arg type mapping: int→i32, uint→u32 (or the protocol enum), fixed→Fixed, string→[]const u8
//! (requests) / [:0]const u8 (events), object→typed id (nullable → optional), new_id→typed id,
//! array→Array, fd→Fd.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ArgKind = enum { int, uint, fixed, string, object, new_id, array, fd };

const Arg = struct {
    name: []const u8,
    kind: ArgKind,
    interface: ?[]const u8 = null,
    allow_null: bool = false,
    enum_ref: ?[]const u8 = null,
};

const Msg = struct {
    name: []const u8,
    since: u32 = 1,
    destructor: bool = false,
    args: std.ArrayList(Arg) = .empty,
};

const Entry = struct { name: []const u8, value: []const u8 };

const Enum = struct {
    name: []const u8,
    bitfield: bool = false,
    entries: std.ArrayList(Entry) = .empty,
};

const Iface = struct {
    name: []const u8,
    version: u32,
    requests: std.ArrayList(Msg) = .empty,
    events: std.ArrayList(Msg) = .empty,
    enums: std.ArrayList(Enum) = .empty,
};

// ---------------------------------------------------------------------------------------------
// Minimal XML tokenizer: yields tags with attributes, skips text, comments, PIs and doctypes.

const Attr = struct { name: []const u8, value: []const u8 };

const Tag = struct {
    name: []const u8,
    closing: bool,
    self_closing: bool,
    attrs: [12]Attr = undefined,
    n_attrs: usize = 0,

    fn get(t: *const Tag, name: []const u8) ?[]const u8 {
        for (t.attrs[0..t.n_attrs]) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }
};

const Xml = struct {
    src: []const u8,
    pos: usize = 0,

    fn next(x: *Xml) error{BadXml}!?Tag {
        while (true) {
            const lt = std.mem.indexOfScalarPos(u8, x.src, x.pos, '<') orelse return null;
            x.pos = lt + 1;
            if (std.mem.startsWith(u8, x.src[x.pos..], "!--")) {
                const end = std.mem.indexOfPos(u8, x.src, x.pos, "-->") orelse return error.BadXml;
                x.pos = end + 3;
                continue;
            }
            if (x.src[x.pos] == '?' or x.src[x.pos] == '!') {
                const end = std.mem.indexOfScalarPos(u8, x.src, x.pos, '>') orelse return error.BadXml;
                x.pos = end + 1;
                continue;
            }
            var tag: Tag = .{ .name = undefined, .closing = false, .self_closing = false };
            if (x.src[x.pos] == '/') {
                tag.closing = true;
                x.pos += 1;
            }
            tag.name = x.ident();
            while (true) {
                x.skipWs();
                if (x.pos >= x.src.len) return error.BadXml;
                const c = x.src[x.pos];
                if (c == '>') {
                    x.pos += 1;
                    return tag;
                }
                if (c == '/') {
                    tag.self_closing = true;
                    x.pos += 1;
                    continue;
                }
                const name = x.ident();
                if (name.len == 0) return error.BadXml;
                x.skipWs();
                if (x.pos >= x.src.len or x.src[x.pos] != '=') return error.BadXml;
                x.pos += 1;
                x.skipWs();
                const q = x.src[x.pos];
                if (q != '"' and q != '\'') return error.BadXml;
                const end = std.mem.indexOfScalarPos(u8, x.src, x.pos + 1, q) orelse return error.BadXml;
                if (tag.n_attrs < tag.attrs.len) {
                    tag.attrs[tag.n_attrs] = .{ .name = name, .value = x.src[x.pos + 1 .. end] };
                    tag.n_attrs += 1;
                }
                x.pos = end + 1;
            }
        }
    }

    fn ident(x: *Xml) []const u8 {
        const start = x.pos;
        while (x.pos < x.src.len) : (x.pos += 1) {
            switch (x.src[x.pos]) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '-', ':', '.' => {},
                else => break,
            }
        }
        return x.src[start..x.pos];
    }

    fn skipWs(x: *Xml) void {
        while (x.pos < x.src.len and std.ascii.isWhitespace(x.src[x.pos])) x.pos += 1;
    }
};

fn parseProtocol(gpa: Allocator, src: []const u8, out: *std.ArrayList(Iface)) !void {
    var x: Xml = .{ .src = src };
    var iface: ?*Iface = null;
    var msg: ?*Msg = null;
    var en: ?*Enum = null;
    while (try x.next()) |tag| {
        const n = tag.name;
        if (tag.closing) {
            if (std.mem.eql(u8, n, "interface")) iface = null;
            if (std.mem.eql(u8, n, "request") or std.mem.eql(u8, n, "event")) msg = null;
            if (std.mem.eql(u8, n, "enum")) en = null;
            continue;
        }
        if (std.mem.eql(u8, n, "interface")) {
            const version = try std.fmt.parseInt(u32, tag.get("version") orelse "1", 10);
            try out.append(gpa, .{ .name = tag.get("name").?, .version = version });
            iface = &out.items[out.items.len - 1];
        } else if (std.mem.eql(u8, n, "request") or std.mem.eql(u8, n, "event")) {
            const i = iface orelse return error.BadXml;
            const list = if (n[0] == 'r') &i.requests else &i.events;
            try list.append(gpa, .{
                .name = tag.get("name").?,
                .since = try std.fmt.parseInt(u32, tag.get("since") orelse "1", 10),
                .destructor = if (tag.get("type")) |t| std.mem.eql(u8, t, "destructor") else false,
            });
            msg = &list.items[list.items.len - 1];
            if (tag.self_closing) msg = null;
        } else if (std.mem.eql(u8, n, "arg")) {
            const m = msg orelse return error.BadXml;
            const kind = std.meta.stringToEnum(ArgKind, tag.get("type").?) orelse return error.BadArgType;
            try m.args.append(gpa, .{
                .name = tag.get("name").?,
                .kind = kind,
                .interface = tag.get("interface"),
                .allow_null = if (tag.get("allow-null")) |v| std.mem.eql(u8, v, "true") else false,
                .enum_ref = tag.get("enum"),
            });
        } else if (std.mem.eql(u8, n, "enum")) {
            const i = iface orelse return error.BadXml;
            try i.enums.append(gpa, .{
                .name = tag.get("name").?,
                .bitfield = if (tag.get("bitfield")) |v| std.mem.eql(u8, v, "true") else false,
            });
            en = &i.enums.items[i.enums.items.len - 1];
        } else if (std.mem.eql(u8, n, "entry")) {
            const e = en orelse return error.BadXml;
            try e.entries.append(gpa, .{ .name = tag.get("name").?, .value = tag.get("value").? });
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Code generation

const Gen = struct {
    gpa: Allocator,
    w: *std.Io.Writer,
    ifaces: []const Iface,

    fn findIface(g: *const Gen, name: []const u8) ?*const Iface {
        for (g.ifaces) |*i| if (std.mem.eql(u8, i.name, name)) return i;
        return null;
    }

    fn findEnum(g: *const Gen, owner: *const Iface, ref: []const u8) ?struct { iface: *const Iface, en: *const Enum } {
        var iface = owner;
        var name = ref;
        if (std.mem.indexOfScalar(u8, ref, '.')) |dot| {
            iface = g.findIface(ref[0..dot]) orelse return null;
            name = ref[dot + 1 ..];
        }
        for (iface.enums.items) |*e| if (std.mem.eql(u8, e.name, name)) return .{ .iface = iface, .en = e };
        return null;
    }
};

/// `wl_surface` -> `WlSurface`.
fn pascal(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    var up = true;
    for (name) |c| {
        if (c == '_') {
            up = true;
            continue;
        }
        buf[n] = if (up) std.ascii.toUpper(c) else c;
        up = false;
        n += 1;
    }
    return buf[0..n];
}

/// `get_xdg_surface` -> `getXdgSurface`.
fn camel(buf: []u8, name: []const u8) []const u8 {
    const s = pascal(buf, name);
    buf[0] = std.ascii.toLower(buf[0]);
    return s;
}

const IdBuf = [128]u8;

fn sigChar(a: Arg) u8 {
    return switch (a.kind) {
        .int => 'i',
        .uint => 'u',
        .fixed => 'f',
        .string => 's',
        .object => 'o',
        .new_id => 'n',
        .array => 'a',
        .fd => 'h',
    };
}

fn writeSignature(w: *std.Io.Writer, m: *const Msg) !void {
    for (m.args.items) |a| {
        if (a.allow_null) try w.writeByte('?');
        if (a.kind == .new_id and a.interface == null) {
            try w.writeAll("sun");
        } else try w.writeByte(sigChar(a));
    }
}

fn writeMessages(g: *Gen, msgs: []const Msg) !void {
    const w = g.w;
    if (msgs.len == 0) return w.writeAll("&.{}");
    try w.writeAll("&.{\n");
    for (msgs) |*m| {
        try w.print("        .{{ .name = \"{s}\", .signature = \"", .{m.name});
        try writeSignature(w, m);
        try w.print("\", .since = {d}", .{m.since});
        if (m.destructor) try w.writeAll(", .destructor = true");
        for (m.args.items) |a| if (a.kind == .new_id) {
            if (a.interface) |ni| if (g.findIface(ni) != null) try w.print(", .new_id = .{s}", .{ni});
        };
        try w.writeAll(" },\n");
    }
    try w.writeAll("    }");
}

/// Writes the Zig type of an argument.
fn writeArgType(g: *Gen, owner: *const Iface, a: Arg, is_event: bool) !void {
    const w = g.w;
    var buf: IdBuf = undefined;
    switch (a.kind) {
        .int, .uint => {
            if (a.enum_ref) |ref| {
                if (g.findEnum(owner, ref)) |found| if (!found.en.bitfield) {
                    var b2: IdBuf = undefined;
                    if (found.iface != owner) try w.print("{s}.", .{pascal(&b2, found.iface.name)});
                    return w.print("{s}", .{pascal(&buf, found.en.name)});
                };
            }
            try w.writeAll(if (a.kind == .int) "i32" else "u32");
        },
        .fixed => try w.writeAll("Fixed"),
        .string => {
            if (a.allow_null) try w.writeByte('?');
            try w.writeAll(if (is_event) "[:0]const u8" else "[]const u8");
        },
        .object, .new_id => {
            if (a.allow_null) try w.writeByte('?');
            if (a.interface) |i| {
                if (g.findIface(i) != null) return w.print("{s}", .{pascal(&buf, i)});
            }
            try w.writeAll("u32");
        },
        .array => try w.writeAll("Array"),
        .fd => try w.writeAll("Fd"),
    }
}

fn isReserved(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

const top_level_names = [_][]const u8{
    "std",      "Fixed",        "Fd",         "Array", "Message", "Interface", "InterfaceId",
    "interfaces", "self",       "conn",       "T",     "ver",
};

fn generate(gpa: Allocator, ifaces: []const Iface, w: *std.Io.Writer) !void {
    var g: Gen = .{ .gpa = gpa, .w = w, .ifaces = ifaces };
    try w.writeAll(prelude);

    try w.writeAll("pub const InterfaceId = enum(u16) {\n");
    for (ifaces) |i| try w.print("    {s},\n", .{i.name});
    try w.writeAll("};\n\npub const interfaces = [_]Interface{\n");
    for (ifaces) |*i| {
        try w.print("    .{{ .name = \"{s}\", .version = {d}, .requests = ", .{ i.name, i.version });
        try writeMessages(&g, i.requests.items);
        try w.writeAll(", .events = ");
        try writeMessages(&g, i.events.items);
        try w.writeAll(" },\n");
    }
    try w.writeAll("};\n");

    for (ifaces, 0..) |*iface, iface_index| {
        var tbuf: IdBuf = undefined;
        const tname = pascal(&tbuf, iface.name);
        try w.print("\npub const {s} = enum(u32) {{\n    _,\n", .{tname});
        try w.print("    pub const interface_id: InterfaceId = .{s};\n", .{iface.name});
        try w.print("    pub const interface: *const Interface = &interfaces[{d}];\n", .{iface_index});
        try w.print("    pub const interface_name = \"{s}\";\n", .{iface.name});
        try w.print("    pub const version: u32 = {d};\n", .{iface.version});

        // Names declared inside this container (params must not shadow them).
        var decls: std.ArrayList([]const u8) = .empty;
        defer {
            for (decls.items) |d| gpa.free(d);
            decls.deinit(gpa);
        }
        for (iface.requests.items) |r| {
            var b: IdBuf = undefined;
            try decls.append(gpa, try gpa.dupe(u8, camel(&b, r.name)));
        }
        for (iface.enums.items) |e| {
            var b: IdBuf = undefined;
            try decls.append(gpa, try gpa.dupe(u8, pascal(&b, e.name)));
        }
        for ([_][]const u8{ "interface_id", "interface", "interface_name", "version", "Event" }) |d|
            try decls.append(gpa, try gpa.dupe(u8, d));

        for (iface.enums.items) |e| {
            var b: IdBuf = undefined;
            if (e.bitfield) {
                try w.print("    pub const {s} = struct {{\n", .{pascal(&b, e.name)});
                for (e.entries.items) |ent| try w.print("        pub const {f}: u32 = {s};\n", .{ std.zig.fmtId(ent.name), ent.value });
            } else {
                try w.print("    pub const {s} = enum(u32) {{\n", .{pascal(&b, e.name)});
                for (e.entries.items) |ent| try w.print("        {f} = {s},\n", .{ std.zig.fmtIdPU(ent.name), ent.value });
                try w.writeAll("        _,\n");
            }
            try w.writeAll("    };\n");
        }

        try w.writeAll("    pub const Event = union(enum) {\n");
        for (iface.events.items) |*ev| {
            try w.print("        {f}: struct {{", .{std.zig.fmtIdPU(ev.name)});
            for (ev.args.items, 0..) |a, k| {
                try w.print("{s}{f}: ", .{ if (k == 0) " " else ", ", std.zig.fmtIdPU(a.name) });
                try writeArgType(&g, iface, a, true);
            }
            try w.writeAll(if (ev.args.items.len > 0) " },\n" else "},\n");
        }
        try w.writeAll("    };\n");

        for (iface.requests.items, 0..) |*req, opcode| {
            var mb: IdBuf = undefined;
            const mname = camel(&mb, req.name);
            var new_id: ?Arg = null;
            for (req.args.items) |a| if (a.kind == .new_id) {
                new_id = a;
            };
            try w.print("    pub fn {f}(self: {s}, conn: anytype", .{ std.zig.fmtId(mname), tname });
            var pnames: [16][]const u8 = undefined;
            var pbufs: [16]IdBuf = undefined;
            for (req.args.items, 0..) |a, k| {
                var nm = a.name;
                if (isReserved(decls.items, nm) or isReserved(&top_level_names, nm)) {
                    nm = try std.fmt.bufPrint(&pbufs[k], "{s}_", .{a.name});
                }
                pnames[k] = nm;
                if (a.kind == .new_id) {
                    if (a.interface == null) try w.writeAll(", comptime T: type, ver: u32");
                    continue;
                }
                try w.print(", {f}: ", .{std.zig.fmtId(nm)});
                try writeArgType(&g, iface, a, false);
            }
            try w.writeAll(") !");
            if (new_id) |a| {
                if (a.interface) |i| {
                    var b: IdBuf = undefined;
                    try w.print("{s}", .{pascal(&b, i)});
                } else try w.writeAll("T");
            } else try w.writeAll("void");
            try w.writeAll(" {\n");
            if (new_id) |a| {
                if (a.interface) |i| {
                    var b: IdBuf = undefined;
                    try w.print("        const new = try conn.newObject({s}, conn.objectVersion(self));\n", .{pascal(&b, i)});
                } else try w.writeAll("        const new = try conn.newObject(T, ver);\n");
            }
            try w.print("        try conn.request(self, {d}, .{{", .{opcode});
            for (req.args.items, 0..) |a, k| {
                try w.writeAll(if (k == 0) " " else ", ");
                if (a.kind == .new_id) {
                    if (a.interface == null) try w.writeAll("T.interface_name, ver, ");
                    try w.writeAll("new");
                } else try w.print("{f}", .{std.zig.fmtId(pnames[k])});
            }
            try w.writeAll(if (req.args.items.len > 0) " });\n" else "});\n");
            if (new_id != null) try w.writeAll("        return new;\n");
            try w.writeAll("    }\n");
        }
        try w.writeAll("};\n");
    }
}

const prelude =
    \\// Generated by palette-native/tools/wayland-scanner.zig from protocols/*.xml. Do not edit.
    \\const std = @import("std");
    \\
    \\/// 24.8 signed fixed-point number.
    \\pub const Fixed = enum(i32) {
    \\    _,
    \\    pub fn fromInt(v: i32) Fixed {
    \\        return @enumFromInt(v *% 256);
    \\    }
    \\    pub fn fromFloat(v: f64) Fixed {
    \\        return @enumFromInt(@as(i32, @intFromFloat(@round(v * 256.0))));
    \\    }
    \\    pub fn toFloat(f: Fixed) f64 {
    \\        return @as(f64, @floatFromInt(@intFromEnum(f))) / 256.0;
    \\    }
    \\    pub fn toInt(f: Fixed) i32 {
    \\        return @divTrunc(@intFromEnum(f), 256);
    \\    }
    \\};
    \\
    \\/// A file descriptor passed with SCM_RIGHTS. Received fds are owned by the event handler.
    \\pub const Fd = enum(i32) { _ };
    \\
    \\/// Opaque byte array argument (4-byte aligned on the wire).
    \\pub const Array = struct {
    \\    data: []const u8 = &.{},
    \\    pub fn u32s(a: Array) []align(1) const u32 {
    \\        return std.mem.bytesAsSlice(u32, a.data[0 .. a.data.len / 4 * 4]);
    \\    }
    \\};
    \\
    \\pub const Message = struct {
    \\    name: []const u8,
    \\    /// One char per wire argument: i u f s o n a h; '?' prefixes nullable args.
    \\    /// Untyped new_id (wl_registry.bind) expands to "sun".
    \\    signature: []const u8,
    \\    since: u16 = 1,
    \\    destructor: bool = false,
    \\    /// Interface of the (typed) new_id argument, if any.
    \\    new_id: ?InterfaceId = null,
    \\};
    \\
    \\pub const Interface = struct {
    \\    name: [:0]const u8,
    \\    version: u32,
    \\    requests: []const Message,
    \\    events: []const Message,
    \\};
    \\
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) std.process.fatal("usage: wayland-scanner <out.zig> <protocol.xml>...", .{});

    var ifaces: std.ArrayList(Iface) = .empty;
    for (args[2..]) |path| {
        const src = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20)) catch |err|
            std.process.fatal("cannot read {s}: {t}", .{ path, err });
        parseProtocol(arena, src, &ifaces) catch |err| std.process.fatal("{s}: {t}", .{ path, err });
    }
    var aw: std.Io.Writer.Allocating = .init(arena);
    try generate(arena, ifaces.items, &aw.writer);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = aw.written() });
}

test "names" {
    var b: IdBuf = undefined;
    try std.testing.expectEqualStrings("ZwpLinuxDmabufV1", pascal(&b, "zwp_linux_dmabuf_v1"));
    try std.testing.expectEqualStrings("getXdgSurface", camel(&b, "get_xdg_surface"));
}

test "generate small protocol" {
    const xml =
        \\<?xml version="1.0"?>
        \\<protocol name="t">
        \\  <!-- comment <interface> -->
        \\  <interface name="t_thing" version="3">
        \\    <description summary="x">text &amp; more</description>
        \\    <enum name="mode"><entry name="a" value="0"/><entry name="1x" value="1"/></enum>
        \\    <enum name="flags" bitfield="true"><entry name="y" value="0x2"/></enum>
        \\    <request name="destroy" type="destructor"/>
        \\    <request name="set_mode" since="2"><arg name="mode" type="uint" enum="mode"/><arg name="title" type="string" allow-null="true"/></request>
        \\    <request name="get_child"><arg name="id" type="new_id" interface="t_thing"/><arg name="fd" type="fd"/></request>
        \\    <event name="changed"><arg name="mode" type="uint" enum="mode"/><arg name="flags" type="uint" enum="flags"/><arg name="data" type="array"/><arg name="name" type="string"/></event>
        \\  </interface>
        \\</protocol>
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ifaces: std.ArrayList(Iface) = .empty;
    try parseProtocol(a, xml, &ifaces);
    try std.testing.expectEqual(@as(usize, 1), ifaces.items.len);
    try std.testing.expectEqual(@as(usize, 3), ifaces.items[0].requests.items.len);
    var aw: std.Io.Writer.Allocating = .init(a);
    try generate(a, ifaces.items, &aw.writer);
    const out = aw.written();
    const expect = [_][]const u8{
        "pub const TThing = enum(u32) {",
        "        @\"1x\" = 1,",
        "        pub const y: u32 = 0x2;",
        "changed: struct { mode: Mode, flags: u32, data: Array, name: [:0]const u8 },",
        "pub fn setMode(self: TThing, conn: anytype, mode: Mode, title: ?[]const u8) !void {",
        "pub fn getChild(self: TThing, conn: anytype, fd: Fd) !TThing {",
        ".{ .name = \"get_child\", .signature = \"nh\", .since = 1, .new_id = .t_thing },",
        ".{ .name = \"set_mode\", .signature = \"u?s\", .since = 2 },",
        ".{ .name = \"destroy\", .signature = \"\", .since = 1, .destructor = true },",
    };
    for (expect) |e| {
        if (std.mem.indexOf(u8, out, e) == null) {
            std.debug.print("missing: {s}\n--- output ---\n{s}\n", .{ e, out });
            return error.TestUnexpectedResult;
        }
    }
}
