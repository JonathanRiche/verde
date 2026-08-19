//! On-demand office-document → PDF conversion for web file previews.
//!
//! The browser cannot render pptx/docx/xlsx natively, so the gateway shells
//! out to LibreOffice headless and serves the produced PDF through the same
//! viewer path as native PDFs. Conversions are cached under the gateway's
//! pref path keyed by document path + mtime + size, so a deck is converted
//! once per edit, not once per view.

const std = @import("std");

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

/// Returns the absolute path of a cached preview PDF for `document_path`,
/// converting it first if the cache has no entry for the file's current
/// mtime + size. Caller owns the returned path.
pub fn previewPdf(
    allocator: std.mem.Allocator,
    io: std.Io,
    pref_path: []const u8,
    env_map: *const std.process.Environ.Map,
    document_path: []const u8,
) ConvertError![]u8 {
    const stat = std.Io.Dir.cwd().statFile(io, document_path, .{}) catch return error.SourceNotFound;
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
    errdefer allocator.free(cached_path);

    if (fileExists(io, cached_path)) return cached_path;

    // A canceled connection surfaces as a failed conversion; the subsequent
    // response write fails on the same canceled Io and tears the task down.
    convert_mutex.lock(io) catch return error.ConversionFailed;
    defer convert_mutex.unlock(io);
    // Another request may have finished the same conversion while we waited.
    if (fileExists(io, cached_path)) return cached_path;

    const out_dir = std.fs.path.join(allocator, &.{ cache_dir, "convert-tmp" }) catch return error.OutOfMemory;
    defer allocator.free(out_dir);
    std.Io.Dir.createDirAbsolute(io, out_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.ConversionFailed,
    };
    const profile_dir = std.fs.path.join(allocator, &.{ cache_dir, "lo-profile" }) catch return error.OutOfMemory;
    defer allocator.free(profile_dir);
    const profile_arg = std.fmt.allocPrint(allocator, "-env:UserInstallation=file://{s}", .{profile_dir}) catch return error.OutOfMemory;
    defer allocator.free(profile_arg);

    try runConverter(allocator, io, env_map, profile_arg, out_dir, document_path);

    const produced_name = try producedPdfName(allocator, document_path);
    defer allocator.free(produced_name);
    const produced_path = std.fs.path.join(allocator, &.{ out_dir, produced_name }) catch return error.OutOfMemory;
    defer allocator.free(produced_path);
    if (!fileExists(io, produced_path)) {
        log.err("soffice reported success but produced no pdf for {s}", .{document_path});
        return error.ConversionFailed;
    }

    // One preview per document: stale entries for older mtimes are dropped
    // before the fresh one lands so the cache stays bounded by corpus size.
    pruneStalePreviews(allocator, io, cache_dir, path_hash, cached_name);
    std.Io.Dir.renameAbsolute(produced_path, cached_path, io) catch return error.ConversionFailed;
    return cached_path;
}

fn runConverter(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    profile_arg: []const u8,
    out_dir: []const u8,
    document_path: []const u8,
) ConvertError!void {
    // Arch installs both names; other distros sometimes ship only one.
    const candidates = [_][]const u8{ "soffice", "libreoffice" };
    for (candidates, 0..) |binary, index| {
        const argv = [_][]const u8{
            binary,          "--headless",  "--norestore",
            profile_arg,     "--convert-to", "pdf",
            "--outdir",      out_dir,       document_path,
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
                log.err("conversion of {s} failed to run: {s}", .{ document_path, @errorName(err) });
                return error.ConversionFailed;
            },
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
        log.err("soffice exited abnormally for {s}: {s}", .{ document_path, result.stderr });
        return error.ConversionFailed;
    }
    return error.ConverterUnavailable;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
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

test "produced pdf name swaps the source extension" {
    const name = try producedPdfName(std.testing.allocator, "/a/b/Richmond_Proposal_Final.pptx");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("Richmond_Proposal_Final.pdf", name);

    const bare = try producedPdfName(std.testing.allocator, "/a/b/nodot");
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualStrings("nodot.pdf", bare);
}
