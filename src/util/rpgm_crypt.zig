//! RPG Maker MV/MZ asset decryption — the core of the "decrypt RPGM mod"
//! tool. RPG Maker "encrypts" audio/image assets (.rpgmvp/.rpgmvo/.png_/
//! .ogg_/.m4a_) by prepending a 16-byte fake header and XOR-ing the real
//! file's first 16 bytes with a per-game key (System.json `encryptionKey`,
//! 32 hex chars). Everything past byte 32 is the original file untouched.
//!
//! Pure (no IO) so the (de)cipher + key parsing are unit-tested directly;
//! the recipe `decrypt_rpgm` step walks the staged tree and calls `decrypt`.

const std = @import("std");

pub const HEADER_LEN = 16;
pub const KEY_LEN = 16;

/// RPG Maker's fake-header signature: "RPGMV\0\0\0" + a version stamp. We
/// only match the "RPGMV" prefix — the trailing bytes vary by version.
const SIGNATURE = "RPGMV";

/// True if `data` carries the RPG Maker encrypted-asset header.
pub fn isEncrypted(data: []const u8) bool {
    return data.len >= HEADER_LEN and std.mem.startsWith(u8, data, SIGNATURE);
}

/// Parse a 32-hex-char `encryptionKey` into 16 raw bytes. Returns null on
/// the wrong length or a non-hex digit.
pub fn parseKey(hex: []const u8) ?[KEY_LEN]u8 {
    if (hex.len != KEY_LEN * 2) return null;
    var key: [KEY_LEN]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, hex) catch return null;
    return key;
}

/// Pull the `encryptionKey` out of a System.json blob and parse it.
pub fn keyFromSystemJson(alloc: std.mem.Allocator, json: []const u8) ?[KEY_LEN]u8 {
    const Shape = struct { encryptionKey: ?[]const u8 = null };
    var parsed = std.json.parseFromSlice(Shape, alloc, json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const hex = parsed.value.encryptionKey orelse return null;
    return parseKey(hex);
}

/// Decrypt an encrypted RPG Maker asset: drop the 16-byte fake header, XOR
/// the next 16 bytes with `key`, leave the rest. Returns a fresh buffer
/// (caller owns). Output length = input − 16.
pub fn decrypt(alloc: std.mem.Allocator, data: []const u8, key: [KEY_LEN]u8) error{ NotEncrypted, OutOfMemory }![]u8 {
    if (!isEncrypted(data)) return error.NotEncrypted;
    const body = data[HEADER_LEN..];
    const out = alloc.alloc(u8, body.len) catch return error.OutOfMemory;
    @memcpy(out, body);
    const n = @min(KEY_LEN, out.len);
    for (0..n) |i| out[i] ^= key[i];
    return out;
}

/// Inverse of `decrypt` — only used by tests (and potentially a future
/// re-encrypt tool). Prepends the signature header and XORs the first 16
/// plaintext bytes with `key`.
pub fn encrypt(alloc: std.mem.Allocator, plain: []const u8, key: [KEY_LEN]u8) error{OutOfMemory}![]u8 {
    const out = alloc.alloc(u8, plain.len + HEADER_LEN) catch return error.OutOfMemory;
    @memset(out[0..HEADER_LEN], 0);
    @memcpy(out[0..SIGNATURE.len], SIGNATURE);
    @memcpy(out[HEADER_LEN..], plain);
    const n = @min(KEY_LEN, plain.len);
    for (0..n) |i| out[HEADER_LEN + i] ^= key[i];
    return out;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseKey accepts 32 hex chars, rejects junk" {
    const k = parseKey("0123456789abcdef0123456789abcdef").?;
    try testing.expectEqual(@as(u8, 0x01), k[0]);
    try testing.expectEqual(@as(u8, 0xef), k[15]);
    try testing.expect(parseKey("tooshort") == null);
    try testing.expect(parseKey("zz23456789abcdef0123456789abcdef") == null);
}

test "keyFromSystemJson extracts the key" {
    const json = "{\"encryptionKey\":\"0123456789abcdef0123456789abcdef\",\"other\":1}";
    const k = keyFromSystemJson(testing.allocator, json).?;
    try testing.expectEqual(@as(u8, 0x01), k[0]);
    try testing.expect(keyFromSystemJson(testing.allocator, "{\"no\":\"key\"}") == null);
}

test "encrypt → decrypt round-trips and isEncrypted gates" {
    const key = parseKey("d41d8cd98f00b204e9800998ecf8427e").?;
    const plain = "\x89PNG\r\n\x1a\n....actual image bytes follow....and more";

    try testing.expect(!isEncrypted(plain));
    const enc = try encrypt(testing.allocator, plain, key);
    defer testing.allocator.free(enc);
    try testing.expect(isEncrypted(enc));
    try testing.expectEqual(plain.len + HEADER_LEN, enc.len);

    const dec = try decrypt(testing.allocator, enc, key);
    defer testing.allocator.free(dec);
    try testing.expectEqualStrings(plain, dec);

    try testing.expectError(error.NotEncrypted, decrypt(testing.allocator, plain, key));
}

test "decrypt handles assets shorter than the 16-byte key window" {
    const key = parseKey("ffffffffffffffffffffffffffffffff").?;
    const plain = "tiny"; // < KEY_LEN after header
    const enc = try encrypt(testing.allocator, plain, key);
    defer testing.allocator.free(enc);
    const dec = try decrypt(testing.allocator, enc, key);
    defer testing.allocator.free(dec);
    try testing.expectEqualStrings(plain, dec);
}
