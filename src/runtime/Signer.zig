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
const AccessId = [ACCESS_ID_LEN]u8;
const AccessSecret = [ACCESS_SECRET_LEN]u8;
const AccessSecretFull = [V4_PREFIX.len + ACCESS_SECRET_LEN]u8;
const Hash = [Sha256.digest_length]u8;
const Signature = [Sha256.digest_length * 2]u8;

access_id: AccessId,
access_secret: AccessSecretFull,

pub fn init(id: *const AccessId, secret: *const AccessSecret) Self {
    const empty_sercet = V4_PREFIX ++ std.mem.zeroes(AccessSecret);
    var self = .{ .access_id = id.*, .access_secret = empty_sercet.* };
    @memcpy(self.access_secret[V4_PREFIX.len..][0..ACCESS_SECRET_LEN], secret);
    return self;
}

test "init" {
    const signer = init(tests.ACCESS_ID, tests.ACCESS_SECRET);
    try testing.expectEqualStrings(tests.ACCESS_ID, &signer.access_id);
    try testing.expectEqualStrings(V4_PREFIX ++ tests.ACCESS_SECRET, &signer.access_secret);
}

pub fn handle(self: Self, buffer: []u8, content: RequestContent, time: RequestTime, target: RequestTarget) ![]const u8 {
    var signature: Signature = undefined;
    var scope_buffer: [64]u8 = undefined;
    const scope = try requestScope(&scope_buffer, &time.date, target);
    try sign(&self.access_secret, &signature, time, target, content, scope);
    return authorize(buffer, &self.access_id, scope, content.headers_signed, &signature);
}

test "handle" {
    const signer = init(tests.ACCESS_ID, tests.ACCESS_SECRET);
    const request = try tests.demoRequest(testing.allocator);
    defer request.deinit(testing.allocator);

    var buffer: [256]u8 = undefined;
    const target = RequestTarget{ .region = .us_east_1, .service = "s3" };
    const auth = try signer.handle(&buffer, request, RequestTime.initEpoch(1373321335), target);
    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130708/us-east-1/s3/aws4_request," ++
            "SignedHeaders=host;x-amz-date,Signature=2fc8cfe69048f0656cd02e9655fb2cb93c8917ac1230890b5a2752ef6ba76c90",
        auth,
    );
}

// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
/// Compute the request signature.
fn sign(secret: *const AccessSecretFull, out: *Signature, time: RequestTime, target: RequestTarget, content: RequestContent, scope: []const u8) !void {
    var canonical_buffer: [1024]u8 = undefined;
    const canonical = try requestCanonical(&canonical_buffer, content);
    hashPayload(out, canonical);

    var key: Hash = undefined;
    var sign_buffer: SigContent = undefined;
    const signable = try signatureContent(&sign_buffer, &time.timestamp, scope, out);
    signatureKey(&key, secret, &time.date, target);
    Hmac.create(&key, signable, &key);
    formatHex(out, &key);
}

test "sign" {
    const request = try tests.demoRequest(testing.allocator);
    defer request.deinit(testing.allocator);

    var hash: Signature = undefined;
    try sign(V4_PREFIX ++ tests.ACCESS_SECRET, &hash, RequestTime.initEpoch(1373321335), .{
        .region = .us_east_1,
        .service = "s3",
    }, request, "20130708/us-east-1/s3");
    try testing.expectEqualStrings("2fc8cfe69048f0656cd02e9655fb2cb93c8917ac1230890b5a2752ef6ba76c90", &hash);
}

fn authorize(buffer: []u8, id: []const u8, scope: []const u8, headers: []const u8, signature: *const Signature) ![]const u8 {
    var stream = std.io.fixedBufferStream(buffer);
    try stream.writer().print(
        V4_ALGO ++ " Credential={s}/{s}/" ++ V4_SUFFIX ++ ",SignedHeaders={s},Signature={s}",
        .{ id, scope, headers, signature },
    );
    return buffer[0..stream.pos];
}

test "authorize" {
    var buffer: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130708/us-east-1/s3/aws4_request," ++
            "SignedHeaders=host;x-amz-date,Signature=2fc8cfe69048f0656cd02e9655fb2cb93c8917ac1230890b5a2752ef6ba76c90",
        try authorize(&buffer, tests.ACCESS_ID, "20130708/us-east-1/s3", "host;x-amz-date", "2fc8cfe69048f0656cd02e9655fb2cb93c8917ac1230890b5a2752ef6ba76c90"),
    );
}

fn requestScope(out: []u8, date: []const u8, target: RequestTarget) ![]const u8 {
    var stream = std.io.fixedBufferStream(out);
    try stream.writer().print("{s}/{s}/{s}", .{ date, target.region.code(), target.service });
    return out[0..stream.pos];
}

test "requestScope" {
    var buffer: [64]u8 = undefined;
    const target = RequestTarget{ .region = .us_east_1, .service = "s3" };
    const scope = try requestScope(&buffer, "20130708", target);
    try testing.expectEqualStrings("20130708/us-east-1/s3", scope);
}

/// The caller owns the returned memory.
// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html#create-canonical-request
fn requestCanonical(buffer: []u8, request: RequestContent) ![]u8 {
    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();
    try writer.print(
        "{s}\n{s}\n{s}{s}\n{s}",
        .{ @tagName(request.method), request.path, request.query, request.headers, request.headers_signed },
    );
    try writer.writeByte('\n');
    var hash: Signature = undefined;
    hashPayload(&hash, request.payload);
    try writer.writeAll(&hash);
    return buffer[0..stream.pos];
}

test "requestCanonical" {
    const request = try tests.demoRequest(testing.allocator);
    defer request.deinit(testing.allocator);

    var canonical_buffer: [4 * 1024]u8 = undefined;
    const canonical = try requestCanonical(&canonical_buffer, request);
    const expected = "GET\n/foo\nbaz=%24qux&foo=%25bar\nhost:s3.amazonaws.com\nx-amz-date:20130708T220855Z" ++
        "\nhost;x-amz-date\n269dce1a5bb90188b2d9cf542a7c30e410c7d8251e34a97bfea56062df51ae23";
    try testing.expectEqualStrings(expected, canonical);
}

// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html#create-string-to-sign
fn signatureContent(buffer: *SigContent, timestamp: []const u8, scope: []const u8, hash: *const Signature) ![]const u8 {
    var stream = std.io.fixedBufferStream(buffer);
    try stream.writer().print(V4_ALGO ++ "\n{s}\n{s}/" ++ V4_SUFFIX ++ "\n{s}", .{ timestamp, scope, hash });
    return buffer[0..stream.pos];
}

test "signatureContent" {
    const time = RequestTime.initEpoch(1373321335);
    const hash_buff = "907ae221d7a1aaf07c909ec72d09a3dba409a040b5f3f0914eb28425ce27ef0a";
    var content_buff: SigContent = undefined;
    const signature = try signatureContent(&content_buff, &time.timestamp, "20130708/us-east-1/s3", hash_buff);
    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256\n20130708T220855Z\n20130708/us-east-1/s3/aws4_request\n" ++
            "907ae221d7a1aaf07c909ec72d09a3dba409a040b5f3f0914eb28425ce27ef0a",
        signature,
    );
}

// https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_aws-signing.html
fn signatureKey(out: *Hash, secret: *const AccessSecretFull, date: []const u8, target: RequestTarget) void {
    Hmac.create(out, date, secret);
    Hmac.create(out, target.region.code(), out);
    Hmac.create(out, target.service, out);
    Hmac.create(out, V4_SUFFIX, out);
}

test "signatureKey" {
    var key: Hash = undefined;
    const target = RequestTarget{ .region = .us_east_1, .service = "s3" };
    signatureKey(&key, V4_PREFIX ++ tests.ACCESS_SECRET, "20130708", target);
    try testing.expectEqualSlices(u8, &.{
        0x22, 0x68, 0xF9, 0x05, 0x25, 0xE3, 0x36, 0x80, 0x16, 0xC7, 0xBD, 0x2E, 0x46, 0x9C, 0x30, 0x5A,
        0x2A, 0xBF, 0xB3, 0x7C, 0xF1, 0x51, 0x5C, 0x52, 0x4F, 0xC1, 0x24, 0x7E, 0xBA, 0xB2, 0x76, 0x55,
    }, &key);
}

fn hashPayload(out: *Signature, payload: ?[]const u8) void {
    if (payload) |pld| {
        var hash: Hash = undefined;
        Sha256.hash(pld, &hash, .{});
        formatHex(out, &hash);
    } else {
        @memcpy(out, EMPTY_PAYLOAD);
    }
}

test "hashPayload" {
    var buffer: Signature = undefined;
    hashPayload(&buffer, "");
    try testing.expectEqualStrings(EMPTY_PAYLOAD, &buffer);

    hashPayload(&buffer, "foo-bar-baz");
    const expected = "269dce1a5bb90188b2d9cf542a7c30e410c7d8251e34a97bfea56062df51ae23";
    try testing.expectEqualStrings(expected, &buffer);
}

fn formatHex(out: *Signature, payload: []const u8) void {
    std.debug.assert(payload.len == Sha256.digest_length);
    var hex = std.io.fixedBufferStream(out);
    hex.writer().print("{}", .{std.fmt.fmtSliceHexLower(payload)}) catch unreachable;
}

test "formatHex" {
    var buffer: Signature = undefined;
    formatHex(&buffer, &.{
        0x2f, 0xc8, 0xcf, 0xe6, 0x90, 0x48, 0xf0, 0x65, 0x6c, 0xd0, 0x2e, 0x96, 0x55, 0xfb, 0x2c, 0xb9,
        0x3c, 0x89, 0x17, 0xac, 0x12, 0x30, 0x89, 0x0b, 0x5a, 0x27, 0x52, 0xef, 0x6b, 0xa7, 0x6c, 0x90,
    });
    try testing.expectEqualStrings("2fc8cfe69048f0656cd02e9655fb2cb93c8917ac1230890b5a2752ef6ba76c90", &buffer);
}
