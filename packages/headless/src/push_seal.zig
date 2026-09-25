//! Sealed-box encryption for push notification payloads (mobile plan §8).
//!
//! The daemon seals a small payload to a paired device's X25519 public key.
//! The push relay, FCM and APNs only ever carry the opaque envelope string;
//! the phone's Zig core opens it with the device's secret key. Both sides
//! call this module, so the Kotlin and Swift apps never reimplement it.
//!
//! Envelope format, version 1 (all lengths in bytes):
//!
//!     raw      = version (1) || ephemeral_public (32) || ciphertext (n) || tag (16)
//!     envelope = base64url(raw)   RFC 4648 §5 alphabet, no '=' padding
//!
//! `version` is the single byte 0x01. `n` equals the plaintext length and is
//! at most `max_plaintext_len` (3 KiB).
//!
//! Sealing to `recipient_public` (32 bytes):
//!
//!  1. Generate a fresh X25519 key pair (`ephemeral_secret`, `ephemeral_public`).
//!  2. `shared = X25519(ephemeral_secret, recipient_public)`. An all-zero
//!     result (a low-order recipient key) is rejected.
//!  3. HKDF-SHA256 (RFC 5869):
//!       `prk = Extract(salt = ephemeral_public || recipient_public, ikm = shared)`
//!       `okm = Expand(prk, info = "verde-push-v1", length = 44)`
//!     The salt is the two raw 32-byte public keys concatenated (64 bytes).
//!  4. `key = okm[0..32]`, `nonce = okm[32..44]`.
//!  5. ChaCha20-Poly1305 (RFC 8439) with that key and nonce, associated data
//!     `version || ephemeral_public` (the 33-byte envelope header), yields
//!     `ciphertext` and the 16-byte `tag`.
//!
//! The nonce is derived rather than random because every envelope uses a new
//! ephemeral key, so each derived AEAD key encrypts exactly one message.
//! Opening recomputes `shared = X25519(recipient_secret, ephemeral_public)`
//! and the same key and nonce. `recipient_public` for the salt is recomputed
//! from `recipient_secret`, so it is never transmitted.

const std = @import("std");

const X25519 = std.crypto.dh.X25519;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const base64 = std.base64.url_safe_no_pad;

/// Envelope format version; the first raw byte of every envelope.
pub const VERSION: u8 = 1;
/// HKDF-Expand `info` string for version 1.
pub const KDF_INFO = "verde-push-v1";
pub const PUBLIC_KEY_LENGTH = X25519.public_length;
pub const SECRET_KEY_LENGTH = X25519.secret_length;
/// Largest plaintext `seal` accepts, sized for FCM/APNs payload limits.
pub const MAX_PLAINTEXT_LEN: usize = 3 * 1024;
/// Raw envelope bytes added to the plaintext: version, ephemeral key, tag.
pub const ENVELOPE_OVERHEAD: usize = HEADER_LEN + ChaCha20Poly1305.tag_length;
/// Longest base64url envelope string `open` accepts.
pub const MAX_ENVELOPE_LEN: usize = base64.Encoder.calcSize(MAX_PLAINTEXT_LEN + ENVELOPE_OVERHEAD);

const HEADER_LEN: usize = 1 + PUBLIC_KEY_LENGTH;
const MAX_RAW_LEN: usize = MAX_PLAINTEXT_LEN + ENVELOPE_OVERHEAD;
const KEY_LENGTH = ChaCha20Poly1305.key_length;
const NONCE_LENGTH = ChaCha20Poly1305.nonce_length;
const TAG_LENGTH = ChaCha20Poly1305.tag_length;

/// X25519 key pair. The device keeps `secret_key` in platform secure storage
/// and registers `public_key` with each paired host.
pub const KeyPair = X25519.KeyPair;

pub const SealError = error{
    PlaintextTooLarge,
    /// The recipient key is a low-order point; no shared secret exists.
    WeakPublicKey,
    OutOfMemory,
};

pub const OpenError = error{
    EnvelopeTooLarge,
    /// Not base64url, shorter than the fixed overhead, or a low-order
    /// ephemeral key.
    InvalidEnvelope,
    UnsupportedVersion,
    /// Wrong recipient key or a modified envelope.
    AuthenticationFailed,
    OutOfMemory,
};

/// Generate a new random device key pair.
pub fn generateKeyPair(io: std.Io) KeyPair {
    return KeyPair.generate(io);
}

/// Seal `plaintext` to `recipient_public`. Returns a caller-owned base64url
/// envelope string of `envelopeLen(plaintext.len)` bytes.
pub fn seal(
    allocator: std.mem.Allocator,
    io: std.Io,
    recipient_public: [PUBLIC_KEY_LENGTH]u8,
    plaintext: []const u8,
) SealError![]u8 {
    var ephemeral_seed: [X25519.seed_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &ephemeral_seed);
    io.random(&ephemeral_seed);
    return sealWithEphemeralSeed(allocator, recipient_public, plaintext, ephemeral_seed);
}

/// Open an envelope produced by `seal` for this device. Returns the
/// caller-owned plaintext.
pub fn open(
    allocator: std.mem.Allocator,
    recipient_secret: [SECRET_KEY_LENGTH]u8,
    envelope: []const u8,
) OpenError![]u8 {
    if (envelope.len > MAX_ENVELOPE_LEN) return error.EnvelopeTooLarge;

    var raw_buffer: [MAX_RAW_LEN]u8 = undefined;
    const raw_len = base64.Decoder.calcSizeForSlice(envelope) catch return error.InvalidEnvelope;
    const raw = raw_buffer[0..raw_len];
    base64.Decoder.decode(raw, envelope) catch return error.InvalidEnvelope;
    if (raw.len < ENVELOPE_OVERHEAD) return error.InvalidEnvelope;
    if (raw[0] != VERSION) return error.UnsupportedVersion;

    const header = raw[0..HEADER_LEN];
    const ephemeral_public = header[1..HEADER_LEN].*;
    const ciphertext = raw[HEADER_LEN .. raw.len - TAG_LENGTH];
    const tag = raw[raw.len - TAG_LENGTH ..][0..TAG_LENGTH].*;

    const recipient_public = X25519.recoverPublicKey(recipient_secret) catch return error.AuthenticationFailed;
    const shared = X25519.scalarmult(recipient_secret, ephemeral_public) catch return error.InvalidEnvelope;
    var keys = deriveKeys(shared, ephemeral_public, recipient_public);
    defer keys.clear();

    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plaintext);
    ChaCha20Poly1305.decrypt(plaintext, ciphertext, tag, header, keys.nonce, keys.key) catch
        return error.AuthenticationFailed;
    return plaintext;
}

/// Base64url envelope length for a plaintext of `plaintext_len` bytes.
pub fn envelopeLen(plaintext_len: usize) usize {
    return base64.Encoder.calcSize(plaintext_len + ENVELOPE_OVERHEAD);
}

/// Deterministic core of `seal`; tests inject the ephemeral seed to pin
/// vectors. Production callers must go through `seal`.
fn sealWithEphemeralSeed(
    allocator: std.mem.Allocator,
    recipient_public: [PUBLIC_KEY_LENGTH]u8,
    plaintext: []const u8,
    ephemeral_seed: [X25519.seed_length]u8,
) SealError![]u8 {
    if (plaintext.len > MAX_PLAINTEXT_LEN) return error.PlaintextTooLarge;

    var ephemeral = KeyPair.generateDeterministic(ephemeral_seed) catch return error.WeakPublicKey;
    defer std.crypto.secureZero(u8, &ephemeral.secret_key);
    const shared = X25519.scalarmult(ephemeral.secret_key, recipient_public) catch return error.WeakPublicKey;
    var keys = deriveKeys(shared, ephemeral.public_key, recipient_public);
    defer keys.clear();

    var raw_buffer: [MAX_RAW_LEN]u8 = undefined;
    const raw = raw_buffer[0 .. plaintext.len + ENVELOPE_OVERHEAD];
    raw[0] = VERSION;
    raw[1..HEADER_LEN].* = ephemeral.public_key;
    const header = raw[0..HEADER_LEN];
    const ciphertext = raw[HEADER_LEN..][0..plaintext.len];
    const tag = raw[HEADER_LEN + plaintext.len ..][0..TAG_LENGTH];
    ChaCha20Poly1305.encrypt(ciphertext, tag, plaintext, header, keys.nonce, keys.key);

    const envelope = try allocator.alloc(u8, base64.Encoder.calcSize(raw.len));
    _ = base64.Encoder.encode(envelope, raw);
    return envelope;
}

const DerivedKeys = struct {
    key: [KEY_LENGTH]u8,
    nonce: [NONCE_LENGTH]u8,

    fn clear(self: *DerivedKeys) void {
        std.crypto.secureZero(u8, &self.key);
        std.crypto.secureZero(u8, &self.nonce);
    }
};

fn deriveKeys(
    shared_secret: [X25519.shared_length]u8,
    ephemeral_public: [PUBLIC_KEY_LENGTH]u8,
    recipient_public: [PUBLIC_KEY_LENGTH]u8,
) DerivedKeys {
    var shared = shared_secret;
    defer std.crypto.secureZero(u8, &shared);
    const salt = ephemeral_public ++ recipient_public;
    var prk = HkdfSha256.extract(&salt, &shared);
    defer std.crypto.secureZero(u8, &prk);
    var okm: [KEY_LENGTH + NONCE_LENGTH]u8 = undefined;
    defer std.crypto.secureZero(u8, &okm);
    HkdfSha256.expand(&okm, KDF_INFO, prk);
    return .{ .key = okm[0..KEY_LENGTH].*, .nonce = okm[KEY_LENGTH..].* };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// RFC 7748 §6.1 key pairs: Bob is the recipient device, Alice's secret is
// the injected ephemeral seed.
const vector_recipient_secret = hexArray(32, "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
const vector_recipient_public = hexArray(32, "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
const vector_ephemeral_seed = hexArray(32, "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
const vector_plaintext =
    \\{"kind":"approval","title":"Verde","snippet":"Run the test suite?"}
;
/// Cross-checked against an independent HKDF/ChaCha20-Poly1305 implementation
/// following the module-level description.
const vector_envelope = "AYUg8AmJMKdUdIt93LQ-91oNvzoNJjga9OukqY6qm05qd-M-eyZ6GWfMt9YSx4uHlwgMPXIeysAPOHi25l4kjlcz6tr1W6wqWvY-MQG_75AKRw5qYyaAZ3xpLtSB4pcNUOA4dcXSA_j7kF6nIah4BhB5MPk";

fn hexArray(comptime len: usize, comptime hex: []const u8) [len]u8 {
    var out: [len]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

fn expectOpenError(expected: OpenError, secret: [SECRET_KEY_LENGTH]u8, envelope: []const u8) !void {
    try testing.expectError(expected, open(testing.allocator, secret, envelope));
}

/// Decode `envelope`, flip one bit of raw byte `index`, and re-encode.
fn tamperedEnvelope(allocator: std.mem.Allocator, envelope: []const u8, index: usize) ![]u8 {
    var raw_buffer: [MAX_RAW_LEN]u8 = undefined;
    const raw = raw_buffer[0..try base64.Decoder.calcSizeForSlice(envelope)];
    try base64.Decoder.decode(raw, envelope);
    raw[index] ^= 0x01;
    const out = try allocator.alloc(u8, base64.Encoder.calcSize(raw.len));
    _ = base64.Encoder.encode(out, raw);
    return out;
}

test "push seal round-trips with random keys" {
    const device = generateKeyPair(testing.io);
    const plaintext = "{\"kind\":\"attention\",\"title\":\"Chat needs input\"}";

    const first = try seal(testing.allocator, testing.io, device.public_key, plaintext);
    defer testing.allocator.free(first);
    const second = try seal(testing.allocator, testing.io, device.public_key, plaintext);
    defer testing.allocator.free(second);
    try testing.expectEqual(envelopeLen(plaintext.len), first.len);
    // Fresh ephemeral keys make every envelope distinct.
    try testing.expect(!std.mem.eql(u8, first, second));

    for ([_][]const u8{ first, second }) |envelope| {
        const opened = try open(testing.allocator, device.secret_key, envelope);
        defer testing.allocator.free(opened);
        try testing.expectEqualStrings(plaintext, opened);
    }
}

test "push seal round-trips an empty plaintext" {
    const device = generateKeyPair(testing.io);
    const envelope = try seal(testing.allocator, testing.io, device.public_key, "");
    defer testing.allocator.free(envelope);
    const opened = try open(testing.allocator, device.secret_key, envelope);
    defer testing.allocator.free(opened);
    try testing.expectEqual(@as(usize, 0), opened.len);
}

test "push seal matches the fixed vector" {
    const recipient = try KeyPair.generateDeterministic(vector_recipient_secret);
    try testing.expectEqualSlices(u8, &vector_recipient_public, &recipient.public_key);

    const envelope = try sealWithEphemeralSeed(testing.allocator, vector_recipient_public, vector_plaintext, vector_ephemeral_seed);
    defer testing.allocator.free(envelope);
    try testing.expectEqualStrings(vector_envelope, envelope);

    const opened = try open(testing.allocator, vector_recipient_secret, vector_envelope);
    defer testing.allocator.free(opened);
    try testing.expectEqualStrings(vector_plaintext, opened);
}

test "push open rejects tampering in every envelope field" {
    const raw_len = vector_plaintext.len + ENVELOPE_OVERHEAD;
    const cases = [_]struct { index: usize, expected: OpenError }{
        .{ .index = 0, .expected = error.UnsupportedVersion }, // version
        .{ .index = 1, .expected = error.AuthenticationFailed }, // ephemeral key, first byte
        .{ .index = HEADER_LEN - 1, .expected = error.AuthenticationFailed }, // ephemeral key, last byte
        .{ .index = HEADER_LEN, .expected = error.AuthenticationFailed }, // ciphertext
        .{ .index = raw_len - TAG_LENGTH - 1, .expected = error.AuthenticationFailed }, // ciphertext, last byte
        .{ .index = raw_len - TAG_LENGTH, .expected = error.AuthenticationFailed }, // tag
        .{ .index = raw_len - 1, .expected = error.AuthenticationFailed }, // tag, last byte
    };
    for (cases) |case| {
        const tampered = try tamperedEnvelope(testing.allocator, vector_envelope, case.index);
        defer testing.allocator.free(tampered);
        try expectOpenError(case.expected, vector_recipient_secret, tampered);
    }
}

test "push open rejects the wrong recipient key" {
    const other = generateKeyPair(testing.io);
    try expectOpenError(error.AuthenticationFailed, other.secret_key, vector_envelope);
}

test "push open rejects malformed envelopes" {
    try expectOpenError(error.InvalidEnvelope, vector_recipient_secret, "");
    // Shorter than the fixed overhead.
    try expectOpenError(error.InvalidEnvelope, vector_recipient_secret, vector_envelope[0..40]);
    // Standard-alphabet and padding characters are not base64url-no-pad.
    try expectOpenError(error.InvalidEnvelope, vector_recipient_secret, "AQ+/" ++ vector_envelope[4..]);
    try expectOpenError(error.InvalidEnvelope, vector_recipient_secret, vector_envelope ++ "==");
    // Non-canonical trailing bits from cutting the base64 text mid-byte.
    try expectOpenError(error.InvalidEnvelope, vector_recipient_secret, vector_envelope[0 .. vector_envelope.len - 1]);
    // A canonical encoding of the envelope minus its last byte: truncated tag.
    var raw_buffer: [MAX_RAW_LEN]u8 = undefined;
    const raw = raw_buffer[0..try base64.Decoder.calcSizeForSlice(vector_envelope)];
    try base64.Decoder.decode(raw, vector_envelope);
    var truncated_buffer: [MAX_ENVELOPE_LEN]u8 = undefined;
    const truncated = base64.Encoder.encode(&truncated_buffer, raw[0 .. raw.len - 1]);
    try expectOpenError(error.AuthenticationFailed, vector_recipient_secret, truncated);
}

test "push seal rejects a low-order recipient key" {
    const zero_key = [_]u8{0} ** PUBLIC_KEY_LENGTH;
    try testing.expectError(error.WeakPublicKey, seal(testing.allocator, testing.io, zero_key, "x"));
}

test "push seal enforces the 3 KiB plaintext limit" {
    const device = generateKeyPair(testing.io);
    var plaintext: [MAX_PLAINTEXT_LEN + 1]u8 = undefined;
    @memset(&plaintext, 'a');

    const envelope = try seal(testing.allocator, testing.io, device.public_key, plaintext[0..MAX_PLAINTEXT_LEN]);
    defer testing.allocator.free(envelope);
    try testing.expectEqual(MAX_ENVELOPE_LEN, envelope.len);
    const opened = try open(testing.allocator, device.secret_key, envelope);
    defer testing.allocator.free(opened);
    try testing.expectEqualSlices(u8, plaintext[0..MAX_PLAINTEXT_LEN], opened);

    try testing.expectError(error.PlaintextTooLarge, seal(testing.allocator, testing.io, device.public_key, &plaintext));

    // One character past the largest valid envelope is rejected before decoding.
    var oversized: [MAX_ENVELOPE_LEN + 1]u8 = undefined;
    @memset(&oversized, 'A');
    try expectOpenError(error.EnvelopeTooLarge, device.secret_key, &oversized);
}
