//! Pure-Zig XKB keymap (text v1) parser and key lookup, replacing libxkbcommon for clients.
//!
//! The compositor sends the keymap that xkbcommon serialised (`xkb_keymap_get_as_string`) and
//! afterwards only *modifier masks and the effective group*: clients never run the XKB state
//! machine themselves. So this parser needs:
//!   * xkb_keycodes: key name -> keycode (+ aliases)
//!   * xkb_types: key types (modifier mask, map entries, preserve)
//!   * xkb_compatibility: interprets, only for virtual-modifier mapping and key repeat
//!   * xkb_symbols: per-key groups/levels of keysyms, explicit types, repeat, virtualMods,
//!     modifier_map
//! Actions, indicators, geometry and LED state are parsed over and ignored.
//!
//! Masks: bits 0-7 are the real modifiers (Shift, Lock, Control, Mod1-Mod5); bit 8+i is the
//! i-th virtual modifier in declaration order (the same indices xkbcommon uses, so masks sent
//! by the compositor index the same way). Every mask is "canonicalised" (virtual bits replaced
//! by their real mapping) before matching, as xkbcommon does.
//!
//! Not supported (documented): dead keys / Compose sequences (keysyms are reported, no text),
//! multiple keysyms per level (the first is used), key actions (group/mod locks are applied by
//! the compositor anyway), overlays.

const std = @import("std");
const keysym = @import("keysym.zig");
const Allocator = std.mem.Allocator;

pub const mod_shift: u32 = 1 << 0;
pub const mod_lock: u32 = 1 << 1;
pub const mod_control: u32 = 1 << 2;
pub const mod_mod1: u32 = 1 << 3;
pub const mod_mod2: u32 = 1 << 4;
pub const mod_mod3: u32 = 1 << 5;
pub const mod_mod4: u32 = 1 << 6;
pub const mod_mod5: u32 = 1 << 7;
const max_vmods = 24;

pub const Error = error{ OutOfMemory, InvalidKeymap };

const KeyGroup = struct {
    type_index: u16,
    num_levels: u8,
    syms_start: u32,
};

const Key = struct {
    groups_start: u32 = 0,
    num_groups: u8 = 0,
    repeats: bool = true,
    /// Out-of-range group handling: wrap (default), clamp, or redirect to group `redirect`.
    group_mode: enum(u2) { wrap, clamp, redirect } = .wrap,
    redirect: u8 = 0,
};

const TypeEntry = struct {
    mods: u32,
    level: u8,
    preserve: u32,
    active: bool,
};

const KeyType = struct {
    mods: u32,
    num_levels: u8,
    entries_start: u32,
    entries_len: u32,
};

/// Modifier state as sent by wl_keyboard.modifiers.
pub const State = struct {
    depressed: u32 = 0,
    latched: u32 = 0,
    locked: u32 = 0,
    group: u32 = 0,
};

pub const Lookup = struct {
    /// Keysym with modifiers applied (incl. Caps Lock transformation).
    sym: u32,
    /// Keysym at level 1 of the active group (for layout-resolved key identity).
    base_sym: u32,
    /// Real modifiers consumed by level selection.
    consumed: u32,
};

pub const Keymap = struct {
    arena: std.heap.ArenaAllocator,
    min_keycode: u32,
    keys: []Key,
    groups: []KeyGroup,
    syms: []u32,
    types: []KeyType,
    entries: []TypeEntry,
    num_vmods: u8,
    /// Real-modifier mapping of each virtual modifier.
    vmod_map: [max_vmods]u32,
    num_groups: u8,
    /// Canonical masks for the modifiers Palette reports.
    alt_mask: u32,
    super_mask: u32,
    num_lock_mask: u32,
    level3_mask: u32,

    pub fn deinit(km: *Keymap) void {
        km.arena.deinit();
    }

    /// Replaces virtual-modifier bits by their real mapping.
    pub fn canonical(km: *const Keymap, mask: u32) u32 {
        var out = mask & 0xff;
        var v = mask >> 8;
        var i: u5 = 0;
        while (v != 0) : ({
            v >>= 1;
            i += 1;
        }) {
            if (v & 1 != 0 and i < km.num_vmods) out |= km.vmod_map[i];
        }
        return out;
    }

    fn key(km: *const Keymap, keycode: u32) ?*const Key {
        if (keycode < km.min_keycode) return null;
        const i = keycode - km.min_keycode;
        if (i >= km.keys.len) return null;
        const k = &km.keys[i];
        return if (k.num_groups == 0) null else k;
    }

    fn effectiveGroup(k: *const Key, group: u32) u32 {
        if (group < k.num_groups) return group;
        return switch (k.group_mode) {
            .wrap => group % k.num_groups,
            .clamp => k.num_groups - 1,
            .redirect => if (k.redirect < k.num_groups) k.redirect else 0,
        };
    }

    /// Resolves an XKB keycode (evdev + 8) under the given state.
    pub fn lookup(km: *const Keymap, keycode: u32, state: State) Lookup {
        const k = km.key(keycode) orelse return .{ .sym = 0, .base_sym = 0, .consumed = 0 };
        const g = km.groups[k.groups_start + effectiveGroup(k, state.group)];
        const t = km.types[g.type_index];
        const mods = km.canonical(state.depressed | state.latched | state.locked);
        var level: u32 = 0;
        var preserve: u32 = 0;
        for (km.entries[t.entries_start..][0..t.entries_len]) |e| {
            if (e.active and (mods & t.mods) == e.mods) {
                level = e.level;
                preserve = e.preserve;
                break;
            }
        }
        const consumed = t.mods & ~preserve;
        var sym: u32 = if (level < g.num_levels) km.syms[g.syms_start + level] else 0;
        if (mods & mod_lock != 0 and consumed & mod_lock == 0) sym = keysym.toUpperKeysym(sym);
        const base: u32 = if (g.num_levels > 0) km.syms[g.syms_start] else 0;
        return .{ .sym = sym, .base_sym = base, .consumed = consumed };
    }

    /// Level-1 keysym of `keycode` in group `group` (no wrapping), or null.
    pub fn baseSymInGroup(km: *const Keymap, keycode: u32, group: u32) ?u32 {
        const k = km.key(keycode) orelse return null;
        if (group >= k.num_groups) return null;
        const g = km.groups[k.groups_start + group];
        return if (g.num_levels > 0) km.syms[g.syms_start] else null;
    }

    pub fn keyRepeats(km: *const Keymap, keycode: u32) bool {
        const k = km.key(keycode) orelse return false;
        return k.repeats;
    }
};

// ---------------------------------------------------------------------------------------------
// Tokenizer

const Tok = union(enum) {
    word: []const u8,
    keyname: []const u8,
    string: []const u8,
    punct: u8,
    eof,
};

const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    peeked: ?Tok = null,

    fn next(l: *Lexer) Tok {
        if (l.peeked) |t| {
            l.peeked = null;
            return t;
        }
        return l.scan();
    }

    fn peek(l: *Lexer) Tok {
        if (l.peeked == null) l.peeked = l.scan();
        return l.peeked.?;
    }

    fn scan(l: *Lexer) Tok {
        const s = l.src;
        while (l.pos < s.len) {
            const c = s[l.pos];
            if (std.ascii.isWhitespace(c)) {
                l.pos += 1;
            } else if (c == '#' or (c == '/' and l.pos + 1 < s.len and s[l.pos + 1] == '/')) {
                while (l.pos < s.len and s[l.pos] != '\n') l.pos += 1;
            } else if (c == '/' and l.pos + 1 < s.len and s[l.pos + 1] == '*') {
                const end = std.mem.indexOfPos(u8, s, l.pos + 2, "*/") orelse s.len - 2;
                l.pos = end + 2;
            } else break;
        }
        if (l.pos >= s.len) return .eof;
        const c = s[l.pos];
        if (c == '<') {
            const end = std.mem.indexOfScalarPos(u8, s, l.pos, '>') orelse s.len;
            const name = s[l.pos + 1 .. end];
            l.pos = @min(end + 1, s.len);
            return .{ .keyname = name };
        }
        if (c == '"') {
            var end = l.pos + 1;
            while (end < s.len and s[end] != '"') : (end += 1) {
                if (s[end] == '\\') end += 1;
            }
            const str = s[l.pos + 1 .. @min(end, s.len)];
            l.pos = @min(end + 1, s.len);
            return .{ .string = str };
        }
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            const start = l.pos;
            while (l.pos < s.len and (std.ascii.isAlphanumeric(s[l.pos]) or s[l.pos] == '_')) l.pos += 1;
            return .{ .word = s[start..l.pos] };
        }
        l.pos += 1;
        return .{ .punct = c };
    }

    fn isPunct(t: Tok, c: u8) bool {
        return t == .punct and t.punct == c;
    }

    fn expect(l: *Lexer, c: u8) Error!void {
        if (!isPunct(l.next(), c)) return error.InvalidKeymap;
    }

    fn accept(l: *Lexer, c: u8) bool {
        if (isPunct(l.peek(), c)) {
            _ = l.next();
            return true;
        }
        return false;
    }

    /// Skips to the end of the current statement (`;` at nesting depth 0), consuming it.
    fn skipStatement(l: *Lexer) void {
        var depth: usize = 0;
        while (true) {
            const t = l.next();
            switch (t) {
                .eof => return,
                .punct => |p| switch (p) {
                    '{', '[', '(' => depth += 1,
                    '}', ']', ')' => {
                        if (depth == 0) {
                            l.peeked = t; // let the caller see the closing brace
                            return;
                        }
                        depth -= 1;
                    },
                    ';' => if (depth == 0) return,
                    else => {},
                },
                else => {},
            }
        }
    }

    /// Skips a balanced group whose opening token was already consumed.
    fn skipBalanced(l: *Lexer, open: u8) void {
        const close: u8 = switch (open) {
            '{' => '}',
            '[' => ']',
            else => ')',
        };
        var depth: usize = 1;
        while (depth > 0) {
            const t = l.next();
            switch (t) {
                .eof => return,
                .punct => |p| {
                    if (p == open) depth += 1;
                    if (p == close) depth -= 1;
                },
                else => {},
            }
        }
    }
};

fn parseNumber(w: []const u8) ?u32 {
    if (w.len > 2 and w[0] == '0' and (w[1] == 'x' or w[1] == 'X')) return std.fmt.parseInt(u32, w[2..], 16) catch null;
    for (w) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, w, 10) catch null;
}

// ---------------------------------------------------------------------------------------------
// Parser (builds temporary structures, then the compact Keymap)

const PType = struct {
    name: []const u8,
    mods: u32 = 0,
    num_levels: u8 = 1,
    entries: std.ArrayList(PEntry) = .empty,
};

const PEntry = struct { mods: u32, level: u8, preserve: u32 = 0 };

const PGroup = struct {
    syms: std.ArrayList(u32) = .empty,
    type_name: ?[]const u8 = null,
};

const PKey = struct {
    keycode: u32,
    groups: [4]PGroup = .{ .{}, .{}, .{}, .{} },
    num_groups: u8 = 0,
    repeat: ?bool = null,
    vmods: ?u32 = null,
    modmap: u8 = 0,
    group_mode: @FieldType(Key, "group_mode") = .wrap,
    redirect: u8 = 0,
};

const Predicate = enum { any_of_or_none, any_of, none_of, all_of, exactly };

const PInterp = struct {
    sym: ?u32, // null = Any
    pred: Predicate = .any_of_or_none,
    mods: u32 = 0xff,
    vmod: ?u8 = null,
    level_one_only: bool = false,
    repeat: bool = false,
};

const Parser = struct {
    a: Allocator,
    lex: Lexer,
    keycodes: std.StringHashMapUnmanaged(u32) = .empty,
    min_keycode: u32 = 8,
    max_keycode: u32 = 255,
    vmod_names: [max_vmods][]const u8 = undefined,
    vmod_explicit: [max_vmods]?u32 = @splat(null),
    num_vmods: u8 = 0,
    types: std.ArrayList(PType) = .empty,
    interps: std.ArrayList(PInterp) = .empty,
    interp_default_repeat: bool = false,
    interp_default_level_one: bool = false,
    keys: std.AutoArrayHashMapUnmanaged(u32, PKey) = .empty,
    modmaps: std.ArrayList(struct { mod: u8, target: Tok }) = .empty,

    fn vmodIndex(p: *Parser, name: []const u8, declare: bool) ?u8 {
        for (p.vmod_names[0..p.num_vmods], 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, name)) return @intCast(i);
        if (!declare or p.num_vmods == max_vmods) return null;
        p.vmod_names[p.num_vmods] = name;
        p.num_vmods += 1;
        return p.num_vmods - 1;
    }

    fn realModIndex(name: []const u8) ?u3 {
        const names = [_][]const u8{ "Shift", "Lock", "Control", "Mod1", "Mod2", "Mod3", "Mod4", "Mod5" };
        for (names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, name)) return @intCast(i);
        if (std.ascii.eqlIgnoreCase(name, "Ctrl")) return 2;
        return null;
    }

    /// Parses `none | all | Name(+Name)* | number`, returning a raw (uncanonicalised) mask.
    fn modExpr(p: *Parser) Error!u32 {
        var mask: u32 = 0;
        while (true) {
            const t = p.lex.next();
            switch (t) {
                .word => |w| {
                    if (std.ascii.eqlIgnoreCase(w, "none")) {} else if (std.ascii.eqlIgnoreCase(w, "all")) {
                        mask |= 0xff | (((@as(u32, 1) << @intCast(p.num_vmods)) - 1) << 8);
                    } else if (parseNumber(w)) |n| {
                        mask |= n;
                    } else if (realModIndex(w)) |i| {
                        mask |= @as(u32, 1) << i;
                    } else if (p.vmodIndex(w, true)) |i| {
                        mask |= @as(u32, 1) << @intCast(8 + @as(u32, i));
                    }
                },
                else => return error.InvalidKeymap,
            }
            if (!p.lex.accept('+') and !p.lex.accept('|')) return mask;
        }
    }

    fn level(p: *Parser) Error!u8 {
        const t = p.lex.next();
        if (t != .word) return error.InvalidKeymap;
        var w = t.word;
        if (std.ascii.startsWithIgnoreCase(w, "level")) w = w[5..];
        const n = parseNumber(w) orelse return error.InvalidKeymap;
        if (n == 0 or n > 255) return error.InvalidKeymap;
        return @intCast(n - 1);
    }

    /// `[N]` or `[GroupN]` index, 0-based.
    fn groupIndex(p: *Parser) Error!u8 {
        try p.lex.expect('[');
        const t = p.lex.next();
        if (t != .word) return error.InvalidKeymap;
        var w = t.word;
        if (std.ascii.startsWithIgnoreCase(w, "group")) w = w[5..];
        const n = parseNumber(w) orelse return error.InvalidKeymap;
        try p.lex.expect(']');
        if (n == 0 or n > 4) return error.InvalidKeymap;
        return @intCast(n - 1);
    }

    fn virtualModifiers(p: *Parser) Error!void {
        while (true) {
            const t = p.lex.next();
            if (t != .word) return error.InvalidKeymap;
            const idx = p.vmodIndex(t.word, true);
            if (p.lex.accept('=')) {
                const m = try p.modExpr();
                if (idx) |i| p.vmod_explicit[i] = m;
            }
            if (p.lex.accept(';')) return;
            try p.lex.expect(',');
        }
    }

    fn keymap(p: *Parser) Error!void {
        // Optional `xkb_keymap [flags] ["name"] {`. Sections may also appear at top level.
        var t = p.lex.next();
        var wrapped = false;
        if (t == .word and std.mem.eql(u8, t.word, "xkb_keymap")) {
            while (true) {
                t = p.lex.next();
                if (Lexer.isPunct(t, '{')) break;
                if (t == .eof) return error.InvalidKeymap;
            }
            wrapped = true;
            t = p.lex.next();
        }
        while (true) {
            switch (t) {
                .eof => return,
                .punct => |c| {
                    if (c == '}' and wrapped) return;
                },
                .word => |w| try p.section(w),
                else => {},
            }
            t = p.lex.next();
        }
    }

    fn section(p: *Parser, kind: []const u8) Error!void {
        // Skip flags/name up to `{`.
        while (true) {
            const t = p.lex.next();
            if (Lexer.isPunct(t, '{')) break;
            if (t == .eof) return error.InvalidKeymap;
        }
        while (true) {
            const t = p.lex.next();
            switch (t) {
                .eof => return error.InvalidKeymap,
                .punct => |c| {
                    if (c == '}') {
                        _ = p.lex.accept(';');
                        return;
                    }
                    if (c != ';') p.lex.skipStatement();
                },
                .keyname => |n| {
                    if (std.mem.eql(u8, kind, "xkb_keycodes")) try p.keycodeDef(n) else p.lex.skipStatement();
                },
                .word => |w| {
                    if (std.mem.eql(u8, kind, "xkb_keycodes")) {
                        try p.keycodesStatement(w);
                    } else if (std.mem.eql(u8, kind, "xkb_types")) {
                        try p.typesStatement(w);
                    } else if (std.mem.startsWith(u8, kind, "xkb_compat")) {
                        try p.compatStatement(w);
                    } else if (std.mem.eql(u8, kind, "xkb_symbols")) {
                        try p.symbolsStatement(w);
                    } else p.lex.skipStatement();
                },
                .string => p.lex.skipStatement(),
            }
        }
    }

    // -- xkb_keycodes --

    fn keycodeDef(p: *Parser, name: []const u8) Error!void {
        try p.lex.expect('=');
        const t = p.lex.next();
        if (t != .word) return error.InvalidKeymap;
        const code = parseNumber(t.word) orelse return error.InvalidKeymap;
        try p.keycodes.put(p.a, name, code);
        try p.lex.expect(';');
    }

    fn keycodesStatement(p: *Parser, w: []const u8) Error!void {
        if (std.mem.eql(u8, w, "alias")) {
            const a = p.lex.next();
            try p.lex.expect('=');
            const b = p.lex.next();
            try p.lex.expect(';');
            if (a == .keyname and b == .keyname) {
                if (p.keycodes.get(b.keyname)) |code| try p.keycodes.put(p.a, a.keyname, code);
            }
        } else if (std.mem.eql(u8, w, "minimum") or std.mem.eql(u8, w, "maximum")) {
            try p.lex.expect('=');
            const t = p.lex.next();
            const n = if (t == .word) parseNumber(t.word) orelse 0 else 0;
            if (w[1] == 'i') p.min_keycode = n else p.max_keycode = n;
            try p.lex.expect(';');
        } else p.lex.skipStatement();
    }

    // -- xkb_types --

    fn typesStatement(p: *Parser, w: []const u8) Error!void {
        if (std.mem.eql(u8, w, "virtual_modifiers")) return p.virtualModifiers();
        if (!std.mem.eql(u8, w, "type")) return p.lex.skipStatement();
        const name_tok = p.lex.next();
        if (name_tok != .string) return error.InvalidKeymap;
        try p.lex.expect('{');
        var ty: PType = .{ .name = name_tok.string };
        while (true) {
            const t = p.lex.next();
            switch (t) {
                .punct => |c| {
                    if (c == '}') break;
                    if (c == ';') continue;
                    return error.InvalidKeymap;
                },
                .word => |field| {
                    if (std.ascii.eqlIgnoreCase(field, "modifiers")) {
                        try p.lex.expect('=');
                        ty.mods = try p.modExpr();
                        try p.lex.expect(';');
                    } else if (std.ascii.eqlIgnoreCase(field, "map")) {
                        try p.lex.expect('[');
                        const m = try p.modExpr();
                        try p.lex.expect(']');
                        try p.lex.expect('=');
                        const lvl = try p.level();
                        try p.lex.expect(';');
                        // A later map for the same mods overrides the earlier one.
                        for (ty.entries.items) |*e| {
                            if (e.mods == m) {
                                e.level = lvl;
                                break;
                            }
                        } else try ty.entries.append(p.a, .{ .mods = m, .level = lvl });
                        ty.num_levels = @max(ty.num_levels, lvl + 1);
                    } else if (std.ascii.eqlIgnoreCase(field, "preserve")) {
                        try p.lex.expect('[');
                        const m = try p.modExpr();
                        try p.lex.expect(']');
                        try p.lex.expect('=');
                        const keep = try p.modExpr();
                        try p.lex.expect(';');
                        for (ty.entries.items) |*e| {
                            if (e.mods == m) {
                                e.preserve = keep;
                                break;
                            }
                        } else try ty.entries.append(p.a, .{ .mods = m, .level = 0, .preserve = keep });
                    } else if (std.ascii.eqlIgnoreCase(field, "level_name")) {
                        // level_name[N] also declares the level count.
                        try p.lex.expect('[');
                        const lvl = try p.level();
                        try p.lex.expect(']');
                        ty.num_levels = @max(ty.num_levels, lvl + 1);
                        p.lex.skipStatement();
                    } else p.lex.skipStatement();
                },
                else => p.lex.skipStatement(),
            }
        }
        _ = p.lex.accept(';');
        try p.types.append(p.a, ty);
    }

    // -- xkb_compatibility --

    fn boolValue(p: *Parser) Error!bool {
        const t = p.lex.next();
        if (t != .word) return error.InvalidKeymap;
        const w = t.word;
        return std.ascii.eqlIgnoreCase(w, "true") or std.ascii.eqlIgnoreCase(w, "yes") or std.ascii.eqlIgnoreCase(w, "on");
    }

    fn compatStatement(p: *Parser, w: []const u8) Error!void {
        if (std.mem.eql(u8, w, "virtual_modifiers")) return p.virtualModifiers();
        if (!std.mem.eql(u8, w, "interpret")) return p.lex.skipStatement();
        if (p.lex.accept('.')) {
            // interpret.field = value;
            const f = p.lex.next();
            try p.lex.expect('=');
            if (f == .word and std.ascii.eqlIgnoreCase(f.word, "repeat")) {
                p.interp_default_repeat = try p.boolValue();
            } else if (f == .word and std.ascii.eqlIgnoreCase(f.word, "useModMapMods")) {
                const v = p.lex.next();
                p.interp_default_level_one = v == .word and std.ascii.eqlIgnoreCase(v.word, "level1");
            } else {
                p.lex.skipStatement();
                return;
            }
            try p.lex.expect(';');
            return;
        }
        var it: PInterp = .{ .sym = null, .repeat = p.interp_default_repeat, .level_one_only = p.interp_default_level_one };
        const sym_tok = p.lex.next();
        if (sym_tok != .word) return error.InvalidKeymap;
        if (!std.ascii.eqlIgnoreCase(sym_tok.word, "Any")) it.sym = symbolFromWord(sym_tok.word) orelse 0;
        if (p.lex.accept('+')) {
            const pred_tok = p.lex.next();
            if (pred_tok != .word) return error.InvalidKeymap;
            const preds = [_]struct { []const u8, Predicate }{
                .{ "AnyOfOrNone", .any_of_or_none }, .{ "AnyOf", .any_of }, .{ "NoneOf", .none_of },
                .{ "AllOf", .all_of },               .{ "Exactly", .exactly },
            };
            var matched = false;
            for (preds) |pr| if (std.ascii.eqlIgnoreCase(pred_tok.word, pr[0])) {
                it.pred = pr[1];
                matched = true;
                try p.lex.expect('(');
                it.mods = try p.modExpr();
                try p.lex.expect(')');
                break;
            };
            if (!matched) {
                // `Sym+Mods` means Exactly(Mods).
                it.pred = .exactly;
                it.mods = if (realModIndex(pred_tok.word)) |i| @as(u32, 1) << i else 0;
                while (p.lex.accept('+')) {
                    const m = p.lex.next();
                    if (m == .word) if (realModIndex(m.word)) |i| {
                        it.mods |= @as(u32, 1) << i;
                    };
                }
            }
        }
        try p.lex.expect('{');
        while (true) {
            const t = p.lex.next();
            switch (t) {
                .punct => |c| {
                    if (c == '}') break;
                    if (c != ';') p.lex.skipStatement();
                },
                .word => |field| {
                    if (std.ascii.eqlIgnoreCase(field, "virtualModifier") or std.ascii.eqlIgnoreCase(field, "virtualMod")) {
                        try p.lex.expect('=');
                        const v = p.lex.next();
                        if (v == .word) it.vmod = p.vmodIndex(v.word, true);
                        try p.lex.expect(';');
                    } else if (std.ascii.eqlIgnoreCase(field, "repeat")) {
                        try p.lex.expect('=');
                        it.repeat = try p.boolValue();
                        try p.lex.expect(';');
                    } else if (std.ascii.eqlIgnoreCase(field, "useModMapMods")) {
                        try p.lex.expect('=');
                        const v = p.lex.next();
                        it.level_one_only = v == .word and std.ascii.eqlIgnoreCase(v.word, "level1");
                        try p.lex.expect(';');
                    } else p.lex.skipStatement();
                },
                else => p.lex.skipStatement(),
            }
        }
        _ = p.lex.accept(';');
        try p.interps.append(p.a, it);
    }

    // -- xkb_symbols --

    fn symbolsStatement(p: *Parser, w: []const u8) Error!void {
        if (std.mem.eql(u8, w, "virtual_modifiers")) return p.virtualModifiers();
        if (std.mem.eql(u8, w, "key")) return p.keyDef();
        if (std.mem.eql(u8, w, "modifier_map") or std.mem.eql(u8, w, "modmap") or std.mem.eql(u8, w, "mod_map")) {
            const m = p.lex.next();
            if (m != .word) return error.InvalidKeymap;
            const mod = realModIndex(m.word) orelse {
                p.lex.skipStatement();
                return;
            };
            try p.lex.expect('{');
            while (true) {
                const t = p.lex.next();
                if (Lexer.isPunct(t, '}')) break;
                if (Lexer.isPunct(t, ',')) continue;
                if (t == .eof) return error.InvalidKeymap;
                try p.modmaps.append(p.a, .{ .mod = mod, .target = t });
            }
            _ = p.lex.accept(';');
            return;
        }
        p.lex.skipStatement();
    }

    fn symList(p: *Parser, out: *std.ArrayList(u32)) Error!void {
        // `[` already consumed.
        out.clearRetainingCapacity();
        while (true) {
            const t = p.lex.next();
            switch (t) {
                .punct => |c| switch (c) {
                    ']' => return,
                    ',' => {},
                    '{' => {
                        // Multiple keysyms per level: keep the first.
                        var first: ?u32 = null;
                        while (true) {
                            const s = p.lex.next();
                            if (Lexer.isPunct(s, '}') or s == .eof) break;
                            if (s == .word and first == null) first = symbolFromWord(s.word) orelse 0;
                        }
                        try out.append(p.a, first orelse 0);
                    },
                    else => return error.InvalidKeymap,
                },
                .word => |s| try out.append(p.a, symbolFromWord(s) orelse 0),
                .eof => return error.InvalidKeymap,
                else => {},
            }
        }
    }

    fn keyDef(p: *Parser) Error!void {
        const name = p.lex.next();
        if (name != .keyname) return error.InvalidKeymap;
        const code = p.keycodes.get(name.keyname) orelse {
            p.lex.skipStatement();
            return;
        };
        const gop = try p.keys.getOrPut(p.a, code);
        if (!gop.found_existing) gop.value_ptr.* = .{ .keycode = code };
        const k = gop.value_ptr;
        try p.lex.expect('{');
        var positional: u8 = 0;
        while (true) {
            const t = p.lex.next();
            switch (t) {
                .punct => |c| switch (c) {
                    '}' => break,
                    ',' => {},
                    '[' => {
                        if (positional < 4) {
                            try p.symList(&k.groups[positional].syms);
                            positional += 1;
                            k.num_groups = @max(k.num_groups, positional);
                        } else p.lex.skipBalanced('[');
                    },
                    else => return error.InvalidKeymap,
                },
                .word => |field| {
                    if (std.ascii.eqlIgnoreCase(field, "type")) {
                        var gi: ?u8 = null;
                        if (Lexer.isPunct(p.lex.peek(), '[')) gi = try p.groupIndex();
                        try p.lex.expect('=');
                        const s = p.lex.next();
                        if (s != .string) return error.InvalidKeymap;
                        if (gi) |g| k.groups[g].type_name = s.string else for (&k.groups) |*g| {
                            g.type_name = s.string;
                        }
                    } else if (std.ascii.eqlIgnoreCase(field, "symbols")) {
                        const g = try p.groupIndex();
                        try p.lex.expect('=');
                        try p.lex.expect('[');
                        try p.symList(&k.groups[g].syms);
                        k.num_groups = @max(k.num_groups, g + 1);
                    } else if (std.ascii.eqlIgnoreCase(field, "repeat") or std.ascii.eqlIgnoreCase(field, "repeats")) {
                        try p.lex.expect('=');
                        k.repeat = try p.boolValue();
                    } else if (std.ascii.eqlIgnoreCase(field, "virtualMods") or std.ascii.eqlIgnoreCase(field, "vmods")) {
                        try p.lex.expect('=');
                        k.vmods = (try p.modExpr()) >> 8;
                    } else if (std.ascii.eqlIgnoreCase(field, "groupsClamp")) {
                        k.group_mode = .clamp;
                    } else if (std.ascii.eqlIgnoreCase(field, "groupsWrap")) {
                        k.group_mode = .wrap;
                    } else if (std.ascii.eqlIgnoreCase(field, "groupsRedirect")) {
                        try p.lex.expect('=');
                        const g = p.lex.next();
                        if (g == .word) {
                            var gw = g.word;
                            if (std.ascii.startsWithIgnoreCase(gw, "group")) gw = gw[5..];
                            k.redirect = @intCast((parseNumber(gw) orelse 1) -| 1);
                        }
                        k.group_mode = .redirect;
                    } else {
                        // actions[N]= [...], overlay, etc.: skip the value.
                        while (true) {
                            const s = p.lex.peek();
                            if (Lexer.isPunct(s, ',') or Lexer.isPunct(s, '}') or s == .eof) break;
                            const v = p.lex.next();
                            if (v == .punct and (v.punct == '[' or v.punct == '(' or v.punct == '{')) p.lex.skipBalanced(v.punct);
                        }
                    }
                },
                else => {},
            }
        }
        _ = p.lex.accept(';');
    }

    // -- assembly --

    fn interpMatches(it: PInterp, sym: u32, modmap: u32) bool {
        if (it.sym) |s| if (s != sym) return false;
        const m = it.mods & 0xff;
        return switch (it.pred) {
            .any_of_or_none => true,
            .any_of => modmap & m != 0,
            .none_of => modmap & m == 0,
            .all_of => modmap & m == m,
            .exactly => modmap == m,
        };
    }

    fn findInterp(p: *Parser, sym: u32, modmap: u32) ?PInterp {
        // Keysym-specific interprets take precedence over `Any`.
        for (p.interps.items) |it| if (it.sym != null and interpMatches(it, sym, modmap)) return it;
        for (p.interps.items) |it| if (it.sym == null and interpMatches(it, sym, modmap)) return it;
        return null;
    }

    fn findType(p: *Parser, name: []const u8) ?usize {
        for (p.types.items, 0..) |t, i| if (std.mem.eql(u8, t.name, name)) return i;
        return null;
    }

    fn ensureType(p: *Parser, name: []const u8) Error!usize {
        if (p.findType(name)) |i| return i;
        // Built-in fallbacks for keymaps without the standard types.
        var t: PType = .{ .name = name };
        const S = mod_shift;
        const L = mod_lock;
        if (std.mem.eql(u8, name, "TWO_LEVEL")) {
            t.mods = S;
            t.num_levels = 2;
            try t.entries.append(p.a, .{ .mods = S, .level = 1 });
        } else if (std.mem.eql(u8, name, "ALPHABETIC")) {
            t.mods = S | L;
            t.num_levels = 2;
            try t.entries.append(p.a, .{ .mods = S, .level = 1 });
            try t.entries.append(p.a, .{ .mods = L, .level = 1 });
        } else if (std.mem.eql(u8, name, "KEYPAD")) {
            const nl = (@as(u32, 1) << @intCast(8 + @as(u32, p.vmodIndex("NumLock", true) orelse 0)));
            t.mods = S | nl;
            t.num_levels = 2;
            try t.entries.append(p.a, .{ .mods = S, .level = 1 });
            try t.entries.append(p.a, .{ .mods = nl, .level = 1 });
        } else if (std.mem.startsWith(u8, name, "FOUR_LEVEL")) {
            const l3 = (@as(u32, 1) << @intCast(8 + @as(u32, p.vmodIndex("LevelThree", true) orelse 0)));
            t.mods = S | l3;
            t.num_levels = 4;
            try t.entries.append(p.a, .{ .mods = S, .level = 1 });
            try t.entries.append(p.a, .{ .mods = l3, .level = 2 });
            try t.entries.append(p.a, .{ .mods = S | l3, .level = 3 });
        }
        try p.types.append(p.a, t);
        return p.types.items.len - 1;
    }

    /// xkbcomp's automatic type selection for keys without an explicit type.
    fn autoType(syms: []const u32) []const u8 {
        const s = struct {
            fn at(v: []const u32, i: usize) u32 {
                return if (i < v.len) v[i] else 0;
            }
        };
        const w = syms.len;
        if (w <= 1) return "ONE_LEVEL";
        const lower_upper = keysym.isLower(s.at(syms, 0)) and keysym.isUpper(s.at(syms, 1));
        const keypad = keysym.isKeypad(s.at(syms, 0)) or keysym.isKeypad(s.at(syms, 1));
        if (w == 2) {
            if (lower_upper) return "ALPHABETIC";
            if (keypad) return "KEYPAD";
            return "TWO_LEVEL";
        }
        if (lower_upper) {
            if (keysym.isLower(s.at(syms, 2)) and keysym.isUpper(s.at(syms, 3))) return "FOUR_LEVEL_ALPHABETIC";
            return "FOUR_LEVEL_SEMIALPHABETIC";
        }
        if (keypad) return "FOUR_LEVEL_KEYPAD";
        return "FOUR_LEVEL";
    }

    fn build(p: *Parser, gpa: Allocator) Error!Keymap {
        var km: Keymap = undefined;
        km.arena = .init(gpa);
        errdefer km.arena.deinit();
        const out = km.arena.allocator();

        // 1. Real modifier map per key.
        for (p.modmaps.items) |mm| {
            switch (mm.target) {
                .keyname => |n| if (p.keycodes.get(n)) |code| {
                    if (p.keys.getPtr(code)) |k| k.modmap |= @as(u8, 1) << @intCast(mm.mod);
                },
                .word => |w| if (symbolFromWord(w)) |sym| {
                    for (p.keys.values()) |*k| {
                        if (k.num_groups > 0 and k.groups[0].syms.items.len > 0 and k.groups[0].syms.items[0] == sym)
                            k.modmap |= @as(u8, 1) << @intCast(mm.mod);
                    }
                },
                else => {},
            }
        }

        // 2. Interprets: virtual modifier map and repeat per key.
        var vmod_map: [max_vmods]u32 = @splat(0);
        for (p.keys.values()) |*k| {
            var vmodmap: u32 = 0;
            var repeat: ?bool = null;
            for (k.groups[0..k.num_groups], 0..) |g, gi| {
                for (g.syms.items, 0..) |sym, li| {
                    if (sym == 0) continue;
                    const first = gi == 0 and li == 0;
                    const it = p.findInterp(sym, k.modmap) orelse continue;
                    if (it.level_one_only and !first) continue;
                    if (it.vmod) |v| vmodmap |= @as(u32, 1) << @intCast(v);
                    if (first) repeat = it.repeat;
                }
            }
            if (k.vmods) |v| vmodmap = v;
            for (0..p.num_vmods) |v| {
                if (vmodmap & (@as(u32, 1) << @intCast(v)) != 0) vmod_map[v] |= k.modmap;
            }
            if (k.repeat == null) {
                const base = if (k.num_groups > 0 and k.groups[0].syms.items.len > 0) k.groups[0].syms.items[0] else 0;
                k.repeat = repeat orelse !keysym.isModifier(base);
            }
        }
        for (0..p.num_vmods) |v| {
            if (p.vmod_explicit[v]) |e| vmod_map[v] = e;
        }
        km.num_vmods = p.num_vmods;
        km.vmod_map = vmod_map;

        // 3. Resolve key types (explicit or automatic) before freezing the type table.
        var key_types: std.ArrayList([4]u16) = .empty;
        for (p.keys.values()) |*k| {
            var tl: [4]u16 = .{ 0, 0, 0, 0 };
            for (k.groups[0..k.num_groups], 0..) |g, gi| {
                const name = g.type_name orelse autoType(g.syms.items);
                const idx = p.findType(name) orelse try p.ensureType(name);
                tl[gi] = @intCast(idx);
            }
            try key_types.append(p.a, tl);
        }

        // 4. Types with canonical masks.
        km.types = try out.alloc(KeyType, p.types.items.len);
        var entries: std.ArrayList(TypeEntry) = .empty;
        for (p.types.items, 0..) |t, i| {
            const start = entries.items.len;
            for (t.entries.items) |e| {
                const m = km.canonical(e.mods);
                try entries.append(out, .{
                    .mods = m & km.canonical(t.mods),
                    .level = e.level,
                    .preserve = km.canonical(e.preserve),
                    // Entries whose (virtual) mods map to nothing are disabled, unless the
                    // entry is explicitly for no modifiers.
                    .active = e.mods == 0 or m != 0,
                });
            }
            km.types[i] = .{
                .mods = km.canonical(t.mods),
                .num_levels = t.num_levels,
                .entries_start = @intCast(start),
                .entries_len = @intCast(entries.items.len - start),
            };
        }
        km.entries = entries.items;

        // 5. Keys, groups, symbols.
        var max_code: u32 = p.min_keycode;
        for (p.keys.keys()) |code| max_code = @max(max_code, code);
        km.min_keycode = p.min_keycode;
        km.keys = try out.alloc(Key, max_code - p.min_keycode + 1);
        @memset(km.keys, .{});
        var groups: std.ArrayList(KeyGroup) = .empty;
        var syms: std.ArrayList(u32) = .empty;
        var num_groups: u8 = 1;
        for (p.keys.values(), key_types.items) |*k, tl| {
            if (k.keycode < p.min_keycode) continue;
            const dst = &km.keys[k.keycode - p.min_keycode];
            dst.* = .{
                .groups_start = @intCast(groups.items.len),
                .num_groups = k.num_groups,
                .repeats = k.repeat orelse true,
                .group_mode = k.group_mode,
                .redirect = k.redirect,
            };
            num_groups = @max(num_groups, k.num_groups);
            for (k.groups[0..k.num_groups], 0..) |g, gi| {
                const n: u8 = @intCast(@min(g.syms.items.len, 255));
                try groups.append(out, .{ .type_index = tl[gi], .num_levels = n, .syms_start = @intCast(syms.items.len) });
                try syms.appendSlice(out, g.syms.items[0..n]);
            }
        }
        km.groups = groups.items;
        km.syms = syms.items;
        km.num_groups = num_groups;

        const mapping = struct {
            fn of(pp: *Parser, k: *const Keymap, name: []const u8, fallback: u32) u32 {
                if (pp.vmodIndex(name, false)) |i| {
                    if (k.vmod_map[i] != 0) return k.vmod_map[i];
                }
                return fallback;
            }
        };
        km.alt_mask = mapping.of(p, &km, "Alt", mod_mod1);
        km.super_mask = mapping.of(p, &km, "Super", mod_mod4);
        km.num_lock_mask = mapping.of(p, &km, "NumLock", mod_mod2);
        km.level3_mask = mapping.of(p, &km, "LevelThree", mod_mod5);
        return km;
    }
};

/// A keysym token from a symbols list: name, `Uxxxx`, hex, or a bare number (0-9 are the
/// digit keysyms; larger numbers are raw keysym values, as in xkbcomp).
fn symbolFromWord(w: []const u8) ?u32 {
    if (w.len == 1 and std.ascii.isDigit(w[0])) return w[0];
    if (std.mem.eql(u8, w, "NoSymbol")) return 0;
    if (std.ascii.isDigit(w[0])) {
        if (parseNumber(w)) |n| return n;
    }
    return keysym.fromName(w);
}

/// Parses keymap text (as received from wl_keyboard.keymap; a trailing NUL is fine).
pub fn parse(gpa: Allocator, text: []const u8) Error!Keymap {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const src = std.mem.sliceTo(text, 0);
    var p: Parser = .{ .a = scratch.allocator(), .lex = .{ .src = src } };
    try p.keymap();
    if (p.keys.count() == 0) return error.InvalidKeymap;
    return p.build(gpa);
}

// ---------------------------------------------------------------------------------------------

const testing = std.testing;

fn kc(evdev: u32) u32 {
    return evdev + 8;
}

const KEY_1 = 2;
const KEY_Q = 16;
const KEY_A = 30;
const KEY_C = 46;
const KEY_LEFTSHIFT = 42;
const KEY_KP7 = 71;
const KEY_TAB = 15;
const KEY_ENTER = 28;

test "real compositor keymap (Hyprland, us)" {
    const text = @embedFile("testdata/hyprland.xkb");
    var km = try parse(testing.allocator, text);
    defer km.deinit();

    try testing.expectEqual(@as(u32, 8), km.min_keycode);
    try testing.expectEqual(@as(u8, 1), km.num_groups);
    // Virtual modifier mapping derived from modifier_map + interprets.
    try testing.expectEqual(mod_mod1, km.alt_mask);
    try testing.expectEqual(mod_mod4, km.super_mask);
    try testing.expectEqual(mod_mod2, km.num_lock_mask);
    try testing.expectEqual(mod_mod5, km.level3_mask);

    const none: State = .{};
    const shift: State = .{ .depressed = mod_shift };
    const caps: State = .{ .locked = mod_lock };
    try testing.expectEqual(@as(u32, 'a'), km.lookup(kc(KEY_A), none).sym);
    try testing.expectEqual(@as(u32, 'A'), km.lookup(kc(KEY_A), shift).sym);
    try testing.expectEqual(@as(u32, 'A'), km.lookup(kc(KEY_A), caps).sym);
    // ALPHABETIC: Shift+Caps -> map entry missing -> level 1.
    try testing.expectEqual(@as(u32, 'a'), km.lookup(kc(KEY_A), .{ .depressed = mod_shift, .locked = mod_lock }).sym);
    try testing.expectEqual(@as(u32, '1'), km.lookup(kc(KEY_1), none).sym);
    try testing.expectEqual(@as(u32, '!'), km.lookup(kc(KEY_1), shift).sym);
    // Caps Lock does not affect digits (TWO_LEVEL; Lock not consumed, no case).
    try testing.expectEqual(@as(u32, '1'), km.lookup(kc(KEY_1), caps).sym);
    // Ctrl+C: Control is not part of ALPHABETIC so level 1, base keysym 'c'.
    const ctrl_c = km.lookup(kc(KEY_C), .{ .depressed = mod_control });
    try testing.expectEqual(@as(u32, 'c'), ctrl_c.sym);
    try testing.expectEqual(@as(u32, 'c'), ctrl_c.base_sym);
    // Keypad: KP_Home vs KP_7 depending on NumLock (sent as Mod2 or as the vmod bit).
    try testing.expectEqual(@as(u32, 0xff95), km.lookup(kc(KEY_KP7), none).sym);
    try testing.expectEqual(@as(u32, 0xffb7), km.lookup(kc(KEY_KP7), .{ .locked = mod_mod2 }).sym);
    try testing.expectEqual(@as(u32, 0xffb7), km.lookup(kc(KEY_KP7), .{ .locked = 1 << 8 }).sym);
    try testing.expectEqual(@as(u32, keysym.ISO_Left_Tab), km.lookup(kc(KEY_TAB), shift).sym);
    try testing.expectEqual(@as(u32, keysym.Return), km.lookup(kc(KEY_ENTER), none).sym);
    // Explicit type on <LFSH>: Shift_L, Caps_Lock at level 2 (shift:both_capslock_cancel).
    try testing.expectEqual(@as(u32, 0xffe1), km.lookup(kc(KEY_LEFTSHIFT), none).sym);
    // Repeat: letters repeat, modifiers don't (interpret.repeat= False + Any+AnyOf(all)).
    try testing.expect(km.keyRepeats(kc(KEY_A)));
    try testing.expect(!km.keyRepeats(kc(KEY_LEFTSHIFT)));
    try testing.expect(!km.keyRepeats(kc(29))); // LEFTCTRL
    try testing.expect(km.keyRepeats(kc(KEY_KP7)));
    // Unknown keycodes are harmless.
    try testing.expectEqual(@as(u32, 0), km.lookup(5000, none).sym);
}

test "hand-written two-group keymap" {
    const text = @embedFile("testdata/two_groups.xkb");
    var km = try parse(testing.allocator, text);
    defer km.deinit();
    try testing.expectEqual(@as(u8, 2), km.num_groups);
    const g2: State = .{ .group = 1 };
    // Group 2 (Cyrillic) on <AD01>; Shift gives uppercase; Caps too.
    try testing.expectEqual(@as(u32, 'q'), km.lookup(kc(KEY_Q), .{}).sym);
    try testing.expectEqual(@as(u32, 0x6ca), km.lookup(kc(KEY_Q), g2).sym); // Cyrillic_shorti
    try testing.expectEqual(@as(u32, 0x6ea), km.lookup(kc(KEY_Q), .{ .group = 1, .depressed = mod_shift }).sym);
    try testing.expectEqual(@as(u32, 0x6ea), km.lookup(kc(KEY_Q), .{ .group = 1, .locked = mod_lock }).sym);
    // Level-3 via AltGr (LevelThree -> Mod5), explicit FOUR_LEVEL type in group 1.
    try testing.expectEqual(@as(u32, 0x20ac), km.lookup(kc(KEY_A + 2), .{ .depressed = mod_mod5 }).sym); // <AC03> e: EuroSign
    try testing.expectEqual(@as(u32, 'd'), km.lookup(kc(KEY_A + 2), .{}).sym);
    // Unicode and hex keysym forms.
    try testing.expectEqual(@as(u32, 0x1000444), km.lookup(kc(KEY_A + 3), g2).sym);
    try testing.expectEqual(@as(u32, 0xfe50), km.lookup(kc(KEY_A + 4), .{}).sym); // dead_grave
    // A key with only one group wraps when group 2 is active.
    try testing.expectEqual(@as(u32, '1'), km.lookup(kc(KEY_1), g2).sym);
    // Base symbol in group 1 is available for shortcut fallback.
    try testing.expectEqual(@as(?u32, 'q'), km.baseSymInGroup(kc(KEY_Q), 0));
    try testing.expect(!km.keyRepeats(kc(KEY_A + 4)));
    try testing.expectEqual(mod_mod5, km.level3_mask);
}

test "malformed keymaps fail cleanly" {
    try testing.expectError(error.InvalidKeymap, parse(testing.allocator, ""));
    try testing.expectError(error.InvalidKeymap, parse(testing.allocator, "xkb_keymap { xkb_keycodes { <A> = ; }; };"));
    try testing.expectError(error.InvalidKeymap, parse(testing.allocator, "xkb_keymap { xkb_symbols { key <A> { [ a ] }; }; };"));
}
