//! Minimal Objective-C runtime binding (no headers, no SDK, no zig-objc).
//!
//! Everything is resolved at runtime: `load()` dlopens `/usr/lib/libobjc.A.dylib` plus the
//! frameworks Palette uses (Foundation, AppKit, QuartzCore, Metal) and looks up the runtime
//! entry points with dlsym. Messages go through `objc_msgSend`, cast at comptime to the exact
//! C function type of each call site (`msgSend(Return, receiver, sel, .{args...})`), so the
//! platform C ABI handles struct arguments/returns (NSRect, NSRange, NSPoint).
//!
//! arm64 has a single `objc_msgSend` for every return type. On x86_64 struct returns larger
//! than 16 bytes go through `objc_msgSend_stret` and are selected automatically.
//!
//! Classes Palette defines (views, delegates) are built with `ClassBuilder`
//! (`objc_allocateClassPair` + `class_addMethod`); methods are plain `callconv(.c)` Zig
//! functions taking `(self: Id, _cmd: SEL, args...)`.
const std = @import("std");
const builtin = @import("builtin");

pub const Object = opaque {};
pub const Id = *Object;
pub const Class = *Object;
pub const Sel = *opaque {};
pub const Protocol = opaque {};
pub const Ivar = opaque {};

/// Objective-C `BOOL`: `bool` on arm64, `signed char` on x86_64. Both are one byte holding
/// 0 or 1, so a `u8` is ABI-compatible for arguments and returns on both.
pub const BOOL = u8;
pub const YES: BOOL = 1;
pub const NO: BOOL = 0;

pub const NSInteger = isize;
pub const NSUInteger = usize;
pub const CGFloat = f64;

pub const NSPoint = extern struct { x: CGFloat = 0, y: CGFloat = 0 };
pub const NSSize = extern struct { width: CGFloat = 0, height: CGFloat = 0 };
pub const NSRect = extern struct {
    origin: NSPoint = .{},
    size: NSSize = .{},

    pub fn make(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) NSRect {
        return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
    }
};
pub const NSRange = extern struct {
    location: NSUInteger = 0,
    length: NSUInteger = 0,

    /// `NSNotFound` (`NSIntegerMax`).
    pub const not_found: NSUInteger = @as(NSUInteger, std.math.maxInt(NSInteger));
    pub const empty: NSRange = .{ .location = not_found, .length = 0 };
};

// ---- dynamic loading ----------------------------------------------------------------------

const RTLD_LAZY: c_int = 0x1;
const RTLD_GLOBAL: c_int = 0x8;
/// `RTLD_DEFAULT` on Darwin.
pub const rtld_default: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

pub extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
pub extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
pub extern "c" fn dlerror() ?[*:0]const u8;

pub const Error = error{ ObjcRuntimeUnavailable, FrameworkUnavailable, ClassUnavailable, ClassRegistrationFailed };

const Runtime = struct {
    msg_send: *const anyopaque,
    msg_send_stret: ?*const anyopaque,
    msg_send_super: *const anyopaque,
    get_class: *const fn ([*:0]const u8) callconv(.c) ?Class,
    register_name: *const fn ([*:0]const u8) callconv(.c) Sel,
    allocate_class_pair: *const fn (?Class, [*:0]const u8, usize) callconv(.c) ?Class,
    register_class_pair: *const fn (Class) callconv(.c) void,
    class_add_method: *const fn (Class, Sel, *const anyopaque, [*:0]const u8) callconv(.c) BOOL,
    class_add_ivar: *const fn (Class, [*:0]const u8, usize, u8, [*:0]const u8) callconv(.c) BOOL,
    class_add_protocol: *const fn (Class, *Protocol) callconv(.c) BOOL,
    class_get_instance_variable: *const fn (Class, [*:0]const u8) callconv(.c) ?*Ivar,
    ivar_get_offset: *const fn (*Ivar) callconv(.c) isize,
    get_protocol: *const fn ([*:0]const u8) callconv(.c) ?*Protocol,
    object_get_class: *const fn (?Id) callconv(.c) ?Class,
    pool_push: *const fn () callconv(.c) ?*anyopaque,
    pool_pop: *const fn (?*anyopaque) callconv(.c) void,
};

var rt: Runtime = undefined;
var loaded: std.atomic.Value(bool) = .init(false);
var load_lock: std.atomic.Value(u32) = .init(0);

pub const Frameworks = struct {
    foundation: ?*anyopaque = null,
    appkit: ?*anyopaque = null,
    quartz_core: ?*anyopaque = null,
    metal: ?*anyopaque = null,
    core_graphics: ?*anyopaque = null,
};
pub var frameworks: Frameworks = .{};

fn sym(handle: ?*anyopaque, name: [*:0]const u8) !*const anyopaque {
    return dlsym(handle, name) orelse error.ObjcRuntimeUnavailable;
}

/// Loads libobjc and the frameworks once (thread-safe, idempotent). AppKit is optional for
/// pure-Metal tools (offscreen rendering), so a missing AppKit is not an error here; callers
/// that need it check `frameworks.appkit`.
pub fn load() Error!void {
    if (loaded.load(.acquire)) return;
    while (load_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer load_lock.store(0, .release);
    if (loaded.load(.acquire)) return;
    if (builtin.os.tag != .macos) return error.ObjcRuntimeUnavailable;

    const lib = dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY | RTLD_GLOBAL) orelse return error.ObjcRuntimeUnavailable;
    frameworks.foundation = dlopen("/System/Library/Frameworks/Foundation.framework/Foundation", RTLD_LAZY | RTLD_GLOBAL);
    if (frameworks.foundation == null) return error.FrameworkUnavailable;
    frameworks.appkit = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY | RTLD_GLOBAL);
    frameworks.quartz_core = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY | RTLD_GLOBAL);
    frameworks.metal = dlopen("/System/Library/Frameworks/Metal.framework/Metal", RTLD_LAZY | RTLD_GLOBAL);
    frameworks.core_graphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_GLOBAL);

    rt = .{
        .msg_send = try sym(lib, "objc_msgSend"),
        .msg_send_stret = if (builtin.cpu.arch == .x86_64) try sym(lib, "objc_msgSend_stret") else null,
        .msg_send_super = try sym(lib, "objc_msgSendSuper"),
        .get_class = @ptrCast(@alignCast(try sym(lib, "objc_getClass"))),
        .register_name = @ptrCast(@alignCast(try sym(lib, "sel_registerName"))),
        .allocate_class_pair = @ptrCast(@alignCast(try sym(lib, "objc_allocateClassPair"))),
        .register_class_pair = @ptrCast(@alignCast(try sym(lib, "objc_registerClassPair"))),
        .class_add_method = @ptrCast(@alignCast(try sym(lib, "class_addMethod"))),
        .class_add_ivar = @ptrCast(@alignCast(try sym(lib, "class_addIvar"))),
        .class_add_protocol = @ptrCast(@alignCast(try sym(lib, "class_addProtocol"))),
        .class_get_instance_variable = @ptrCast(@alignCast(try sym(lib, "class_getInstanceVariable"))),
        .ivar_get_offset = @ptrCast(@alignCast(try sym(lib, "ivar_getOffset"))),
        .get_protocol = @ptrCast(@alignCast(try sym(lib, "objc_getProtocol"))),
        .object_get_class = @ptrCast(@alignCast(try sym(lib, "object_getClass"))),
        .pool_push = @ptrCast(@alignCast(try sym(lib, "objc_autoreleasePoolPush"))),
        .pool_pop = @ptrCast(@alignCast(try sym(lib, "objc_autoreleasePoolPop"))),
    };
    loaded.store(true, .release);
}

pub fn isLoaded() bool {
    return loaded.load(.acquire);
}

/// Looks up a C symbol (function or global) in any loaded image.
pub fn cSymbol(comptime T: type, name: [*:0]const u8) ?T {
    const p = dlsym(rtld_default, name) orelse return null;
    return @ptrCast(@alignCast(p));
}

/// Value of an exported `NSString *const` (e.g. `NSPasteboardTypeString`).
pub fn stringConstant(name: [*:0]const u8) ?Id {
    const p = cSymbol(*const ?Id, name) orelse return null;
    return p.*;
}

// ---- classes, selectors, messages ---------------------------------------------------------

pub fn getClass(name: [*:0]const u8) ?Class {
    return rt.get_class(name);
}

pub fn class(name: [*:0]const u8) Class {
    return rt.get_class(name) orelse std.debug.panic("objc class {s} not found", .{name});
}

pub fn sel(name: [*:0]const u8) Sel {
    return rt.register_name(name);
}

pub fn getProtocol(name: [*:0]const u8) ?*Protocol {
    return rt.get_protocol(name);
}

pub fn objectClass(obj: Id) ?Class {
    return rt.object_get_class(obj);
}

fn receiverPtr(target: anytype) ?*anyopaque {
    const T = @TypeOf(target);
    return switch (@typeInfo(T)) {
        .optional => if (target) |t| @ptrCast(t) else null,
        .null => null,
        else => @ptrCast(target),
    };
}

fn needsStret(comptime R: type) bool {
    if (builtin.cpu.arch != .x86_64) return false;
    return switch (@typeInfo(R)) {
        .@"struct" => @sizeOf(R) > 16,
        else => false,
    };
}

fn MsgFn(comptime R: type, comptime Args: type, comptime Recv: type) type {
    const fields = @typeInfo(Args).@"struct".fields;
    var params: [fields.len + 2]type = undefined;
    params[0] = Recv;
    params[1] = Sel;
    for (fields, 0..) |f, i| {
        if (f.type == comptime_int or f.type == comptime_float)
            @compileError("msgSend argument " ++ f.name ++ " must have a runtime type (use @as)");
        params[i + 2] = f.type;
    }
    const attrs: [fields.len + 2]std.builtin.Type.Fn.Param.Attributes = @splat(.{});
    return @Fn(&params, &attrs, R, .{ .@"callconv" = .c });
}

/// `[target sel args...]` returning `R`. `target` is any object/class pointer (or optional
/// one; nil messages return zero like Objective-C). Arguments must have runtime types.
pub fn msgSend(comptime R: type, target: anytype, s: Sel, args: anytype) R {
    const F = MsgFn(R, @TypeOf(args), ?*anyopaque);
    const fp: *const F = @ptrCast(@alignCast(if (comptime needsStret(R)) rt.msg_send_stret.? else rt.msg_send));
    return @call(.auto, fp, .{ receiverPtr(target), s } ++ args);
}

/// `[target name args...]` with the selector registered from a comptime string (cached by
/// the runtime; `sel_registerName` is a hash lookup).
pub fn send(comptime R: type, target: anytype, comptime name: [:0]const u8, args: anytype) R {
    return msgSend(R, target, sel(name), args);
}

pub const Super = extern struct {
    receiver: ?*anyopaque,
    super_class: Class,
};

/// `[super name args...]` from inside a method of a class whose superclass is `super_class`.
pub fn sendSuper(comptime R: type, self: Id, super_class: Class, comptime name: [:0]const u8, args: anytype) R {
    if (comptime needsStret(R)) @compileError("sendSuper with a large struct return is not supported");
    var sup: Super = .{ .receiver = @ptrCast(self), .super_class = super_class };
    const F = MsgFn(R, @TypeOf(args), *Super);
    const fp: *const F = @ptrCast(@alignCast(rt.msg_send_super));
    return @call(.auto, fp, .{ &sup, sel(name) } ++ args);
}

pub fn respondsTo(obj: anytype, comptime name: [:0]const u8) bool {
    if (receiverPtr(obj) == null) return false;
    return send(BOOL, obj, "respondsToSelector:", .{sel(name)}) != 0;
}

pub fn retain(obj: anytype) @TypeOf(obj) {
    _ = send(?Id, obj, "retain", .{});
    return obj;
}

pub fn release(obj: anytype) void {
    if (receiverPtr(obj) == null) return;
    send(void, obj, "release", .{});
}

/// `[[cls alloc] init]` (retained, +1).
pub fn new(cls: Class) Id {
    return send(?Id, cls, "new", .{}) orelse @panic("objc: +new returned nil");
}

pub fn isKindOf(obj: Id, cls: Class) bool {
    return send(BOOL, obj, "isKindOfClass:", .{cls}) != 0;
}

// ---- autorelease pools ----------------------------------------------------------------------

pub const Pool = struct {
    token: ?*anyopaque,

    pub fn push() Pool {
        return .{ .token = rt.pool_push() };
    }

    pub fn pop(self: Pool) void {
        rt.pool_pop(self.token);
    }
};

// ---- strings ----------------------------------------------------------------------------------

const NSUTF8StringEncoding: NSUInteger = 4;

/// Autoreleased NSString copy of UTF-8 bytes (invalid UTF-8 yields an empty string).
pub fn nsString(bytes: []const u8) Id {
    const cls = class("NSString");
    const s = send(?Id, send(Id, cls, "alloc", .{}), "initWithBytes:length:encoding:", .{ @as(?*const anyopaque, bytes.ptr), @as(NSUInteger, bytes.len), NSUTF8StringEncoding });
    const obj = s orelse send(Id, cls, "string", .{});
    if (s != null) _ = send(Id, obj, "autorelease", .{});
    return obj;
}

/// UTF-8 bytes of an NSString, valid until the enclosing autorelease pool drains.
pub fn utf8(str: ?Id) []const u8 {
    const s = str orelse return "";
    const p = send(?[*:0]const u8, s, "UTF8String", .{}) orelse return "";
    return std.mem.span(p);
}

/// Length in UTF-16 code units.
pub fn length(str: Id) NSUInteger {
    return send(NSUInteger, str, "length", .{});
}

// ---- class building ---------------------------------------------------------------------------

pub const ClassBuilder = struct {
    cls: Class,

    /// Starts a subclass of `super_name`. Returns null if a class called `name` already
    /// exists (registered earlier in this process); use `getClass(name)` then.
    pub fn begin(super_name: [*:0]const u8, name: [*:0]const u8) Error!?ClassBuilder {
        if (getClass(name) != null) return null;
        const sup = getClass(super_name) orelse return error.ClassUnavailable;
        const cls = rt.allocate_class_pair(sup, name, 0) orelse return error.ClassRegistrationFailed;
        return .{ .cls = cls };
    }

    /// Adds an instance method. `types` is the Objective-C type encoding, e.g. "v@:@".
    pub fn method(self: ClassBuilder, comptime name: [:0]const u8, imp: anytype, types: [*:0]const u8) void {
        _ = rt.class_add_method(self.cls, sel(name), @ptrCast(imp), types);
    }

    /// Adds a pointer-sized ivar (`void *`), read back with `ivarPtr`.
    pub fn pointerIvar(self: ClassBuilder, name: [*:0]const u8) void {
        _ = rt.class_add_ivar(self.cls, name, @sizeOf(usize), std.math.log2_int(usize, @alignOf(usize)), "^v");
    }

    pub fn protocol(self: ClassBuilder, name: [*:0]const u8) void {
        if (getProtocol(name)) |p| _ = rt.class_add_protocol(self.cls, p);
    }

    pub fn register(self: ClassBuilder) Class {
        rt.register_class_pair(self.cls);
        return self.cls;
    }
};

/// Address of a pointer-sized ivar of `obj` (added with `ClassBuilder.pointerIvar`).
pub fn ivarPtr(obj: Id, name: [*:0]const u8) *?*anyopaque {
    const cls = objectClass(obj) orelse @panic("objc: object without class");
    const iv = rt.class_get_instance_variable(cls, name) orelse @panic("objc: missing ivar");
    const off = rt.ivar_get_offset(iv);
    const base: [*]u8 = @ptrCast(obj);
    return @ptrCast(@alignCast(base + @as(usize, @intCast(off))));
}

/// Like `ivarPtr` but resolves the ivar on a known class (avoids a lookup on subclasses
/// created by KVO isa-swizzling).
pub fn ivarOffset(cls: Class, name: [*:0]const u8) usize {
    const iv = rt.class_get_instance_variable(cls, name) orelse @panic("objc: missing ivar");
    return @intCast(rt.ivar_get_offset(iv));
}

pub fn ivarAt(obj: Id, offset: usize) *?*anyopaque {
    const base: [*]u8 = @ptrCast(obj);
    return @ptrCast(@alignCast(base + offset));
}
