const std = @import("std");
const testing = std.testing;

pub const Sha256 = std.crypto.hash.sha2.Sha256;
pub const Hmac256 = std.crypto.auth.hmac.sha2.HmacSha256;

const HASH_LEN = Sha256.digest_length;
pub const HashBytes = [HASH_LEN]u8;
pub const HashStr = [HASH_LEN * 2]u8;

const EMPTY_HASH = [_]u8{
    0xE3, 0xB0, 0xC4, 0x42, 0x98, 0xFC, 0x1C, 0x14, 0x9A, 0xFB, 0xF4, 0xC8, 0x99, 0x6F, 0xB9, 0x24,
    0x27, 0xAE, 0x41, 0xE4, 0x64, 0x9B, 0x93, 0x4C, 0xA4, 0x95, 0x99, 0x1B, 0x78, 0x52, 0xB8, 0x55,
};
const EMPTY_HASH_STR = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

/// Hash a payload into a 256-bit hash (SHA-256).
pub fn hash256(out: *HashBytes, payload: []const u8) void {
    if (payload.len > 0) {
        Sha256.hash(payload, out, .{});
    } else {
        @memcpy(out, &EMPTY_HASH);
    }
}

test "hash256" {
    var buffer: HashBytes = undefined;
    hash256(&buffer, &.{});
    try testing.expectEqualStrings(&EMPTY_HASH, &buffer);

    hash256(&buffer, "foo-bar-baz");
    try testing.expectEqualSlices(u8, &.{
        0x26, 0x9D, 0xCE, 0x1A, 0x5B, 0xB9, 0x01, 0x88, 0xB2, 0xD9, 0xCF, 0x54, 0x2A, 0x7C, 0x30, 0xE4,
        0x10, 0xC7, 0xD8, 0x25, 0x1E, 0x34, 0xA9, 0x7B, 0xFE, 0xA5, 0x60, 0x62, 0xDF, 0x51, 0xAE, 0x23,
    }, &buffer);
}

/// Hash a payload into a 64 lower-case hexdecimal characters.
pub fn hashString(out: *HashStr, payload: ?[]const u8) void {
    std.debug.assert(out.len >= 2 * HASH_LEN);
    if (payload) |pld| if (pld.len > 0) {
        var s256: HashBytes = undefined;
        hash256(&s256, pld);
        _ = hexString(out, .lower, &s256) catch unreachable;
        return;
    };

    // Null or empty
    @memcpy(out, EMPTY_HASH_STR);
}

test "hashString" {
    var buffer: HashStr = undefined;
    hashString(&buffer, "");
    try testing.expectEqualStrings(EMPTY_HASH_STR, &buffer);

    hashString(&buffer, "foo-bar-baz");
    try testing.expectEqualStrings(
        "269dce1a5bb90188b2d9cf542a7c30e410c7d8251e34a97bfea56062df51ae23",
        &buffer,
    );
}

/// The output buffer must be at-least double the length of the input payload.
pub fn hexString(buffer: []u8, case: std.fmt.Case, payload: []const u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buffer);
    switch (case) {
        .lower => try stream.writer().print("{}", .{std.fmt.fmtSliceHexLower(payload)}),
        .upper => try stream.writer().print("{}", .{std.fmt.fmtSliceHexUpper(payload)}),
    }
    return stream.getWritten();
}

test "hexString" {
    const payload: []const u8 = &.{
        0x26, 0x9D, 0xCE, 0x1A, 0x5B, 0xB9, 0x01, 0x88, 0xB2, 0xD9, 0xCF, 0x54, 0x2A, 0x7C, 0x30, 0xE4,
        0x10, 0xC7, 0xD8, 0x25, 0x1E, 0x34, 0xA9, 0x7B, 0xFE, 0xA5, 0x60, 0x62, 0xDF, 0x51, 0xAE, 0x23,
    };

    var buffer: HashStr = undefined;
    try testing.expectEqualStrings(
        "269dce1a5bb90188b2d9cf542a7c30e410c7d8251e34a97bfea56062df51ae23",
        try hexString(&buffer, .lower, payload),
    );
    try testing.expectEqualStrings(
        "269DCE1A5BB90188B2D9CF542A7C30E410C7D8251E34A97BFEA56062DF51AE23",
        try hexString(&buffer, .upper, payload),
    );
}
