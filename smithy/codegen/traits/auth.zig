//! Authentication traits
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/authentication-traits.html)
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const SmithyId = @import("../model.zig").SmithyId;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;
const JsonReader = @import("../utils/JsonReader.zig");

pub const registry: TraitsRegistry = &.{
    .{ Auth.id, Auth.parse },
    // smithy.api#authDefinition
    .{ http_basic_id, null },
    .{ http_bearer_id, null },
    .{ http_digest_id, null },
    .{ HttpApiKey.id, HttpApiKey.parse },
    .{ optional_auth_id, null },
};

pub const AuthId = enum(u64) {
    none = parse("00000000"),
    http_basic = parse("smithy.api#httpBasicAuth"),
    http_bearer = parse("smithy.api#httpBearerAuth"),
    http_api_key = parse("smithy.api#httpApiKeyAuth"),
    http_digest = parse("smithy.api#httpDigestAuth"),
    _,

    pub fn of(trait_id: []const u8) AuthId {
        return @enumFromInt(parse(trait_id));
    }

    fn parse(s: []const u8) u64 {
        var bytes: [8]u8 = "00000000".*;
        const trim = if (std.mem.indexOfScalar(u8, s, '#')) |i| s[i + 1 .. s.len] else s;
        const len = @min(8, trim.len);
        @memcpy(bytes[0..len], trim[0..len]);
        return std.mem.bytesToValue(u64, &bytes);
    }

    pub fn toString(self: *const AuthId) []const u8 {
        const str = std.mem.asBytes(self);
        return std.mem.sliceTo(str, '0');
    }
};

test "AuthId" {
    try testing.expectEqual(AuthId.http_basic, AuthId.of("httpBasicAuth"));
    try testing.expectEqual(AuthId.http_basic, AuthId.of("smithy.api#httpBasicAuth"));
    try testing.expectEqual(AuthId.of("foo00000"), AuthId.of("foo"));
    try testing.expectEqualStrings("foo", AuthId.of("foo").toString());
}

/// Indicates that a service supports HTTP Basic Authentication as defined in
/// [RFC 2617](https://datatracker.ietf.org/doc/html/rfc2617.html).
///
/// [Smithy Spec](https://smithy.io/2.0/spec/authentication-traits.html#httpbasicauth-trait)
pub const http_basic_id = SmithyId.of("smithy.api#httpBasicAuth");

/// Indicates that a service supports HTTP Bearer Authentication as defined in
/// [RFC 6750](https://datatracker.ietf.org/doc/html/rfc6750.html).
///
/// [Smithy Spec](https://smithy.io/2.0/spec/authentication-traits.html#httpbearerauth-trait)
pub const http_bearer_id = SmithyId.of("smithy.api#httpBearerAuth");

/// Indicates that a service supports HTTP Digest Authentication as defined in
/// [RFC 2617](https://datatracker.ietf.org/doc/html/rfc2617.html).
///
/// [Smithy Spec](https://smithy.io/2.0/spec/authentication-traits.html#httpdigestauth-trait)
pub const http_digest_id = SmithyId.of("smithy.api#httpDigestAuth");

/// Indicates that an operation MAY be invoked without authentication,
/// regardless of any authentication traits applied to the operation.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/authentication-traits.html#optionalauth-trait)
pub const optional_auth_id = SmithyId.of("smithy.api#optionalAuth");

/// Indicates that a service supports HTTP-specific authentication using an API
/// key sent in a header or query string parameter.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/authentication-traits.html#httpapikeyauth-trait)
pub const HttpApiKey = struct {
    pub const id = SmithyId.of("smithy.api#httpApiKeyAuth");

    pub const Value = struct {
        /// Defines the name of the HTTP header or query string parameter that contains the API key.
        name: []const u8,
        /// Defines the location of where the key is serialized.
        target: Target,
        /// Defines the scheme to use on the `Authorization` header value.
        scheme: ?[]const u8 = null,
    };

    pub const Target = enum { header, query };

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        const value = try arena.create(Value);
        errdefer arena.destroy(value);

        try reader.nextObjectBegin();
        while (try reader.peek() != .object_end) {
            const prop = try reader.nextString();
            if (mem.eql(u8, prop, "name")) {
                value.name = try reader.nextStringAlloc(arena);
            } else if (mem.eql(u8, prop, "in")) {
                const target = try reader.nextString();
                if (mem.eql(u8, target, "header")) {
                    value.target = .header;
                } else if (mem.eql(u8, target, "query")) {
                    value.target = .query;
                } else {
                    return error.AuthHttpApiKeyInvalidTarget;
                }
            } else if (mem.eql(u8, prop, "scheme")) {
                value.scheme = try reader.nextStringAlloc(arena);
            } else {
                std.log.warn("Unknown httpApiKeyAuth trait property `{s}`", .{prop});
                try reader.skipValueOrScope();
            }
        }
        try reader.nextObjectEnd();

        return value;
    }

    pub fn get(symbols: *SymbolsProvider, shape_id: SmithyId) ?Value {
        return symbols.getTrait(Value, shape_id, id);
    }
};

test HttpApiKey {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc,
        \\{
        \\    "name": "Authorization",
        \\    "in": "header",
        \\    "scheme": "ApiKey"
        \\}
    );
    errdefer reader.deinit();

    const auth: *const HttpApiKey.Value = @ptrCast(@alignCast(try HttpApiKey.parse(arena_alloc, &reader)));
    reader.deinit();
    try testing.expectEqualDeep(&HttpApiKey.Value{
        .name = "Authorization",
        .target = .header,
        .scheme = "ApiKey",
    }, auth);
}

/// Defines the priority ordered authentication schemes supported by a service or operation.
///
/// When applied to a service, it defines the default authentication schemes of
/// every operation in the service.
/// When applied to an operation, it defines the list of all authentication schemes
/// supported by the operation, overriding any auth trait specified on a service.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/authentication-traits.html#auth-trait)
pub const Auth = struct {
    pub const id = SmithyId.of("smithy.api#auth");

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        var list = std.ArrayList(AuthId).init(arena);
        errdefer list.deinit();

        try reader.nextArrayBegin();
        while (try reader.peek() != .array_end) {
            const name = try reader.nextString();
            try list.append(AuthId.of(name));
        }

        const slice = try list.toOwnedSliceSentinel(AuthId.none);
        return @ptrCast(slice.ptr);
    }

    pub fn get(symbols: *SymbolsProvider, shape_id: SmithyId) ?[]const AuthId {
        const trait = symbols.getTraitOpaque(shape_id, id);
        return if (trait) |ptr| cast(ptr) else null;
    }

    fn cast(ptr: *const anyopaque) []const AuthId {
        var i: usize = 0;
        const schemes: [*]const AuthId = @ptrCast(@alignCast(ptr));
        while (true) : (i += 1) {
            if (schemes[i] == AuthId.none) return schemes[0..i];
        }
        unreachable;
    }
};

test Auth {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc, "[ \"foo\", \"bar\" ]");
    errdefer reader.deinit();

    const schemes = Auth.cast(try Auth.parse(arena_alloc, &reader));
    reader.deinit();
    try testing.expectEqualDeep(&[_]AuthId{ AuthId.of("foo"), AuthId.of("bar") }, schemes);
}
