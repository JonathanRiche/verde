//! Shared chat-attachment staging contract for remote repository routes.
//!
//! Desktop clients stream image bytes to the selected runtime through the
//! chunked `chat.attachment.*` methods, then reference the returned opaque
//! attachment IDs in `chat.turn.start`. Local desktop paths never cross the
//! runtime boundary. Pure std-only helpers so the daemon, gateway, and
//! desktop client validate identically.

const std = @import("std");

/// Capability advertised by daemons that accept staged chat attachments.
pub const CHAT_ATTACHMENT_CAPABILITY = "chat.attachments.v1";

pub const METHOD_CHAT_ATTACHMENT_CREATE = "chat.attachment.create";
pub const METHOD_CHAT_ATTACHMENT_APPEND = "chat.attachment.append";
pub const METHOD_CHAT_ATTACHMENT_COMMIT = "chat.attachment.commit";

/// Attachment IDs are daemon-generated 32-char lowercase hex, mirroring the
/// runtime/instance id shape. Anything else is rejected before lookup.
pub const ATTACHMENT_ID_LENGTH: usize = 32;

/// Durable message rows reference staged uploads as
/// `verde-attachment:<id>` — a stable opaque token — instead of any
/// filesystem path. v1 persists attachment metadata only; the staged bytes
/// expire with the runtime-side TTL and are not downloadable afterwards.
pub const ATTACHMENT_REFERENCE_PREFIX = "verde-attachment:";

/// One turn references at most this many staged attachments. Shared between
/// the desktop composer gate (visible pre-staging rejection) and the daemon
/// claim path so a client can never stage a set it cannot send.
pub const MAX_ATTACHMENTS_PER_TURN: usize = 16;

/// Portable per-image byte cap every audited native chat provider harness can
/// ingest (Pi's 16 MiB limit is the smallest). Desktop rejects before staging
/// and the daemon rejects at create, so acceptance never defers a
/// deterministic provider-side failure.
pub const MAX_PORTABLE_ATTACHMENT_BYTES: usize = 16 * 1024 * 1024;

/// Envelope headroom reserved for the JSON-RPC wrapper around one append
/// frame (id, method, target, attachment_id, offset, quoting).
const APPEND_ENVELOPE_RESERVE_BYTES: usize = 4096;

/// Preferred throughput floor. Only applied when the advertised request
/// limit can actually carry it; degenerate limits fall back to the largest
/// fitting chunk so the fit contract is never violated.
pub const MIN_APPEND_CHUNK_BYTES: usize = 4096;

pub fn isValidAttachmentId(value: []const u8) bool {
    if (value.len != ATTACHMENT_ID_LENGTH) return false;
    for (value) |byte| {
        const hex_digit = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
        if (!hex_digit) return false;
    }
    return true;
}

/// Largest raw (pre-base64) chunk that fits one append request inside the
/// transport's max request size. Base64 expands 3 raw bytes into 4 encoded.
pub fn maxAppendChunkBytes(max_request_bytes: usize) usize {
    const budget = max_request_bytes -| APPEND_ENVELOPE_RESERVE_BYTES;
    const raw = (budget / 4) * 3;
    // Any raw <= (budget/4)*3 encodes to <= budget, so returning raw keeps
    // the fit contract even for tiny advertised limits. Zero means no chunk
    // can fit at all; callers must treat that as "uploads unsupported" and
    // never arm an upload loop with it.
    return raw;
}

/// Image MIME types accepted for staged chat attachments. Matches the
/// provider harness contract: every native chat provider consumes these.
pub fn supportedImageMime(value: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(value, "image/png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(value, "image/jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(value, "image/webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(value, "image/gif")) return "image/gif";
    return null;
}

/// Sniff a supported image MIME type from leading magic bytes.
pub fn sniffImageMime(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return "image/jpeg";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return "image/gif";
    return null;
}

/// Verify committed bytes actually match the declared MIME type.
pub fn imageBytesMatchMime(mime: []const u8, bytes: []const u8) bool {
    const sniffed = sniffImageMime(bytes) orelse return false;
    return std.mem.eql(u8, sniffed, mime);
}

pub fn imageExtension(mime: []const u8) []const u8 {
    if (std.mem.eql(u8, mime, "image/png")) return "png";
    if (std.mem.eql(u8, mime, "image/jpeg")) return "jpg";
    if (std.mem.eql(u8, mime, "image/webp")) return "webp";
    return "gif";
}

/// Capability advertised by daemons that also stage files that are not
/// images. Such a file never becomes a provider image input: the turn's
/// prompt names its runtime-local path so the agent reads it with its tools.
pub const CHAT_ATTACHMENT_FILES_CAPABILITY = "chat.attachments.files.v1";

/// Longest client-supplied display name kept for a staged file.
pub const MAX_ATTACHMENT_NAME_BYTES: usize = 120;
/// Longest extension carried from a file's name onto its staged path.
pub const MAX_FILE_EXTENSION_BYTES: usize = 10;

/// A well-formed `type/subtype` media type for a staged file. The value is
/// only a label; file bytes are never interpreted through it.
pub fn isValidFileMime(value: []const u8) bool {
    if (value.len == 0 or value.len > 127) return false;
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return false;
    if (slash == 0 or slash + 1 == value.len) return false;
    for (value, 0..) |byte, index| {
        if (index == slash) continue;
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$&^_.+-", byte) == null) return false;
    }
    return true;
}

/// A display name safe to echo into a prompt and a transcript: one line of
/// valid UTF-8 with no path separators or control bytes.
pub fn isValidAttachmentName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_ATTACHMENT_NAME_BYTES) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (!std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == '/' or byte == '\\') return false;
    }
    return true;
}

/// Lowercase alphanumeric extension of `name` written into `buffer`, or
/// "bin". The staged path keeps it so agents and tools recognize the type;
/// nothing else of the client's name reaches the filesystem.
pub fn fileExtension(name: []const u8, buffer: *[MAX_FILE_EXTENSION_BYTES]u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "bin";
    const raw = name[dot + 1 ..];
    if (dot == 0 or raw.len == 0 or raw.len > MAX_FILE_EXTENSION_BYTES) return "bin";
    for (raw, 0..) |byte, index| {
        if (!std.ascii.isAlphanumeric(byte)) return "bin";
        buffer[index] = std.ascii.toLower(byte);
    }
    return buffer[0..raw.len];
}

test "file attachments validate their mime, name and extension" {
    try std.testing.expect(isValidFileMime("application/pdf"));
    try std.testing.expect(isValidFileMime("application/vnd.ms-excel.sheet+xml"));
    try std.testing.expect(!isValidFileMime("pdf"));
    try std.testing.expect(!isValidFileMime("text/"));
    try std.testing.expect(!isValidFileMime("text/plain; charset=utf-8"));
    try std.testing.expect(!isValidFileMime("a/b/c"));
    try std.testing.expect(isValidAttachmentName("Q3 report (final).pdf"));
    try std.testing.expect(!isValidAttachmentName("../etc/passwd"));
    try std.testing.expect(!isValidAttachmentName("two\nlines.txt"));
    try std.testing.expect(!isValidAttachmentName(".."));
    try std.testing.expect(!isValidAttachmentName(""));
    var buffer: [MAX_FILE_EXTENSION_BYTES]u8 = undefined;
    try std.testing.expectEqualStrings("pdf", fileExtension("Report.PDF", &buffer));
    try std.testing.expectEqualStrings("gz", fileExtension("logs.tar.gz", &buffer));
    try std.testing.expectEqualStrings("bin", fileExtension("Makefile", &buffer));
    try std.testing.expectEqualStrings("bin", fileExtension(".env", &buffer));
    try std.testing.expectEqualStrings("bin", fileExtension("odd.na me", &buffer));
    try std.testing.expectEqualStrings("bin", fileExtension("long.abcdefghijklm", &buffer));
}

test "attachment id validation accepts only 32 lowercase hex chars" {
    try std.testing.expect(isValidAttachmentId("0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!isValidAttachmentId(""));
    try std.testing.expect(!isValidAttachmentId("0123456789abcdef0123456789abcde"));
    try std.testing.expect(!isValidAttachmentId("0123456789ABCDEF0123456789ABCDEF"));
    try std.testing.expect(!isValidAttachmentId("../3456789abcdef0123456789abcdef"));
    try std.testing.expect(!isValidAttachmentId("0123456789abcdef0123456789abcdeg"));
}

test "append chunk sizing keeps the encoded fit contract for every limit" {
    const chunk = maxAppendChunkBytes(1024 * 1024);
    // Encoded chunk plus envelope must fit the advertised request limit.
    const encoded = std.base64.standard.Encoder.calcSize(chunk);
    try std.testing.expect(encoded + APPEND_ENVELOPE_RESERVE_BYTES <= 1024 * 1024);
    try std.testing.expect(chunk >= 512 * 1024);
    // The fit contract holds for every limit: any nonzero result encodes
    // within the limit, and impossible limits report exactly zero.
    const limits = [_]usize{ 0, 1, APPEND_ENVELOPE_RESERVE_BYTES, APPEND_ENVELOPE_RESERVE_BYTES + 3, APPEND_ENVELOPE_RESERVE_BYTES + 4, APPEND_ENVELOPE_RESERVE_BYTES + 100, 8 * 1024, 16 * 1024, 1024 * 1024 };
    for (limits) |limit| {
        const sized = maxAppendChunkBytes(limit);
        if (sized > 0) {
            try std.testing.expect(std.base64.standard.Encoder.calcSize(sized) + APPEND_ENVELOPE_RESERVE_BYTES <= limit);
        } else {
            try std.testing.expect(limit < APPEND_ENVELOPE_RESERVE_BYTES + 4);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), maxAppendChunkBytes(0));
    try std.testing.expectEqual(@as(usize, 0), maxAppendChunkBytes(APPEND_ENVELOPE_RESERVE_BYTES));
    try std.testing.expectEqual(@as(usize, 3), maxAppendChunkBytes(APPEND_ENVELOPE_RESERVE_BYTES + 4));
    try std.testing.expectEqual(@as(usize, 3072), maxAppendChunkBytes(8 * 1024));
}
