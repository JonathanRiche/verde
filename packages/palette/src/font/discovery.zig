//! fontconfig-free system font discovery.
//!
//! Scans the XDG font directories (macOS: ~/Library/Fonts, /Library/Fonts and
//! /System/Library/Fonts) recursively for .ttf/.otf/.ttc/.otc files and reads only the
//! table directory plus the `name`, `OS/2`, `post` and `head` tables of each face (positional
//! reads, never the whole file) to build an index: family, style, weight, italic, monospace,
//! path, TTC index. The index is cached in `$XDG_CACHE_HOME/palette/fonts-v1.bin` (macOS:
//! `~/Library/Caches/palette/fonts-v1.bin` unless XDG_CACHE_HOME is set), keyed by the
//! mtimes of every scanned directory (adding/removing a font changes its directory's mtime).
//!
//! `match(SystemQuery)` scores entries (family > weight distance > italic > monospace) and
//! understands generic families (sans-serif, serif, monospace, emoji, system-ui).
//! `fallbackForCodepoint(cp)` lazily probes `cmap` tables (one representative face per family,
//! broad-coverage families first) and caches results per codepoint.

const std = @import("std");
const builtin = @import("builtin");
const sfnt = @import("sfnt.zig");
const api = @import("api.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

pub const Options = struct {
    /// Directories scanned before the standard XDG ones.
    extra_dirs: []const []const u8 = &.{},
    use_standard_dirs: bool = true,
    /// Read/write the on-disk index cache.
    use_cache: bool = true,
    /// Override the cache file path.
    cache_path: ?[]const u8 = null,
    max_depth: u8 = 10,
    /// Upper bound of cmap bytes kept in memory for codepoint fallback probing.
    fallback_cmap_budget: usize = 8 << 20,
};

pub const Entry = struct {
    /// Typographic family (name id 16) when present, else family (1).
    family: []const u8,
    /// Legacy family (name id 1), e.g. "Noto Sans Medium".
    legacy_family: []const u8,
    style: []const u8,
    path_index: u32,
    face_index: u16,
    weight: u16,
    italic: bool,
    monospace: bool,
    /// Has glyf or CFF outlines (bitmap-only colour fonts are skipped for fallback).
    outlines: bool,
};

pub const Match = struct {
    path: []const u8,
    face_index: u32,
    entry: *const Entry,
    score: i32,
};

const DirStamp = struct { path: []const u8, mtime: i96 };

const cache_magic = "PFNTIDX1";

pub const Index = struct {
    gpa: std.mem.Allocator,
    io: Io,
    options: Options,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    paths: std.ArrayList([]const u8) = .empty,
    dirs: std.ArrayList(DirStamp) = .empty,
    roots: std.ArrayList([]const u8) = .empty,
    from_cache: bool = false,
    // Fallback state.
    fallback_order: ?[]u32 = null,
    fallback_cache: std.AutoHashMapUnmanaged(u21, i32) = .empty,
    cmaps: std.AutoHashMapUnmanaged(u32, CachedCmap) = .empty,
    cmap_bytes: usize = 0,
    cmap_tick: u64 = 0,

    const CachedCmap = struct { bytes: []u8, cmap: sfnt.Cmap, num_glyphs: u32, last_use: u64 };

    pub fn create(gpa: std.mem.Allocator, io: Io, environ: ?*const std.process.Environ.Map, options: Options) !*Index {
        const self = try gpa.create(Index);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .options = options, .arena = .init(gpa) };
        errdefer self.deinitInner();
        try self.collectRoots(environ);
        const cache_path = try self.cachePath(environ);
        if (options.use_cache) {
            if (cache_path) |cp| {
                if (self.loadCache(cp)) |ok| {
                    if (ok) {
                        self.from_cache = true;
                        return self;
                    }
                } else |_| {}
                self.resetIndex();
            }
        }
        try self.scan();
        if (options.use_cache) if (cache_path) |cp| self.saveCache(cp) catch {};
        return self;
    }

    pub fn destroy(self: *Index) void {
        const gpa = self.gpa;
        self.deinitInner();
        gpa.destroy(self);
    }

    fn deinitInner(self: *Index) void {
        const gpa = self.gpa;
        self.entries.deinit(gpa);
        self.paths.deinit(gpa);
        self.dirs.deinit(gpa);
        self.roots.deinit(gpa);
        if (self.fallback_order) |o| gpa.free(o);
        self.fallback_cache.deinit(gpa);
        var it = self.cmaps.valueIterator();
        while (it.next()) |c| gpa.free(c.bytes);
        self.cmaps.deinit(gpa);
        self.arena.deinit();
    }

    fn resetIndex(self: *Index) void {
        self.entries.clearRetainingCapacity();
        self.paths.clearRetainingCapacity();
        self.dirs.clearRetainingCapacity();
    }

    pub fn count(self: *const Index) usize {
        return self.entries.items.len;
    }

    pub fn pathOf(self: *const Index, e: *const Entry) []const u8 {
        return self.paths.items[e.path_index];
    }

    /// Approximate heap bytes held by the index.
    pub fn memoryUsed(self: *const Index) usize {
        return self.arena.queryCapacity() + self.entries.capacity * @sizeOf(Entry) +
            self.paths.capacity * @sizeOf([]const u8) + self.dirs.capacity * @sizeOf(DirStamp) + self.cmap_bytes +
            self.fallback_cache.capacity() * 8;
    }

    // -- roots / env ---------------------------------------------------------------------------

    fn getenv(environ: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
        if (environ) |m| return m.get(key);
        if (builtin.link_libc) {
            var buf: [64]u8 = undefined;
            if (key.len >= buf.len) return null;
            @memcpy(buf[0..key.len], key);
            buf[key.len] = 0;
            const v = std.c.getenv(@ptrCast(&buf)) orelse return null;
            return std.mem.span(v);
        }
        return null;
    }

    fn addRoot(self: *Index, path: []const u8) !void {
        // Absolute only: `/...` on POSIX; `C:\...`, `\\server\...` or `/...` on Windows.
        if (path.len == 0 or !std.fs.path.isAbsolute(path)) return;
        for (self.roots.items) |r| if (std.mem.eql(u8, r, path)) return;
        try self.roots.append(self.gpa, try self.arena.allocator().dupe(u8, path));
    }

    fn collectRoots(self: *Index, environ: ?*const std.process.Environ.Map) !void {
        const a = self.arena.allocator();
        for (self.options.extra_dirs) |d| try self.addRoot(d);
        if (!self.options.use_standard_dirs) return;
        if (comptime builtin.os.tag == .windows) return self.collectWindowsRoots(environ);
        const home = getenv(environ, "HOME");
        if (builtin.os.tag == .macos) {
            // The three NSFontManager domains (user, local, system; Supplemental/ is below
            // System). Fonts downloaded on demand under /System/Library/AssetsV2 are not
            // scanned (their layout is private), nor is the Network domain.
            if (home) |h| try self.addRoot(try std.fmt.allocPrint(a, "{s}/Library/Fonts", .{h}));
            try self.addRoot("/Library/Fonts");
            try self.addRoot("/System/Library/Fonts");
            return;
        }
        if (getenv(environ, "XDG_DATA_HOME")) |x| {
            try self.addRoot(try std.fmt.allocPrint(a, "{s}/fonts", .{x}));
        } else if (home) |h| {
            try self.addRoot(try std.fmt.allocPrint(a, "{s}/.local/share/fonts", .{h}));
        }
        if (home) |h| {
            try self.addRoot(try std.fmt.allocPrint(a, "{s}/.local/share/fonts", .{h}));
            try self.addRoot(try std.fmt.allocPrint(a, "{s}/.fonts", .{h}));
        }
        const data_dirs = getenv(environ, "XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
        var it = std.mem.tokenizeScalar(u8, data_dirs, ':');
        while (it.next()) |d| try self.addRoot(try std.fmt.allocPrint(a, "{s}/fonts", .{std.mem.trimEnd(u8, d, "/")}));
        try self.addRoot("/usr/share/fonts");
        try self.addRoot("/usr/local/share/fonts");
    }

    /// Windows: the system font directory (%WINDIR%\Fonts, i.e. C:\Windows\Fonts) and the
    /// per-user one fonts installed "for me only" go to (%LOCALAPPDATA%\Microsoft\Windows\Fonts).
    /// Font files there are flat, so `max_depth` is irrelevant.
    fn collectWindowsRoots(self: *Index, environ: ?*const std.process.Environ.Map) !void {
        const a = self.arena.allocator();
        const windir = getenv(environ, "WINDIR") orelse getenv(environ, "SystemRoot") orelse "C:\\Windows";
        try self.addRoot(try std.fmt.allocPrint(a, "{s}\\Fonts", .{std.mem.trimEnd(u8, windir, "\\/")}));
        if (getenv(environ, "LOCALAPPDATA")) |l|
            try self.addRoot(try std.fmt.allocPrint(a, "{s}\\Microsoft\\Windows\\Fonts", .{std.mem.trimEnd(u8, l, "\\/")}));
    }

    fn cachePath(self: *Index, environ: ?*const std.process.Environ.Map) !?[]const u8 {
        if (self.options.cache_path) |p| return p;
        const a = self.arena.allocator();
        if (comptime builtin.os.tag == .windows) {
            const l = getenv(environ, "LOCALAPPDATA") orelse return null;
            return try std.fmt.allocPrint(a, "{s}\\palette\\fonts-v1.bin", .{std.mem.trimEnd(u8, l, "\\/")});
        }
        if (getenv(environ, "XDG_CACHE_HOME")) |x| return try std.fmt.allocPrint(a, "{s}/palette/fonts-v1.bin", .{x});
        if (getenv(environ, "HOME")) |h| {
            const sub = if (builtin.os.tag == .macos) "Library/Caches" else ".cache";
            return try std.fmt.allocPrint(a, "{s}/{s}/palette/fonts-v1.bin", .{ h, sub });
        }
        return null;
    }

    // -- scanning ------------------------------------------------------------------------------

    fn scan(self: *Index) !void {
        var path_buf: std.ArrayList(u8) = .empty;
        defer path_buf.deinit(self.gpa);
        var hdr_buf: std.ArrayList(u8) = .empty;
        defer hdr_buf.deinit(self.gpa);
        for (self.roots.items) |root| {
            path_buf.clearRetainingCapacity();
            try path_buf.appendSlice(self.gpa, root);
            self.scanDir(&path_buf, &hdr_buf, 0) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => {},
            };
        }
    }

    fn statMtime(self: *Index, path: []const u8) ?i96 {
        var d = Dir.openDirAbsolute(self.io, path, .{}) catch return null;
        defer d.close(self.io);
        const st = d.stat(self.io) catch return null;
        return st.mtime.nanoseconds;
    }

    fn scanDir(self: *Index, path: *std.ArrayList(u8), scratch: *std.ArrayList(u8), depth: u8) !void {
        if (depth > self.options.max_depth) return;
        const io = self.io;
        var dir = Dir.openDirAbsolute(io, path.items, .{ .iterate = true }) catch return;
        defer dir.close(io);
        const st = dir.stat(io) catch return;
        // Avoid rescanning a directory reached twice (symlinks).
        for (self.dirs.items) |d| if (std.mem.eql(u8, d.path, path.items)) return;
        try self.dirs.append(self.gpa, .{ .path = try self.arena.allocator().dupe(u8, path.items), .mtime = st.mtime.nanoseconds });
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            const base_len = path.items.len;
            defer path.shrinkRetainingCapacity(base_len);
            try path.append(self.gpa, '/');
            try path.appendSlice(self.gpa, entry.name);
            var kind = entry.kind;
            if (kind == .sym_link or kind == .unknown) {
                const s = dir.statFile(io, entry.name, .{}) catch continue;
                kind = s.kind;
            }
            switch (kind) {
                .directory => try self.scanDir(path, scratch, depth + 1),
                .file => if (isFontFile(entry.name)) self.indexFile(dir, entry.name, path.items, scratch) catch |e| switch (e) {
                    error.OutOfMemory => return e,
                    else => {},
                },
                else => {},
            }
        }
    }

    fn isFontFile(name: []const u8) bool {
        const exts = [_][]const u8{ ".ttf", ".otf", ".ttc", ".otc" };
        for (exts) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
        return false;
    }

    fn readAt(io: Io, file: Io.File, buf: []u8, off: u64) !void {
        const n = try file.readPositionalAll(io, buf, off);
        if (n != buf.len) return error.InvalidFont;
    }

    fn indexFile(self: *Index, dir: Dir, name: []const u8, full_path: []const u8, scratch: *std.ArrayList(u8)) !void {
        const io = self.io;
        const file = try dir.openFile(io, name, .{});
        defer file.close(io);
        var head: [12]u8 = undefined;
        try readAt(io, file, &head, 0);
        var offsets_buf: [256]u32 = undefined;
        var offsets: []u32 = offsets_buf[0..1];
        offsets[0] = 0;
        if (std.mem.eql(u8, head[0..4], "ttcf")) {
            const n = std.mem.readInt(u32, head[8..12], .big);
            if (n == 0) return;
            const take = @min(n, offsets_buf.len);
            var raw: [256 * 4]u8 = undefined;
            try readAt(io, file, raw[0 .. take * 4], 12);
            for (0..take) |i| offsets_buf[i] = std.mem.readInt(u32, raw[i * 4 ..][0..4], .big);
            offsets = offsets_buf[0..take];
        }
        var path_index: ?u32 = null;
        for (offsets, 0..) |off, face_index| {
            const entry = self.readFace(io, file, off, scratch) catch continue;
            if (path_index == null) {
                path_index = @intCast(self.paths.items.len);
                try self.paths.append(self.gpa, try self.arena.allocator().dupe(u8, full_path));
            }
            var e = entry;
            e.path_index = path_index.?;
            e.face_index = @intCast(face_index);
            try self.entries.append(self.gpa, e);
        }
    }

    fn readFace(self: *Index, io: Io, file: Io.File, off: u32, scratch: *std.ArrayList(u8)) !Entry {
        var hdr: [12]u8 = undefined;
        try readAt(io, file, &hdr, off);
        const n_tables = std.mem.readInt(u16, hdr[4..6], .big);
        if (n_tables == 0 or n_tables > 512) return error.InvalidFont;
        var dir_buf: [512 * 16]u8 = undefined;
        const dir = dir_buf[0 .. @as(usize, n_tables) * 16];
        try readAt(io, file, dir, off + 12);
        const Want = struct { tag: sfnt.Tag, off: u32 = 0, len: u32 = 0 };
        var want = [_]Want{ .{ .tag = sfnt.tag("name") }, .{ .tag = sfnt.tag("OS/2") }, .{ .tag = sfnt.tag("post") }, .{ .tag = sfnt.tag("head") } };
        var outlines = false;
        // Apple's sbix colour bitmaps (Apple Color Emoji) are not rendered; such fonts carry
        // empty glyf outlines, so they must not win codepoint fallback.
        var sbix = false;
        for (0..n_tables) |i| {
            const rec = dir[i * 16 ..][0..16];
            const t = std.mem.readInt(u32, rec[0..4], .big);
            if (t == sfnt.tag("glyf") or t == sfnt.tag("CFF ") or t == sfnt.tag("CFF2")) outlines = true;
            if (t == sfnt.tag("sbix")) sbix = true;
            for (&want) |*w| if (w.tag == t) {
                w.off = std.mem.readInt(u32, rec[8..12], .big);
                w.len = std.mem.readInt(u32, rec[12..16], .big);
            };
        }
        if (want[0].len == 0 or want[0].len > 1 << 20) return error.InvalidFont;
        var total: usize = 0;
        for (want) |w| total += @min(w.len, 1 << 20);
        try scratch.resize(self.gpa, total);
        var tables: [4][]const u8 = undefined;
        var p: usize = 0;
        for (want, 0..) |w, i| {
            const l = @min(w.len, 1 << 20);
            const dst = scratch.items[p..][0..l];
            if (l > 0) readAt(io, file, dst, w.off) catch {
                tables[i] = &.{};
                continue;
            };
            tables[i] = dst;
            p += l;
        }
        const a = self.arena.allocator();
        var nb: [256]u8 = undefined;
        const fam16 = sfnt.nameString(tables[0], .typographic_family, &nb);
        const family = try a.dupe(u8, fam16 orelse sfnt.nameString(tables[0], .family, &nb) orelse return error.InvalidFont);
        const legacy = if (fam16 != null) try a.dupe(u8, sfnt.nameString(tables[0], .family, &nb) orelse family) else family;
        const style = try a.dupe(u8, sfnt.nameString(tables[0], .typographic_subfamily, &nb) orelse sfnt.nameString(tables[0], .subfamily, &nb) orelse "Regular");
        const os2 = sfnt.Os2.parse(tables[1]);
        const post = sfnt.Post.parse(tables[2]);
        const mac_style: u16 = if (tables[3].len >= 46) std.mem.readInt(u16, tables[3][44..46], .big) else 0;
        var weight: u16 = if (os2.present and os2.weight_class >= 1 and os2.weight_class <= 1000) os2.weight_class else if (mac_style & 1 != 0) 700 else 400;
        // Some old fonts use 1..9 weight classes.
        if (weight < 10) weight *= 100;
        const italic = if (os2.present) os2.fs_selection & (sfnt.Os2.fs_italic | sfnt.Os2.fs_oblique) != 0 else mac_style & 2 != 0;
        const mono = post.is_fixed_pitch or os2.panose_proportion == 9;
        return .{
            .family = family,
            .legacy_family = legacy,
            .style = style,
            .path_index = 0,
            .face_index = 0,
            .weight = weight,
            .italic = italic,
            .monospace = mono,
            .outlines = outlines and !sbix,
        };
    }

    // -- cache ---------------------------------------------------------------------------------

    fn loadCache(self: *Index, path: []const u8) !bool {
        const io = self.io;
        const bytes = Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(64 << 20)) catch return false;
        defer self.gpa.free(bytes);
        var r: CacheReader = .{ .b = bytes };
        if (!std.mem.eql(u8, try r.take(cache_magic.len), cache_magic)) return false;
        const a = self.arena.allocator();
        // Roots must match exactly (same order).
        const n_roots = try r.int(u32);
        if (n_roots != self.roots.items.len) return false;
        for (self.roots.items) |root| {
            if (!std.mem.eql(u8, try r.str(), root)) return false;
            const mt = try r.int(i128);
            const now = self.statMtime(root) orelse -1;
            if (mt != now) return false;
        }
        const n_dirs = try r.int(u32);
        for (0..n_dirs) |_| {
            const p = try r.str();
            const mt = try r.int(i128);
            const now = self.statMtime(p) orelse return false;
            if (now != mt) return false;
            try self.dirs.append(self.gpa, .{ .path = try a.dupe(u8, p), .mtime = @intCast(mt) });
        }
        const n_paths = try r.int(u32);
        for (0..n_paths) |_| try self.paths.append(self.gpa, try a.dupe(u8, try r.str()));
        const n_entries = try r.int(u32);
        for (0..n_entries) |_| {
            const fam = try a.dupe(u8, try r.str());
            const legacy_raw = try r.str();
            const legacy = if (std.mem.eql(u8, legacy_raw, fam)) fam else try a.dupe(u8, legacy_raw);
            const style = try a.dupe(u8, try r.str());
            const pi = try r.int(u32);
            if (pi >= self.paths.items.len) return false;
            const fi = try r.int(u16);
            const w = try r.int(u16);
            const flags = try r.int(u8);
            try self.entries.append(self.gpa, .{
                .family = fam,
                .legacy_family = legacy,
                .style = style,
                .path_index = pi,
                .face_index = fi,
                .weight = w,
                .italic = flags & 1 != 0,
                .monospace = flags & 2 != 0,
                .outlines = flags & 4 != 0,
            });
        }
        return true;
    }

    fn saveCache(self: *Index, path: []const u8) !void {
        const io = self.io;
        const gpa = self.gpa;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        const W = struct {
            fn int(o: *std.ArrayList(u8), g: std.mem.Allocator, comptime T: type, v: T) !void {
                var b: [@sizeOf(T)]u8 = undefined;
                std.mem.writeInt(T, &b, v, .little);
                try o.appendSlice(g, &b);
            }
            fn str(o: *std.ArrayList(u8), g: std.mem.Allocator, s: []const u8) !void {
                try int(o, g, u16, @intCast(@min(s.len, 0xFFFF)));
                try o.appendSlice(g, s[0..@min(s.len, 0xFFFF)]);
            }
        };
        try out.appendSlice(gpa, cache_magic);
        try W.int(&out, gpa, u32, @intCast(self.roots.items.len));
        for (self.roots.items) |root| {
            try W.str(&out, gpa, root);
            try W.int(&out, gpa, i128, self.statMtime(root) orelse -1);
        }
        try W.int(&out, gpa, u32, @intCast(self.dirs.items.len));
        for (self.dirs.items) |d| {
            try W.str(&out, gpa, d.path);
            try W.int(&out, gpa, i128, d.mtime);
        }
        try W.int(&out, gpa, u32, @intCast(self.paths.items.len));
        for (self.paths.items) |p| try W.str(&out, gpa, p);
        try W.int(&out, gpa, u32, @intCast(self.entries.items.len));
        for (self.entries.items) |e| {
            try W.str(&out, gpa, e.family);
            try W.str(&out, gpa, e.legacy_family);
            try W.str(&out, gpa, e.style);
            try W.int(&out, gpa, u32, e.path_index);
            try W.int(&out, gpa, u16, e.face_index);
            try W.int(&out, gpa, u16, e.weight);
            try W.int(&out, gpa, u8, @as(u8, @intFromBool(e.italic)) | (@as(u8, @intFromBool(e.monospace)) << 1) | (@as(u8, @intFromBool(e.outlines)) << 2));
        }
        const dir_name = std.fs.path.dirname(path) orelse return;
        Dir.cwd().createDirPath(io, dir_name) catch {};
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
        try Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = out.items });
        try Dir.rename(Dir.cwd(), tmp, Dir.cwd(), path, io);
    }

    // -- matching ------------------------------------------------------------------------------

    const generic_sans = [_][]const u8{ "Noto Sans", "DejaVu Sans", "Adwaita Sans", "Cantarell", "Liberation Sans", "Roboto", "Inter", "Segoe UI", "Arial", "Helvetica" };
    const generic_serif = [_][]const u8{ "Noto Serif", "DejaVu Serif", "Liberation Serif", "Times New Roman", "C059" };
    const generic_mono = [_][]const u8{ "JetBrains Mono", "Noto Sans Mono", "DejaVu Sans Mono", "Adwaita Mono", "Liberation Mono", "Source Code Pro", "Cascadia Mono", "Hack", "Consolas", "Courier New" };
    const generic_emoji = [_][]const u8{ "Noto Emoji", "Noto Color Emoji", "Twemoji", "Segoe UI Emoji" };

    fn genericList(family: []const u8, monospace: bool) ?[]const []const u8 {
        if (family.len == 0) return if (monospace) &generic_mono else &generic_sans;
        if (eqlFamily(family, "sans-serif") or eqlFamily(family, "sans") or eqlFamily(family, "system-ui") or eqlFamily(family, "ui-sans-serif")) return &generic_sans;
        if (eqlFamily(family, "serif") or eqlFamily(family, "ui-serif")) return &generic_serif;
        if (eqlFamily(family, "monospace") or eqlFamily(family, "mono") or eqlFamily(family, "ui-monospace")) return &generic_mono;
        if (eqlFamily(family, "emoji")) return &generic_emoji;
        return null;
    }

    /// Case-insensitive comparison ignoring spaces, '-' and '_'.
    pub fn eqlFamily(a: []const u8, b: []const u8) bool {
        var i: usize = 0;
        var j: usize = 0;
        while (true) {
            while (i < a.len and isSep(a[i])) i += 1;
            while (j < b.len and isSep(b[j])) j += 1;
            if (i == a.len or j == b.len) return i == a.len and j == b.len;
            if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
            i += 1;
            j += 1;
        }
    }
    fn isSep(c: u8) bool {
        return c == ' ' or c == '-' or c == '_';
    }

    /// Like `eqlFamily` but true when `prefix` is a (separator-insensitive) prefix of `s`.
    pub fn familyHasPrefix(s: []const u8, prefix: []const u8) bool {
        var i: usize = 0;
        var j: usize = 0;
        while (true) {
            while (i < s.len and isSep(s[i])) i += 1;
            while (j < prefix.len and isSep(prefix[j])) j += 1;
            if (j == prefix.len) return true;
            if (i == s.len) return false;
            if (std.ascii.toLower(s[i]) != std.ascii.toLower(prefix[j])) return false;
            i += 1;
            j += 1;
        }
    }

    fn familyScore(e: *const Entry, family: []const u8, generic: ?[]const []const u8) i32 {
        if (generic) |list| {
            for (list, 0..) |name, rank| {
                const r = @as(i32, @intCast(rank)) * 20;
                if (eqlFamily(e.family, name)) return 800 - r;
                // "JetBrains Mono" also accepts "JetBrainsMono Nerd Font".
                if (familyHasPrefix(e.family, name)) return 700 - r;
            }
            // Any face of the right kind is better than nothing.
            const want_mono = list.ptr == &generic_mono;
            if (want_mono) return if (e.monospace) 300 else 0;
            if (list.ptr == &generic_emoji) return 0;
            return if (!e.monospace) 100 else 50;
        }
        if (eqlFamily(e.family, family)) return 1000;
        if (eqlFamily(e.legacy_family, family)) return 950;
        if (familyHasPrefix(e.family, family) or familyHasPrefix(e.legacy_family, family)) return 600;
        return 0;
    }

    pub fn score(e: *const Entry, q: api.SystemQuery, generic: ?[]const []const u8) i32 {
        const fs = familyScore(e, q.family, generic);
        if (fs == 0) return 0;
        var s: i32 = fs;
        const dw = @as(i32, e.weight) - @as(i32, q.weight);
        // CSS-like: for light/regular requests prefer lighter, for bold prefer heavier.
        const penalty = if ((q.weight >= 500 and dw < 0) or (q.weight < 500 and dw > 0)) @divTrunc(@as(i32, @intCast(@abs(dw))), 8) else @divTrunc(@as(i32, @intCast(@abs(dw))), 10);
        s -= penalty;
        if (e.italic != q.italic) s -= 120;
        if (q.monospace and !e.monospace) s -= 200;
        if (!e.outlines) s -= 400;
        return @max(s, 1);
    }

    pub fn match(self: *const Index, q: api.SystemQuery) ?Match {
        const generic = genericList(q.family, q.monospace);
        var best: ?*const Entry = null;
        var best_score: i32 = 0;
        for (self.entries.items) |*e| {
            const s = score(e, q, generic);
            if (s > best_score) {
                best_score = s;
                best = e;
            }
        }
        // Unknown family: fall back to the generic list for the query's monospace flag.
        if (best == null and generic == null) {
            var q2 = q;
            q2.family = "";
            return self.match(q2);
        }
        const e = best orelse return null;
        return .{ .path = self.paths.items[e.path_index], .face_index = e.face_index, .entry = e, .score = best_score };
    }

    // -- codepoint fallback --------------------------------------------------------------------

    /// Fallback probing order, by tier: broad-coverage UI faces, then script-specific
    /// "Noto Sans <Script>" faces, then everything else, then symbol/math/emoji/icon faces (these
    /// cover stray Latin/Arabic code points and must not shadow real text faces).
    const primary_fallback = [_][]const u8{ "Noto Sans", "DejaVu Sans", "Liberation Sans", "Adwaita Sans", "Cantarell", "Noto Sans CJK SC" };
    const late_fallback = [_][]const u8{ "Noto Sans Symbols", "Noto Sans Symbols 2", "Noto Sans Math", "Noto Emoji", "Symbols Nerd Font", "Segoe UI Symbol", "Cambria Math", "Segoe UI Emoji" };

    fn fallbackTier(e: *const Entry) usize {
        for (primary_fallback, 0..) |name, k| if (eqlFamily(e.family, name)) return k;
        const base = primary_fallback.len;
        for (late_fallback, 0..) |name, k| if (eqlFamily(e.family, name)) return base + 3 + k;
        const lateish = [_][]const u8{ "Symbol", "Math", "Emoji", "Nerd", "Icon", "Awesome", "Codicon", "Dingbat" };
        for (lateish) |w| if (std.ascii.indexOfIgnoreCase(e.family, w) != null) return base + 3 + late_fallback.len;
        if (e.monospace) return base + 2;
        if (familyHasPrefix(e.family, "Noto Sans")) return base;
        return base + 1;
    }

    fn buildFallbackOrder(self: *Index) ![]u32 {
        const gpa = self.gpa;
        // One representative per family: outlines, closest to regular upright.
        var reps: std.ArrayList(u32) = .empty;
        defer reps.deinit(gpa);
        outer: for (self.entries.items, 0..) |*e, i| {
            if (!e.outlines) continue;
            for (reps.items) |*r| {
                const cur = &self.entries.items[r.*];
                if (std.mem.eql(u8, cur.family, e.family)) {
                    if (repRank(e) < repRank(cur)) r.* = @intCast(i);
                    continue :outer;
                }
            }
            try reps.append(gpa, @intCast(i));
        }
        const Ctx = struct {
            idx: *const Index,
            fn pref(e: *const Entry) usize {
                return fallbackTier(e);
            }
            fn less(ctx: @This(), a: u32, b: u32) bool {
                const ea = &ctx.idx.entries.items[a];
                const eb = &ctx.idx.entries.items[b];
                const pa = pref(ea);
                const pb = pref(eb);
                if (pa != pb) return pa < pb;
                return std.mem.order(u8, ea.family, eb.family) == .lt;
            }
        };
        std.mem.sort(u32, reps.items, Ctx{ .idx = self }, Ctx.less);
        return reps.toOwnedSlice(gpa);
    }

    fn repRank(e: *const Entry) u32 {
        return @as(u32, @intCast(@abs(@as(i32, e.weight) - 400))) + (if (e.italic) @as(u32, 1000) else 0);
    }

    /// Finds an installed face whose cmap covers `cp`. Lazy and cached (positive and negative).
    pub fn fallbackForCodepoint(self: *Index, cp: u21) ?Match {
        if (self.fallback_cache.get(cp)) |v| {
            if (v < 0) return null;
            const e = &self.entries.items[@intCast(v)];
            return .{ .path = self.paths.items[e.path_index], .face_index = e.face_index, .entry = e, .score = 1 };
        }
        if (self.fallback_order == null) self.fallback_order = self.buildFallbackOrder() catch return null;
        var found: i32 = -1;
        for (self.fallback_order.?) |ei| {
            const c = self.cmapFor(ei) orelse continue;
            const g = c.cmap.lookup(cp);
            if (g != 0 and g < c.num_glyphs) {
                found = @intCast(ei);
                break;
            }
        }
        self.fallback_cache.put(self.gpa, cp, found) catch {};
        if (found < 0) return null;
        const e = &self.entries.items[@intCast(found)];
        return .{ .path = self.paths.items[e.path_index], .face_index = e.face_index, .entry = e, .score = 1 };
    }

    fn cmapFor(self: *Index, ei: u32) ?*CachedCmap {
        self.cmap_tick += 1;
        if (self.cmaps.getPtr(ei)) |c| {
            c.last_use = self.cmap_tick;
            return if (c.bytes.len == 0) null else c;
        }
        const loaded = self.loadCmap(ei) catch CachedCmap{ .bytes = &.{}, .cmap = .{}, .num_glyphs = 0, .last_use = 0 };
        var c = loaded;
        c.last_use = self.cmap_tick;
        while (self.cmap_bytes + c.bytes.len > self.options.fallback_cmap_budget and self.cmaps.count() > 0) self.evictOldestCmap();
        self.cmaps.put(self.gpa, ei, c) catch {
            self.gpa.free(c.bytes);
            return null;
        };
        self.cmap_bytes += c.bytes.len;
        const ptr = self.cmaps.getPtr(ei).?;
        return if (ptr.bytes.len == 0) null else ptr;
    }

    fn evictOldestCmap(self: *Index) void {
        var oldest: ?u32 = null;
        var oldest_tick: u64 = std.math.maxInt(u64);
        var it = self.cmaps.iterator();
        while (it.next()) |kv| if (kv.value_ptr.last_use < oldest_tick and kv.value_ptr.bytes.len > 0) {
            oldest_tick = kv.value_ptr.last_use;
            oldest = kv.key_ptr.*;
        };
        const k = oldest orelse return;
        const v = self.cmaps.fetchRemove(k).?.value;
        self.cmap_bytes -= v.bytes.len;
        self.gpa.free(v.bytes);
        // Keep a tombstone-free map: the entry will simply be reloaded on demand.
    }

    fn loadCmap(self: *Index, ei: u32) !CachedCmap {
        const io = self.io;
        const e = &self.entries.items[ei];
        const file = try Dir.cwd().openFile(io, self.paths.items[e.path_index], .{});
        defer file.close(io);
        var off: u64 = 0;
        var head: [16]u8 = undefined;
        try readAt(io, file, head[0..12], 0);
        if (std.mem.eql(u8, head[0..4], "ttcf")) {
            var b: [4]u8 = undefined;
            try readAt(io, file, &b, 12 + @as(u64, e.face_index) * 4);
            off = std.mem.readInt(u32, &b, .big);
            try readAt(io, file, head[0..12], off);
        }
        const n_tables = std.mem.readInt(u16, head[4..6], .big);
        if (n_tables > 512) return error.InvalidFont;
        var dir_buf: [512 * 16]u8 = undefined;
        const dir = dir_buf[0 .. @as(usize, n_tables) * 16];
        try readAt(io, file, dir, off + 12);
        var cmap_off: u32 = 0;
        var cmap_len: u32 = 0;
        var maxp_off: u32 = 0;
        for (0..n_tables) |i| {
            const rec = dir[i * 16 ..][0..16];
            const t = std.mem.readInt(u32, rec[0..4], .big);
            if (t == sfnt.tag("cmap")) {
                cmap_off = std.mem.readInt(u32, rec[8..12], .big);
                cmap_len = std.mem.readInt(u32, rec[12..16], .big);
            } else if (t == sfnt.tag("maxp")) maxp_off = std.mem.readInt(u32, rec[8..12], .big);
        }
        if (cmap_len == 0 or cmap_len > 16 << 20) return error.InvalidFont;
        var maxp: [6]u8 = undefined;
        try readAt(io, file, &maxp, maxp_off);
        const bytes = try self.gpa.alloc(u8, cmap_len);
        errdefer self.gpa.free(bytes);
        try readAt(io, file, bytes, cmap_off);
        return .{ .bytes = bytes, .cmap = sfnt.Cmap.init(bytes), .num_glyphs = std.mem.readInt(u16, maxp[4..6], .big), .last_use = 0 };
    }
};

const CacheReader = struct {
    b: []const u8,
    p: usize = 0,

    fn take(self: *CacheReader, n: usize) ![]const u8 {
        if (self.b.len - self.p < n) return error.InvalidCache;
        defer self.p += n;
        return self.b[self.p..][0..n];
    }
    fn int(self: *CacheReader, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
    fn str(self: *CacheReader) ![]const u8 {
        const n = try self.int(u16);
        return self.take(n);
    }
};
