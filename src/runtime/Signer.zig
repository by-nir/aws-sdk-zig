const std = @import("std");
const testing = std.testing;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const format = @import("format.zig");

const ACCESS_ID_LEN = 20;
const ACCESS_SECRET_LEN = 40;
const V4_PREFIX = "AWS4";
const V4_SUFFIX = "aws4_request";
const V4_ALGO = "AWS4-HMAC-SHA256";

const Self = @This();
const AccessId = [ACCESS_ID_LEN]u8;
const AccessSecret = [ACCESS_SECRET_LEN]u8;
const AccessSecretFull = [V4_PREFIX.len + ACCESS_SECRET_LEN]u8;
const SignatureBuffer = [512]u8;
const CanonicalBuffer = [2 * 1024]u8;

pub const Event = struct {
    service: []const u8,
    region: []const u8,
    date: []const u8,
    timestamp: []const u8,
};

pub const Content = struct {
    method: std.http.Method,
    path: []const u8,
    query: []const u8,
    headers: []const u8,
    headers_names: []const u8,
    payload_hash: []const u8,
};

access_id: AccessId,
access_secret: AccessSecretFull,

pub fn init(id: *const AccessId, secret: *const AccessSecret) Self {
    const empty_sercet = V4_PREFIX ++ std.mem.zeroes(AccessSecret);
    var self = .{ .access_id = id.*, .access_secret = empty_sercet.* };
    @memcpy(self.access_secret[V4_PREFIX.len..][0..ACCESS_SECRET_LEN], secret);
    return self;
}

test "init" {
    const signer = init(TEST_ID, TEST_SECRET);
    try testing.expectEqualStrings(TEST_ID, &signer.access_id);
    try testing.expectEqualStrings(V4_PREFIX ++ TEST_SECRET, &signer.access_secret);
}

// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
pub fn handle(self: Self, buffer: []u8, event: Event, content: Content) ![]const u8 {
    var signature: format.HashStr = undefined;
    var scope_buffer: [64]u8 = undefined;
    const scope = try requestScope(&scope_buffer, event);
    try sign(&self.access_secret, &signature, event, content, scope);
    return authorize(buffer, &self.access_id, scope, content.headers_names, &signature);
}

test "handle" {
    const signer = init(TEST_ID, TEST_SECRET);
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130708/us-east-1/s3/aws4_request," ++
            "SignedHeaders=host;x-amz-date,Signature=3c059efad8b5c07bbe759cb31436857114cb986b161695c03ef115e4878ea945",
        try signer.handle(&buffer, TEST_EVENT, TEST_CONTENT),
    );
}

/// Compute the request signature.
fn sign(secret: *const AccessSecretFull, out: *format.HashStr, event: Event, content: Content, scope: []const u8) !void {
    var canonical_buffer: CanonicalBuffer = undefined;
    const canonical = try requestCanonical(&canonical_buffer, content);
    format.hashString(out, canonical);

    var key: format.Hash = undefined;
    var sig_buffer: SignatureBuffer = undefined;
    const signable = try signatureContent(&sig_buffer, event.timestamp, scope, out);
    signatureKey(&key, secret, event);
    Hmac.create(&key, signable, &key);

    std.debug.assert(out.len >= 2 * key.len);
    _ = format.hexString(out, .lower, &key) catch unreachable;
}

test "sign" {
    var hash: format.HashStr = undefined;
    try sign(V4_PREFIX ++ TEST_SECRET, &hash, TEST_EVENT, TEST_CONTENT, TEST_SCOPE);
    try testing.expectEqualStrings("3c059efad8b5c07bbe759cb31436857114cb986b161695c03ef115e4878ea945", &hash);
}

/// Create an authorization header for the request.
fn authorize(buffer: []u8, id: []const u8, scope: []const u8, headers: []const u8, signature: *const format.HashStr) ![]const u8 {
    var stream = std.io.fixedBufferStream(buffer);
    try stream.writer().print(
        V4_ALGO ++ " Credential={s}/{s}/" ++ V4_SUFFIX ++ ",SignedHeaders={s},Signature={s}",
        .{ id, scope, headers, signature },
    );
    return buffer[0..stream.pos];
}

test "authorize" {
    var buffer: SignatureBuffer = undefined;
    const expected = "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130708/us-east-1/s3/aws4_request," ++
        "SignedHeaders=host;x-amz-date,Signature=2fc8cfe69048f0656cd02e9655fb2cb93c8917ac1230890b5a2752ef6ba76c90";
    const actual = try authorize(&buffer, TEST_ID, TEST_SCOPE, TEST_CONTENT.headers_names, "2fc8cfe69048f0656cd02e9655fb2cb93c8917ac1230890b5a2752ef6ba76c90");
    try testing.expectEqualStrings(expected, actual);
}

fn requestScope(out: []u8, event: Event) ![]const u8 {
    var stream = std.io.fixedBufferStream(out);
    try stream.writer().print("{s}/{s}/{s}", .{ event.date, event.region, event.service });
    return out[0..stream.pos];
}

test "requestScope" {
    var buffer: [64]u8 = undefined;
    const scope = try requestScope(&buffer, TEST_EVENT);
    try testing.expectEqualStrings(TEST_SCOPE, scope);
}

/// The caller owns the returned memory.
// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html#create-canonical-request
fn requestCanonical(buffer: []u8, content: Content) ![]u8 {
    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();
    try writer.print(
        "{s}\n{s}\n{s}\n{s}\n{s}\n{s}",
        .{ @tagName(content.method), content.path, content.query, content.headers, content.headers_names, content.payload_hash },
    );
    return buffer[0..stream.pos];
}

test "requestCanonical" {
    var canonical_buffer: CanonicalBuffer = undefined;
    const canonical = try requestCanonical(&canonical_buffer, TEST_CONTENT);
    const expected = "GET\n/foo\nbaz=%24qux&foo=%25bar\nhost:s3.amazonaws.com\nx-amz-date:20130708T220855Z\n" ++
        "\nhost;x-amz-date\n269dce1a5bb90188b2d9cf542a7c30e410c7d8251e34a97bfea56062df51ae23";
    try testing.expectEqualStrings(expected, canonical);
}

// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html#create-string-to-sign
fn signatureContent(buffer: *SignatureBuffer, timestamp: []const u8, scope: []const u8, hash: *const format.HashStr) ![]const u8 {
    var stream = std.io.fixedBufferStream(buffer);
    try stream.writer().print(V4_ALGO ++ "\n{s}\n{s}/" ++ V4_SUFFIX ++ "\n{s}", .{ timestamp, scope, hash });
    return buffer[0..stream.pos];
}

test "signatureContent" {
    var content_buff: SignatureBuffer = undefined;
    const hash_buff = "907ae221d7a1aaf07c909ec72d09a3dba409a040b5f3f0914eb28425ce27ef0a";
    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256\n20130708T220855Z\n20130708/us-east-1/s3/aws4_request\n" ++ hash_buff,
        try signatureContent(&content_buff, TEST_EVENT.timestamp, TEST_SCOPE, hash_buff),
    );
}

// https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_aws-signing.html
fn signatureKey(out: *format.Hash, secret: *const AccessSecretFull, event: Event) void {
    Hmac.create(out, event.date, secret);
    Hmac.create(out, event.region, out);
    Hmac.create(out, event.service, out);
    Hmac.create(out, V4_SUFFIX, out);
}

test "signatureKey" {
    var key: format.Hash = undefined;
    signatureKey(&key, V4_PREFIX ++ TEST_SECRET, TEST_EVENT);
    try testing.expectEqualSlices(u8, &.{
        0x22, 0x68, 0xF9, 0x05, 0x25, 0xE3, 0x36, 0x80, 0x16, 0xC7, 0xBD, 0x2E, 0x46, 0x9C, 0x30, 0x5A,
        0x2A, 0xBF, 0xB3, 0x7C, 0xF1, 0x51, 0x5C, 0x52, 0x4F, 0xC1, 0x24, 0x7E, 0xBA, 0xB2, 0x76, 0x55,
    }, &key);
}

const TEST_ID = "AKIAIOSFODNN7EXAMPLE";
const TEST_SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
const TEST_EVENT = Event{
    .service = "s3",
    .region = "us-east-1",
    .date = "20130708",
    .timestamp = "20130708T220855Z",
};
const TEST_SCOPE = "20130708/us-east-1/s3";
const TEST_CONTENT = Content{
    .method = .GET,
    .path = "/foo",
    .query = "baz=%24qux&foo=%25bar",
    .headers = "host:s3.amazonaws.com\nx-amz-date:20130708T220855Z\n",
    .headers_names = "host;x-amz-date",
    .payload_hash = "269dce1a5bb90188b2d9cf542a7c30e410c7d8251e34a97bfea56062df51ae23",
};
