const std = @import("std");
const testing = std.testing;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const utils = @import("utils.zig");
const stngs = @import("config/settings.zig");

const V4_PREFIX = "AWS4";
const V4_SUFFIX = "aws4_request";
const V4_ALGO = "AWS4-HMAC-SHA256";

const SignatureBuffer = [512]u8;
const CanonicalBuffer = [2 * 1024]u8;
const AccessSecretV4 = [V4_PREFIX.len + stngs.SECRET_LEN]u8;

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

pub const Signer = struct {
    access_id: stngs.AccessId,
    access_secret: AccessSecretV4,

    pub fn init(credentials: stngs.Credentials) Signer {
        var self: Signer = .{
            .access_id = credentials.access_id,
            .access_secret = (V4_PREFIX ++ std.mem.zeroes(stngs.AccessSecret)).*,
        };
        @memcpy(self.access_secret[V4_PREFIX.len..], credentials.access_secret[0..stngs.SECRET_LEN]);
        return self;
    }

    // https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
    pub fn sign(self: Signer, buffer: []u8, event: Event, content: Content) ![]const u8 {
        var signature: utils.HashStr = undefined;
        var scope_buffer: [64]u8 = undefined;
        const scope = try requestScope(&scope_buffer, event);
        try computeSignature(&self.access_secret, &signature, event, content, scope);
        return authorize(buffer, &self.access_id, scope, content.headers_names, &signature);
    }

    /// Compute the request signature.
    fn computeSignature(
        secret: *const AccessSecretV4,
        out: *utils.HashStr,
        event: Event,
        content: Content,
        scope: []const u8,
    ) !void {
        var canonical_buffer: CanonicalBuffer = undefined;
        const canonical = try requestCanonical(&canonical_buffer, content);
        utils.hashString(out, canonical);

        var key: utils.Hash = undefined;
        var sig_buffer: SignatureBuffer = undefined;
        const signable = try signatureContent(&sig_buffer, event.timestamp, scope, out);
        signatureKey(&key, secret, event);
        Hmac.create(&key, signable, &key);

        std.debug.assert(out.len >= 2 * key.len);
        _ = utils.hexString(out, .lower, &key) catch unreachable;
    }

    /// Create an authorization header for the request.
    fn authorize(
        buffer: []u8,
        id: []const u8,
        scope: []const u8,
        headers: []const u8,
        signature: *const utils.HashStr,
    ) ![]const u8 {
        var stream = std.io.fixedBufferStream(buffer);
        try stream.writer().print(
            V4_ALGO ++ " Credential={s}/{s}/" ++ V4_SUFFIX ++ ",SignedHeaders={s},Signature={s}",
            .{ id, scope, headers, signature },
        );
        return stream.getWritten();
    }

    fn requestScope(out: []u8, event: Event) ![]const u8 {
        var stream = std.io.fixedBufferStream(out);
        try stream.writer().print("{s}/{s}/{s}", .{ event.date, event.region, event.service });
        return stream.getWritten();
    }

    /// The caller owns the returned memory.
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

    // https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html#create-string-to-sign
    fn signatureContent(
        buffer: *SignatureBuffer,
        timestamp: []const u8,
        scope: []const u8,
        hash: *const utils.HashStr,
    ) ![]const u8 {
        var stream = std.io.fixedBufferStream(buffer);
        try stream.writer().print(V4_ALGO ++ "\n{s}\n{s}/" ++ V4_SUFFIX ++ "\n{s}", .{ timestamp, scope, hash });
        return stream.getWritten();
    }

    // https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_aws-signing.html
    fn signatureKey(out: *utils.Hash, secret: *const AccessSecretV4, event: Event) void {
        Hmac.create(out, event.date, secret);
        Hmac.create(out, event.region, out);
        Hmac.create(out, event.service, out);
        Hmac.create(out, V4_SUFFIX, out);
    }
};

test "Signer.init" {
    const signer = Signer.init(TEST_CREDS);
    try testing.expectEqualStrings(&TEST_ID, &signer.access_id);
    try testing.expectEqualStrings(V4_PREFIX ++ TEST_SECRET, &signer.access_secret);
}

test "Signer.handle" {
    const signer = Signer.init(TEST_CREDS);
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130708/us-east-1/s3/aws4_request," ++
            "SignedHeaders=host;x-amz-date,Signature=3c059efad8b5c07bbe759cb31436857114cb986b161695c03ef115e4878ea945",
        try signer.sign(&buffer, TEST_EVENT, TEST_CONTENT),
    );
}

test "Signer.sign" {
    var hash: utils.HashStr = undefined;
    try Signer.computeSignature(V4_PREFIX ++ TEST_SECRET, &hash, TEST_EVENT, TEST_CONTENT, TEST_SCOPE);
    try testing.expectEqualStrings("3c059efad8b5c07bbe759cb31436857114cb986b161695c03ef115e4878ea945", &hash);
}

test "Signer.authorize" {
    var buffer: SignatureBuffer = undefined;
    const expected = "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130708/us-east-1/s3/aws4_request," ++
        "SignedHeaders=host;x-amz-date,Signature=2fc8cfe69048f0656cd02e9655fb2cb93c8917ac1230890b5a2752ef6ba76c90";
    const actual = try Signer.authorize(&buffer, &TEST_ID, TEST_SCOPE, TEST_CONTENT.headers_names, "2fc8cfe69048f0656cd02e9655fb2cb93c8917ac1230890b5a2752ef6ba76c90");
    try testing.expectEqualStrings(expected, actual);
}

test "Signer.requestScope" {
    var buffer: [64]u8 = undefined;
    const scope = try Signer.requestScope(&buffer, TEST_EVENT);
    try testing.expectEqualStrings(TEST_SCOPE, scope);
}

test "Signer.requestCanonical" {
    var canonical_buffer: CanonicalBuffer = undefined;
    const canonical = try Signer.requestCanonical(&canonical_buffer, TEST_CONTENT);
    const expected = "GET\n/foo\nbaz=%24qux&foo=%25bar\nhost:s3.amazonaws.com\nx-amz-date:20130708T220855Z\n" ++
        "\nhost;x-amz-date\n269dce1a5bb90188b2d9cf542a7c30e410c7d8251e34a97bfea56062df51ae23";
    try testing.expectEqualStrings(expected, canonical);
}

test "Signer.signatureContent" {
    var content_buff: SignatureBuffer = undefined;
    const hash_buff = "907ae221d7a1aaf07c909ec72d09a3dba409a040b5f3f0914eb28425ce27ef0a";
    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256\n20130708T220855Z\n20130708/us-east-1/s3/aws4_request\n" ++ hash_buff,
        try Signer.signatureContent(&content_buff, TEST_EVENT.timestamp, TEST_SCOPE, hash_buff),
    );
}

test "Signer.signatureKey" {
    var key: utils.Hash = undefined;
    Signer.signatureKey(&key, V4_PREFIX ++ TEST_SECRET, TEST_EVENT);
    try testing.expectEqualSlices(u8, &.{
        0x22, 0x68, 0xF9, 0x05, 0x25, 0xE3, 0x36, 0x80, 0x16, 0xC7, 0xBD, 0x2E, 0x46, 0x9C, 0x30, 0x5A,
        0x2A, 0xBF, 0xB3, 0x7C, 0xF1, 0x51, 0x5C, 0x52, 0x4F, 0xC1, 0x24, 0x7E, 0xBA, 0xB2, 0x76, 0x55,
    }, &key);
}

const TEST_ID: stngs.AccessId = "AKIAIOSFODNN7EXAMPLE".*;
const TEST_SECRET: stngs.AccessSecret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY".*;
const TEST_CREDS = stngs.Credentials{
    .access_id = TEST_ID,
    .access_secret = TEST_SECRET,
};

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
