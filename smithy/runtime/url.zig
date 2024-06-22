const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const fmt = std.fmt;
const ascii = std.ascii;
const testing = std.testing;
const test_alloc = std.testing.allocator;

/// [Smithy Spec](https://smithy.io/2.0/additional-specs/rules-engine/standard-library.html#url-structure)
pub const Url = struct {
    allocator: Allocator,
    did_alloc_path: bool = false,
    did_alloc_authority: bool = false,
    /// The URL scheme, such as https.
    scheme: []const u8,
    /// The host and optional port component of the URL.
    authority: []const u8,
    /// The unmodified path segment of the URL.
    path: []const u8,
    /// The path segment of the URL.
    /// This value is guaranteed to start and end with a / character.
    normalized_path: []const u8,
    /// Indicates whether the authority is an IPv4 _or_ IPv6 address.
    is_ip: bool,

    pub fn init(allocator: Allocator, value: []const u8) !Url {
        const uri = try std.Uri.parse(value);
        if (uri.query != null or uri.fragment != null) return error.InvalidUrlComponents;

        var authority = if (uri.host) |h| h.percent_encoded else return error.MissingUrlHost;
        var is_ip = if (std.net.Ip4Address.parse(authority, 0)) |_| true else |_| false;
        if (!is_ip and authority[0] == '[') {
            if (mem.indexOfScalarPos(u8, authority, 1, ']')) |end| {
                is_ip = if (std.net.Ip6Address.parse(authority[1..end], 0)) |_| true else |_| false;
            }
        }

        var did_alloc_authority = false;
        errdefer if (did_alloc_authority) allocator.free(authority);
        if (uri.port) |port| {
            authority = try fmt.allocPrint(allocator, "{s}:{d}", .{ authority, port });
            did_alloc_authority = true;
        }

        var path: []const u8 = "/";
        var normalized: []const u8 = "/";
        var did_alloc_path = false;
        errdefer if (did_alloc_path) allocator.free(normalized);
        if (!uri.path.isEmpty() and !mem.eql(u8, "/", uri.path.percent_encoded)) {
            const raw = uri.path.percent_encoded;
            const prepend = raw[0] != '/';
            const append = raw[raw.len - 1] != '/';

            if (prepend and append) {
                normalized = try fmt.allocPrint(allocator, "/{s}/", .{raw});
                path = normalized[0 .. raw.len + 1];
                did_alloc_path = true;
            } else if (prepend) {
                normalized = try fmt.allocPrint(allocator, "/{s}", .{raw});
                path = normalized[0..raw.len];
                did_alloc_path = true;
            } else if (append) {
                normalized = try fmt.allocPrint(allocator, "{s}/", .{raw});
                path = normalized[0..raw.len];
                did_alloc_path = true;
            } else {
                normalized = raw;
                path = raw[0 .. raw.len - 1];
            }
        }

        return Url{
            .allocator = allocator,
            .did_alloc_path = did_alloc_path,
            .did_alloc_authority = did_alloc_authority,
            .scheme = uri.scheme,
            .authority = authority,
            .path = path,
            .normalized_path = normalized,
            .is_ip = is_ip,
        };
    }

    pub fn deinit(self: Url) void {
        if (self.did_alloc_path) self.allocator.free(self.normalized_path);
        if (self.did_alloc_authority) self.allocator.free(self.authority);
    }

    fn expect(expected: Url, value: []const u8) !void {
        const url = try Url.init(expected.allocator, value);
        defer url.deinit();

        try testing.expectEqualStrings(expected.scheme, url.scheme);
        try testing.expectEqualStrings(expected.authority, url.authority);
        try testing.expectEqualStrings(expected.path, url.path);
        try testing.expectEqualStrings(expected.normalized_path, url.normalized_path);
        try testing.expectEqual(expected.is_ip, url.is_ip);
    }
};

test "Url" {
    try testing.expectError(
        error.InvalidUrlComponents,
        Url.init(test_alloc, "https://example.com:8443?foo=bar&faz=baz"),
    );
    try testing.expectError(
        error.MissingUrlHost,
        Url.init(test_alloc, "https:///foo/bar"),
    );

    try Url.expect(.{
        .allocator = test_alloc,
        .scheme = "https",
        .authority = "example.com",
        .path = "/",
        .normalized_path = "/",
        .is_ip = false,
    }, "https://example.com");

    try Url.expect(.{
        .allocator = test_alloc,
        .scheme = "http",
        .authority = "example.com:80",
        .path = "/foo/bar",
        .normalized_path = "/foo/bar/",
        .is_ip = false,
    }, "http://example.com:80/foo/bar");

    try Url.expect(.{
        .allocator = test_alloc,
        .scheme = "https",
        .authority = "127.0.0.1",
        .path = "/",
        .normalized_path = "/",
        .is_ip = true,
    }, "https://127.0.0.1");

    try Url.expect(.{
        .allocator = test_alloc,
        .scheme = "https",
        .authority = "[fe80::1]",
        .path = "/",
        .normalized_path = "/",
        .is_ip = true,
    }, "https://[fe80::1]");
}

pub fn uriEncode(allocator: Allocator, value: []const u8) ![]const u8 {
    const encoder = UriEncoder{ .raw = value };
    return fmt.allocPrint(allocator, "{}", .{encoder});
}

test "uriEncode" {
    const escaped = try uriEncode(test_alloc, ":/?#[]@!$&'()*+,;=%");
    defer test_alloc.free(escaped);
    try testing.expectEqualStrings("%3A%2F%3F%23%5B%5D%40%21%24%26%27%28%29%2A%2B%2C%3B%3D%25", escaped);
}

// https://github.com/smithy-lang/smithy-rs/blob/main/rust-runtime/aws-smithy-http/src/urlencode.rs
const UriEncoder = struct {
    raw: []const u8,

    pub fn format(self: UriEncoder, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        var start: usize = 0;
        for (self.raw, 0..) |char, index| {
            if (isValidUrlChar(char)) continue;
            try writer.print("{s}%{X:0>2}", .{ self.raw[start..index], char });
            start = index + 1;
        }
        try writer.writeAll(self.raw[start..]);
    }

    fn isValidUrlChar(char: u8) bool {
        return switch (char) {
            // zig fmt: off
            ' ', '/', ':', ',', '?', '#', '[', ']', '{', '}', '|', '@', '!', '$', '&',
            '\'', '(', ')', '*', '+', ';', '=', '%', '<', '>', '"', '^', '`', '\\' => false,
            // zig fmt: on
            else => !ascii.isControl(char),
        };
    }
};

// https://github.com/smithy-lang/smithy-rs/blob/main/rust-runtime/inlineable/src/endpoint_lib/host.rs
pub fn isValidHostLabel(label: []const u8, allow_dots: bool) bool {
    if (allow_dots) {
        var it = mem.splitScalar(u8, label, '.');
        while (it.next()) |part| {
            if (!isValidHostLabel(part, false)) return false;
        }
    } else {
        if (label.len == 0 or label.len > 63) return false;
        if (label[0] == '-') return false;
        for (label) |char| {
            if (!ascii.isAlphanumeric(char) and char != '-') return false;
        }
    }
    return true;
}

test "isValidHostLabel" {
    try testing.expectEqual(false, isValidHostLabel("", false));
    try testing.expectEqual(false, isValidHostLabel("", true));
    try testing.expectEqual(false, isValidHostLabel(".", true));
    try testing.expectEqual(true, isValidHostLabel("a.b", true));
    try testing.expectEqual(false, isValidHostLabel("a.b", false));
    try testing.expectEqual(false, isValidHostLabel("a.b.", true));
    try testing.expectEqual(true, isValidHostLabel("a.b.c", true));
    try testing.expectEqual(false, isValidHostLabel("a_b", true));
    try testing.expectEqual(false, isValidHostLabel("a" ** 64, false));
    try testing.expect(isValidHostLabel("a" ** 63 ++ "." ++ "a" ** 63, true));

    try testing.expectEqual(false, isValidHostLabel("-foo", false));
    try testing.expectEqual(false, isValidHostLabel("-foo", true));
    try testing.expectEqual(false, isValidHostLabel(".foo", true));
    try testing.expectEqual(true, isValidHostLabel("a-b.foo", true));
}
