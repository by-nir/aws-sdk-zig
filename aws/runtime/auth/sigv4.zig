const std = @import("std");
const testing = std.testing;
const crds = @import("creds.zig");
const hashing = @import("../utils/hashing.zig");
const TimeStr = @import("../utils/TimeStr.zig");

const V4_PREFIX = "AWS4";
const V4_SUFFIX = "aws4_request";
const V4_ALGO = "AWS4-HMAC-SHA256";

pub const SignBuffer = [256]u8;
const SignatureBuffer = [512]u8;
const CanonicalBuffer = [2 * 1024]u8;
const AccessSecretV4 = [V4_PREFIX.len + crds.SECRET_LEN]u8;

pub const Target = struct {
    service: []const u8,
    region: []const u8,
};

pub const Content = struct {
    method: std.http.Method,
    path: []const u8,
    query: []const u8,
    headers: []const u8,
    headers_names: []const u8,
    payload_hash: []const u8,
};

// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
pub fn signV4(out_buffer: *SignBuffer, creds: crds.Credentials, time: TimeStr, target: Target, content: Content) ![]const u8 {
    var secret: AccessSecretV4 = undefined;
    _ = try std.fmt.bufPrint(&secret, V4_PREFIX ++ "{s}", .{creds.access_secret});

    var scope_buffer: [64]u8 = undefined;
    const scope = try requestScope(&scope_buffer, time.date(), target.region, target.service);

    var signature: hashing.HashStr = undefined;
    try computeSignature(&secret, &signature, target, time, content, scope);
    return authorize(out_buffer, creds.access_id, scope, content.headers_names, &signature);
}

test "signV4" {
    var buffer: SignBuffer = undefined;
    const signature = try signV4(&buffer, crds.TEST_CREDS, TEST_TIME, TEST_TARGET, TEST_CONTENT);

    const expected =
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130708/us-east-1/s3/aws4_request," ++
        "SignedHeaders=host;x-amz-date,Signature=3c059efad8b5c07bbe759cb31436857114cb986b161695c03ef115e4878ea945";
    try testing.expectEqualStrings(expected, signature);
}

/// Compute the request signature.
fn computeSignature(secret: *const AccessSecretV4, out: *hashing.HashStr, target: Target, time: TimeStr, content: Content, scope: []const u8) !void {
    var canonical_buffer: CanonicalBuffer = undefined;
    const canonical = try requestCanonical(&canonical_buffer, content);
    hashing.hashString(out, canonical);

    var key: hashing.HashBytes = undefined;
    var sig_buffer: SignatureBuffer = undefined;
    const signable = try signatureContent(&sig_buffer, time.timestamp(), scope, out);
    signatureKey(&key, secret, time.date(), target.region, target.service);
    hashing.Hmac256.create(&key, signable, &key);

    std.debug.assert(out.len >= 2 * key.len);
    _ = hashing.hexString(out, .lower, &key) catch unreachable;
}

test "Signer.computeSignature" {
    var hash: hashing.HashStr = undefined;
    try computeSignature(V4_PREFIX ++ crds.TEST_SECRET, &hash, TEST_TARGET, TEST_TIME, TEST_CONTENT, TEST_SCOPE);
    try testing.expectEqualStrings("3c059efad8b5c07bbe759cb31436857114cb986b161695c03ef115e4878ea945", &hash);
}

/// Create an authorization header for the request.
fn authorize(buffer: []u8, id: []const u8, scope: []const u8, headers: []const u8, signature: *const hashing.HashStr) ![]const u8 {
    var stream = std.io.fixedBufferStream(buffer);
    try stream.writer().print(
        V4_ALGO ++ " Credential={s}/{s}/" ++ V4_SUFFIX ++ ",SignedHeaders={s},Signature={s}",
        .{ id, scope, headers, signature },
    );
    return stream.getWritten();
}

test "Signer.authorize" {
    var buffer: SignatureBuffer = undefined;
    const actual = try authorize(&buffer, crds.TEST_ID, TEST_SCOPE, TEST_CONTENT.headers_names, "2fc8cfe69048f0656cd02e9655fb2cb93c8917ac1230890b5a2752ef6ba76c90");

    const expected = "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130708/us-east-1/s3/aws4_request," ++
        "SignedHeaders=host;x-amz-date,Signature=2fc8cfe69048f0656cd02e9655fb2cb93c8917ac1230890b5a2752ef6ba76c90";
    try testing.expectEqualStrings(expected, actual);
}

fn requestScope(out: []u8, date: TimeStr.Date, region: []const u8, service: []const u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(out);
    try stream.writer().print("{s}/{s}/{s}", .{ date, region, service });
    return stream.getWritten();
}

test "Signer.requestScope" {
    var buffer: [128]u8 = undefined;
    const scope = try requestScope(&buffer, TEST_TIME.date(), TEST_TARGET.region, TEST_TARGET.service);
    try testing.expectEqualStrings(TEST_SCOPE, scope);
}

// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html#create-canonical-request
fn requestCanonical(buffer: []u8, content: Content) ![]u8 {
    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();
    try writer.print("{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
        @tagName(content.method),
        content.path,
        content.query,
        content.headers,
        content.headers_names,
        content.payload_hash,
    });
    return stream.getWritten();
}

test "Signer.requestCanonical" {
    var canonical_buffer: CanonicalBuffer = undefined;
    const canonical = try requestCanonical(&canonical_buffer, TEST_CONTENT);
    const expected = "GET\n/foo\nbaz=%24qux&foo=%25bar\nhost:s3.amazonaws.com\nx-amz-date:20130708T220855Z\n" ++
        "\nhost;x-amz-date\n269dce1a5bb90188b2d9cf542a7c30e410c7d8251e34a97bfea56062df51ae23";
    try testing.expectEqualStrings(expected, canonical);
}

// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html#create-string-to-sign
fn signatureContent(buffer: *SignatureBuffer, timestamp: TimeStr.Timestamp, scope: []const u8, hash: *const hashing.HashStr) ![]const u8 {
    var stream = std.io.fixedBufferStream(buffer);
    try stream.writer().print(V4_ALGO ++ "\n{s}\n{s}/" ++ V4_SUFFIX ++ "\n{s}", .{ timestamp, scope, hash });
    return stream.getWritten();
}

test "Signer.signatureContent" {
    var content_buff: SignatureBuffer = undefined;
    const hash_buff = "907ae221d7a1aaf07c909ec72d09a3dba409a040b5f3f0914eb28425ce27ef0a";
    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256\n20130708T220855Z\n20130708/us-east-1/s3/aws4_request\n" ++ hash_buff,
        try signatureContent(&content_buff, TEST_TIME.timestamp(), TEST_SCOPE, hash_buff),
    );
}

// https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_aws-signing.html
fn signatureKey(out: *hashing.HashBytes, secret: *const AccessSecretV4, date: TimeStr.Date, region: []const u8, service: []const u8) void {
    hashing.Hmac256.create(out, date, secret);
    hashing.Hmac256.create(out, region, out);
    hashing.Hmac256.create(out, service, out);
    hashing.Hmac256.create(out, V4_SUFFIX, out);
}

test "Signer.signatureKey" {
    var key: hashing.HashBytes = undefined;
    signatureKey(&key, V4_PREFIX ++ crds.TEST_SECRET, TEST_TIME.date(), TEST_TARGET.region, TEST_TARGET.service);
    try testing.expectEqualSlices(u8, &.{
        0x22, 0x68, 0xF9, 0x05, 0x25, 0xE3, 0x36, 0x80, 0x16, 0xC7, 0xBD, 0x2E, 0x46, 0x9C, 0x30, 0x5A,
        0x2A, 0xBF, 0xB3, 0x7C, 0xF1, 0x51, 0x5C, 0x52, 0x4F, 0xC1, 0x24, 0x7E, 0xBA, 0xB2, 0x76, 0x55,
    }, &key);
}

const TEST_TARGET = Target{
    .service = "s3",
    .region = "us-east-1",
};
const TEST_SCOPE = "20130708/us-east-1/s3";
const TEST_TIME = TimeStr{ .value = "20130708T220855Z".* };

const TEST_CONTENT = Content{
    .method = .GET,
    .path = "/foo",
    .query = "baz=%24qux&foo=%25bar",
    .headers = "host:s3.amazonaws.com\nx-amz-date:20130708T220855Z\n",
    .headers_names = "host;x-amz-date",
    .payload_hash = "269dce1a5bb90188b2d9cf542a7c30e410c7d8251e34a97bfea56062df51ae23",
};
