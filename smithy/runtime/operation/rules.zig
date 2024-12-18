const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = std.testing.allocator;

/// [Smithy Spec](https://smithy.io/2.0/additional-specs/rules-engine/standard-library.html#url-structure)
pub const RulesUrl = struct {
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

    pub fn init(allocator: Allocator, value: []const u8) !RulesUrl {
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

        return RulesUrl{
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

    pub fn deinit(self: RulesUrl) void {
        if (self.did_alloc_path) self.allocator.free(self.normalized_path);
        if (self.did_alloc_authority) self.allocator.free(self.authority);
    }

    fn expect(expected: RulesUrl, value: []const u8) !void {
        const url = try RulesUrl.init(expected.allocator, value);
        defer url.deinit();

        try testing.expectEqualStrings(expected.scheme, url.scheme);
        try testing.expectEqualStrings(expected.authority, url.authority);
        try testing.expectEqualStrings(expected.path, url.path);
        try testing.expectEqualStrings(expected.normalized_path, url.normalized_path);
        try testing.expectEqual(expected.is_ip, url.is_ip);
    }
};

test "RulesUrl" {
    try testing.expectError(
        error.InvalidUrlComponents,
        RulesUrl.init(test_alloc, "https://example.com:8443?foo=bar&faz=baz"),
    );
    try testing.expectError(
        error.MissingUrlHost,
        RulesUrl.init(test_alloc, "https:///foo/bar"),
    );

    try RulesUrl.expect(.{
        .allocator = test_alloc,
        .scheme = "https",
        .authority = "example.com",
        .path = "/",
        .normalized_path = "/",
        .is_ip = false,
    }, "https://example.com");

    try RulesUrl.expect(.{
        .allocator = test_alloc,
        .scheme = "http",
        .authority = "example.com:80",
        .path = "/foo/bar",
        .normalized_path = "/foo/bar/",
        .is_ip = false,
    }, "http://example.com:80/foo/bar");

    try RulesUrl.expect(.{
        .allocator = test_alloc,
        .scheme = "https",
        .authority = "127.0.0.1",
        .path = "/",
        .normalized_path = "/",
        .is_ip = true,
    }, "https://127.0.0.1");

    try RulesUrl.expect(.{
        .allocator = test_alloc,
        .scheme = "https",
        .authority = "[fe80::1]",
        .path = "/",
        .normalized_path = "/",
        .is_ip = true,
    }, "https://[fe80::1]");
}

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
            if (!std.ascii.isAlphanumeric(char) and char != '-') return false;
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

// https://github.com/smithy-lang/smithy-rs/blob/main/rust-runtime/inlineable/src/endpoint_lib/substring.rs
pub fn substring(value: []const u8, start: usize, end: usize, reverse: bool) ![]const u8 {
    if (start >= end) return error.InvalidRange;
    if (end > value.len) return error.RangeOutOfBounds;
    for (value) |c| if (!std.ascii.isASCII(c)) return error.InvalidAscii;

    return if (reverse)
        value[value.len - end .. value.len - start]
    else
        value[start..end];
}

test "substring" {
    try testing.expectEqualStrings("he", try substring("hello", 0, 2, false));
    try testing.expectEqualStrings("hello", try substring("hello", 0, 5, false));
    try testing.expectError(error.InvalidRange, substring("hello", 0, 0, false));
    try testing.expectError(error.RangeOutOfBounds, substring("hello", 0, 6, false));

    try testing.expectEqualStrings("lo", try substring("hello", 0, 2, true));
    try testing.expectEqualStrings("hello", try substring("hello", 0, 5, true));
    try testing.expectError(error.InvalidRange, substring("hello", 0, 0, true));

    try testing.expectError(error.InvalidAscii, substring("a🐱b", 0, 2, false));
}
