const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const testing = std.testing;
const tests = @import("testing.zig");
const reqst = @import("request.zig");
const RequestTime = reqst.RequestTime;
const RequestTarget = reqst.RequestTarget;
const RequestContent = reqst.RequestContent;

const ACCESS_ID_LEN = 20;
const ACCESS_SECRET_LEN = 40;
const V4_PREFIX = "AWS4";
const V4_SUFFIX = "aws4_request";
const V4_ALGO = "AWS4-HMAC-SHA256";
const EMPTY_PAYLOAD = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

const Self = @This();
const SigContent = [256]u8;
const Key = [Hmac.mac_length]u8;
const Hash = [Sha256.digest_length]u8;
const HashStr = [Sha256.digest_length * 2]u8;

access_id: [ACCESS_ID_LEN]u8,
access_secret: [V4_PREFIX.len + ACCESS_SECRET_LEN]u8,

pub fn init(id: *const [ACCESS_ID_LEN]u8, secret: *const [ACCESS_SECRET_LEN]u8) Self {
    const empty_sercet = V4_PREFIX ++ std.mem.zeroes([ACCESS_SECRET_LEN]u8);
    var self = .{ .access_id = id.*, .access_secret = empty_sercet.* };
    @memcpy(self.access_secret[V4_PREFIX.len..][0..ACCESS_SECRET_LEN], secret);
    return self;
}

test "init" {
    const signer = init(tests.ACCESS_ID, tests.ACCESS_SECRET);
    try testing.expectEqualStrings(tests.ACCESS_ID, &signer.access_id);
    try testing.expectEqualStrings(V4_PREFIX ++ tests.ACCESS_SECRET, &signer.access_secret);
}

// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
pub fn sign(self: Self, time: RequestTime, target: RequestTarget, content: RequestContent) !Key {
    var hash: HashStr = undefined;
    var canonical_buffer: [4 * 1024]u8 = undefined;
    const canonical = try caninicalRequest(&canonical_buffer, content);
    hashPayload(&hash, canonical);

    var key: Key = undefined;
    var sign_buffer: SigContent = undefined;
    const region = target.region.code();
    const signable = signatureContent(&sign_buffer, time, region, target.service, &hash);
    signingKey(&key, &self.access_secret, &time.date, region, target.service);
    Hmac.create(&key, signable, &key);
    return key;
}

test "sign" {
    const request = try tests.demoRequest(testing.allocator);
    defer request.deinit(testing.allocator);

    const signer = init(tests.ACCESS_ID, tests.ACCESS_SECRET);
    const key = try signer.sign(RequestTime.initEpoch(1373321335), .{
        .region = .us_east_1,
        .service = "s3",
        .endpoint = undefined,
    }, request);
    // zig fmt: off
    try testing.expectEqualSlices(u8, &.{
        0x2f, 0xc8, 0xcf, 0xe6, 0x90, 0x48, 0xf0, 0x65, 0x6c, 0xd0, 0x2e, 0x96, 0x55, 0xfb, 0x2c, 0xb9,
        0x3c, 0x89, 0x17, 0xac, 0x12, 0x30, 0x89, 0x0b, 0x5a, 0x27, 0x52, 0xef, 0x6b, 0xa7, 0x6c, 0x90,
    }, &key);
    // zig fmt: on
}

/// The caller owns the returned memory.
// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html#create-canonical-request
fn caninicalRequest(buffer: []u8, request: RequestContent) ![]u8 {
    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();
    try writer.print(
        "{s}\n{s}\n{s}{s}\n{s}",
        .{ @tagName(request.method), request.path, request.query, request.headers, request.headers_signed },
    );
    try writer.writeByte('\n');
    var hash: HashStr = undefined;
    hashPayload(&hash, request.payload);
    try writer.writeAll(&hash);
    return buffer[0..stream.pos];
}

test "caninicalRequest" {
    const request = try tests.demoRequest(testing.allocator);
    defer request.deinit(testing.allocator);

    var canonical_buffer: [4 * 1024]u8 = undefined;
    const canonical = try caninicalRequest(&canonical_buffer, request);
    const expected = "GET\n/foo\nbaz=%24qux&foo=%25bar\nhost:s3.amazonaws.com\nx-amz-date:20130708T220855Z\n" ++
        "host;x-amz-date\n269dce1a5bb90188b2d9cf542a7c30e410c7d8251e34a97bfea56062df51ae23";
    try testing.expectEqualStrings(expected, canonical);
}

// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html#create-string-to-sign
fn signatureContent(buffer: *SigContent, time: RequestTime, region: []const u8, service: []const u8, hash: *const HashStr) []const u8 {
    // 30 = 8 date + 16 timestamp + 3 slashes + 3 newlines
    const max_var = comptime buffer.len - (V4_ALGO.len + V4_SUFFIX.len + hash.len + 30);
    std.debug.assert(region.len + service.len <= max_var);

    var stream = std.io.fixedBufferStream(buffer);
    const format = V4_ALGO ++ "\n{s}\n{s}/{s}/{s}/" ++ V4_SUFFIX ++ "\n{s}";
    stream.writer().print(
        format,
        .{ &time.timestamp, &time.date, region, service, hash },
    ) catch unreachable;
    return buffer[0..stream.pos];
}

test "signatureContent" {
    const time = RequestTime.initEpoch(1373321335);
    const hash_buff = "907ae221d7a1aaf07c909ec72d09a3dba409a040b5f3f0914eb28425ce27ef0a";
    var content_buff: SigContent = undefined;
    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256\n20130708T220855Z\n20130708/us-east-1/s3/aws4_request\n907ae221d7a1aaf07c909ec72d09a3dba409a040b5f3f0914eb28425ce27ef0a",
        signatureContent(&content_buff, time, "us-east-1", "s3", hash_buff),
    );
}

// https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_aws-signing.html
fn signingKey(out: *Key, secret: []const u8, date: []const u8, region: []const u8, service: []const u8) void {
    Hmac.create(out, date, secret);
    Hmac.create(out, region, out);
    Hmac.create(out, service, out);
    Hmac.create(out, V4_SUFFIX, out);
}

test "signingKey" {
    var key: Key = undefined;
    signingKey(&key, "secret", "20130708", "us-east-1", "s3");
    // zig fmt: off
    try testing.expectEqualStrings(&.{
        0x05, 0x44, 0x5e, 0x7d, 0x33, 0x2d, 0x16, 0x6e, 0x92, 0xeb, 0xff, 0xac, 0x4b, 0x4a, 0x7a, 0xed,
        0x82, 0x7f, 0x27, 0x01, 0xc3, 0xdc, 0xc1, 0x99, 0xf4, 0xf9, 0x8d, 0x94, 0xfd, 0x5e, 0x15, 0x45,
    }, &key);
    // zig fmt: on
}

fn hashPayload(out: *HashStr, payload: ?[]const u8) void {
    if (payload) |pld| {
        var hash: Hash = undefined;
        Sha256.hash(pld, &hash, .{});
        var hex = std.io.fixedBufferStream(out);
        hex.writer().print("{}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;
    } else {
        @memcpy(out, EMPTY_PAYLOAD);
    }
}

test "hashPayload" {
    var buffer: HashStr = undefined;
    hashPayload(&buffer, "");
    try testing.expectEqualStrings(EMPTY_PAYLOAD, &buffer);

    hashPayload(&buffer, "foo-bar-baz");
    const expected = "269dce1a5bb90188b2d9cf542a7c30e410c7d8251e34a97bfea56062df51ae23";
    try testing.expectEqualStrings(expected, &buffer);
}
