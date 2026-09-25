//! On-demand office-document → PDF conversion for web file previews.
//!
//! The browser cannot render pptx/docx/xlsx natively, so the gateway shells
//! out to LibreOffice headless and serves the produced PDF through the same
//! viewer path as native PDFs. Conversions are cached under the gateway's
//! pref path keyed by document path + mtime + size, so a deck is converted
//! once per edit, not once per view.

const std = @import("std");
const served_files = @import("served_files.zig");

const log = std.log.scoped(.office_preview);

pub const PREVIEW_DIR = "web-file-previews";
const CONVERT_TIMEOUT_SECONDS = 120;

/// Conversions are serialized: LibreOffice instances sharing one user
/// profile race each other, and one dedicated profile keeps warm-start
/// conversions fast while never touching the user's desktop LibreOffice.
var convert_mutex: std.Io.Mutex = .init;

pub const ConvertError = error{
    ConverterUnavailable,
    ConversionFailed,
    SourceNotFound,
} || std.mem.Allocator.Error;

/// Document extensions LibreOffice reliably renders to PDF for previewing.
pub fn convertible(path: []const u8) bool {
    const extensions = [_][]const u8{
        ".pptx", ".ppt", ".odp",
        ".docx", ".doc", ".odt",
        ".xlsx", ".xls", ".ods",
        ".rtf",
    };
    for (extensions) |extension| {
        if (std.ascii.endsWithIgnoreCase(path, extension)) return true;
    }
    return false;
}

/// Basename with the source extension swapped for .pdf — the name
/// `soffice --convert-to pdf` writes into its outdir.
fn producedPdfName(allocator: std.mem.Allocator, document_path: []const u8) ![]u8 {
    const basename = std.fs.path.basename(document_path);
    const stem = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot| basename[0..dot] else basename;
    return std.fmt.allocPrint(allocator, "{s}.pdf", .{stem});
}

/// Returns an open regular cached preview PDF for an authorized descriptor,
/// converting it first if the cache has no entry for the file's current
/// mtime + size. Caller closes the returned descriptor.
pub fn previewPdf(
    allocator: std.mem.Allocator,
    io: std.Io,
    pref_path: []const u8,
    env_map: *const std.process.Environ.Map,
    document_path: []const u8,
    source: std.Io.File,
    max_bytes: usize,
) ConvertError!std.Io.File {
    return previewPdfWithConverter(allocator, io, pref_path, env_map, document_path, source, max_bytes, runConverter);
}

fn previewPdfWithConverter(
    allocator: std.mem.Allocator,
    io: std.Io,
    pref_path: []const u8,
    env_map: *const std.process.Environ.Map,
    document_path: []const u8,
    source: std.Io.File,
    max_bytes: usize,
    comptime convert: anytype,
) ConvertError!std.Io.File {
    const stat = source.stat(io) catch return error.SourceNotFound;
    if (stat.kind != .file or stat.size > max_bytes) return error.SourceNotFound;
    const path_hash = std.hash.Wyhash.hash(0, document_path);
    const state_hash = std.hash.Wyhash.hash(stat.size, std.mem.asBytes(&stat.mtime));

    const cache_dir = std.fs.path.join(allocator, &.{ pref_path, PREVIEW_DIR }) catch return error.OutOfMemory;
    defer allocator.free(cache_dir);
    std.Io.Dir.createDirAbsolute(io, cache_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.ConversionFailed,
    };

    const cached_name = std.fmt.allocPrint(allocator, "p{x}-{x}.pdf", .{ path_hash, state_hash }) catch return error.OutOfMemory;
    defer allocator.free(cached_name);
    const cached_path = std.fs.path.join(allocator, &.{ cache_dir, cached_name }) catch return error.OutOfMemory;
    defer allocator.free(cached_path);

    if (served_files.openCacheFile(io, cached_path)) |file| return file else |_| {}

    // A canceled connection surfaces as a failed conversion; the subsequent
    // response write fails on the same canceled Io and tears the task down.
    convert_mutex.lock(io) catch return error.ConversionFailed;
    defer convert_mutex.unlock(io);
    // Another request may have finished the same conversion while we waited.
    if (served_files.openCacheFile(io, cached_path)) |file| return file else |_| {}

    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    const request_id = std.fmt.bytesToHex(nonce, .lower);
    const temp_name = try std.fmt.allocPrint(allocator, "convert-{s}", .{request_id});
    defer allocator.free(temp_name);
    const out_dir = std.fs.path.join(allocator, &.{ cache_dir, temp_name }) catch return error.OutOfMemory;
    defer allocator.free(out_dir);
    // Exclusive random directory, owner-only; each conversion gets a clean
    // source copy and output namespace. Never give LibreOffice a workspace path.
    std.Io.Dir.createDirAbsolute(io, out_dir, .fromMode(0o700)) catch return error.ConversionFailed;
    defer std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    const source_name = try std.fmt.allocPrint(allocator, "source{s}", .{std.fs.path.extension(document_path)});
    defer allocator.free(source_name);
    const source_path = try std.fs.path.join(allocator, &.{ out_dir, source_name });
    defer allocator.free(source_path);
    const bytes = served_files.readAlloc(allocator, io, source, max_bytes) catch return error.ConversionFailed;
    defer allocator.free(bytes);
    const copy = std.Io.Dir.createFileAbsolute(io, source_path, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch return error.ConversionFailed;
    defer copy.close(io);
    copy.writeStreamingAll(io, bytes) catch return error.ConversionFailed;
    const profile_dir = std.fs.path.join(allocator, &.{ cache_dir, "lo-profile" }) catch return error.OutOfMemory;
    defer allocator.free(profile_dir);
    const profile_arg = std.fmt.allocPrint(allocator, "-env:UserInstallation=file://{s}", .{profile_dir}) catch return error.OutOfMemory;
    defer allocator.free(profile_arg);

    try convert(allocator, io, env_map, profile_arg, out_dir, source_path, &request_id);

    const produced_name = try producedPdfName(allocator, source_path);
    defer allocator.free(produced_name);
    const produced_path = std.fs.path.join(allocator, &.{ out_dir, produced_name }) catch return error.OutOfMemory;
    defer allocator.free(produced_path);
    const produced = served_files.openCacheFile(io, produced_path) catch {
        log.err("preview {s}: missing_regular_pdf", .{request_id});
        return error.ConversionFailed;
    };
    errdefer produced.close(io);

    // One preview per document: stale entries for older mtimes are dropped
    // before the fresh one lands so the cache stays bounded by corpus size.
    pruneStalePreviews(allocator, io, cache_dir, path_hash, cached_name);
    std.Io.Dir.renameAbsolute(produced_path, cached_path, io) catch return error.ConversionFailed;
    return produced;
}

fn runConverter(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    profile_arg: []const u8,
    out_dir: []const u8,
    document_path: []const u8,
    request_id: []const u8,
) ConvertError!void {
    // Arch installs both names; other distros sometimes ship only one.
    const candidates = [_][]const u8{ "soffice", "libreoffice" };
    for (candidates, 0..) |binary, index| {
        const argv = [_][]const u8{
            binary,      "--headless",   "--norestore",
            profile_arg, "--convert-to", "pdf",
            "--outdir",  out_dir,        document_path,
        };
        const result = std.process.run(allocator, io, .{
            .argv = &argv,
            .environ_map = env_map,
            .timeout = .{ .duration = .{ .raw = .fromSeconds(CONVERT_TIMEOUT_SECONDS), .clock = .awake } },
        }) catch |err| switch (err) {
            error.FileNotFound => {
                if (index + 1 < candidates.len) continue;
                return error.ConverterUnavailable;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.err("preview {s}: converter_start_failed", .{request_id});
                return error.ConversionFailed;
            },
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
        // Converter output can include document content and host paths. Emit a
        // fixed, bounded category instead of attempting to redact arbitrary text.
        log.err("preview {s}: converter_abnormal_exit", .{request_id});
        return error.ConversionFailed;
    }
    return error.ConverterUnavailable;
}

/// Deletes cached previews of the same document produced from older file
/// states. Best effort: a leftover entry only costs disk space.
fn pruneStalePreviews(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_dir: []const u8,
    path_hash: u64,
    keep_name: []const u8,
) void {
    var prefix_buf: [32]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "p{x}-", .{path_hash}) catch return;
    const dir = std.Io.Dir.openDirAbsolute(io, cache_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (iterator.next(io) catch return) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (std.mem.eql(u8, entry.name, keep_name)) continue;
        const stale = std.fs.path.join(allocator, &.{ cache_dir, entry.name }) catch continue;
        defer allocator.free(stale);
        std.Io.Dir.deleteFileAbsolute(io, stale) catch {};
    }
}

test "convertible allowlists office document extensions" {
    try std.testing.expect(convertible("/tmp/deck.pptx"));
    try std.testing.expect(convertible("/tmp/DECK.PPTX"));
    try std.testing.expect(convertible("/tmp/report.docx"));
    try std.testing.expect(convertible("/tmp/sheet.ods"));
    try std.testing.expect(!convertible("/tmp/archive.zip"));
    try std.testing.expect(!convertible("/tmp/proof.pdf"));
}

test "preview converts the held descriptor through a private copy and cleans up" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base_buffer);
    const base = base_buffer[0..base_len];
    try tmp.dir.writeFile(io, .{ .sub_path = "original.docx", .data = "authorized bytes" });
    const source = try tmp.dir.openFile(io, "original.docx", .{});
    defer source.close(io);
    // A subsequent pathname lookup would read the replacement instead.
    try tmp.dir.rename("original.docx", tmp.dir, "held.docx", io);
    try tmp.dir.writeFile(io, .{ .sub_path = "original.docx", .data = "replacement bytes" });
    const path = try std.fs.path.join(allocator, &.{ base, "original.docx" });
    defer allocator.free(path);

    const Fixture = struct {
        fn convert(gpa: std.mem.Allocator, test_io: std.Io, _: *const std.process.Environ.Map, _: []const u8, out_dir: []const u8, copy_path: []const u8, _: []const u8) ConvertError!void {
            if (std.mem.indexOf(u8, copy_path, "/convert-") == null or
                !std.mem.endsWith(u8, copy_path, "/source.docx")) return error.ConversionFailed;
            const copy_bytes = std.Io.Dir.cwd().readFileAlloc(test_io, copy_path, gpa, .limited(100)) catch return error.ConversionFailed;
            defer gpa.free(copy_bytes);
            const output = try std.fs.path.join(gpa, &.{ out_dir, "source.pdf" });
            defer gpa.free(output);
            std.Io.Dir.cwd().writeFile(test_io, .{ .sub_path = output, .data = copy_bytes }) catch return error.ConversionFailed;
        }
    };
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const pdf = try previewPdfWithConverter(allocator, io, base, &env, path, source, 100, Fixture.convert);
    defer pdf.close(io);
    const bytes = try served_files.readAlloc(allocator, io, pdf, 100);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("authorized bytes", bytes);
    const cache = try tmp.dir.openDir(io, PREVIEW_DIR, .{ .iterate = true });
    defer cache.close(io);
    var iterator = cache.iterate();
    while (try iterator.next(io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, "convert-"));
    }
}
