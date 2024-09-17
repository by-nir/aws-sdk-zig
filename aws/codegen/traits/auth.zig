//! AWS Authentication Traits
//!
//! [Smithy Spec](https://smithy.io/2.0/aws/aws-auth.html#aws-authentication-traits)
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const smithy = @import("smithy/codegen");
const SmithyId = smithy.SmithyId;
const JsonReader = smithy.JsonReader;
const TraitsRegistry = smithy.TraitsRegistry;
const SymbolsProvider = smithy.SymbolsProvider;

// TODO: Remainig traits
pub const traits: TraitsRegistry = &.{
    // aws.auth#cognitoUserPools
    .{ SigV4.id, SigV4.parse },
    .{ SigV4A.id, SigV4A.parse },
    .{ unsigned_payload_id, null },
};

/// Adds support for [AWS signature version 4](https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html)
/// to a service.
///
/// [Smithy Spec](https://smithy.io/2.0/aws/aws-auth.html#aws-auth-sigv4-trait)
pub const SigV4 = AuthTrait("aws.auth#sigv4");

/// Adds support for AWS Signature Version 4 Asymmetric (SigV4A) extension.
///
/// [Smithy Spec](https://smithy.io/2.0/aws/aws-auth.html#aws-auth-sigv4a-trait)
pub const SigV4A = AuthTrait("aws.auth#sigv4a");

/// Indicates that the payload of an operation is not to be part of the signature
/// computed for the request of an operation.
///
/// [Smithy Spec](https://smithy.io/2.0/aws/aws-auth.html#aws-auth-unsignedpayload-trait)
pub const unsigned_payload_id = SmithyId.of("aws.auth#unsignedPayload");

fn AuthTrait(comptime trait_id: []const u8) type {
    return struct {
        pub const id = SmithyId.of(trait_id);
        pub const auth_id = smithy.traits.auth.AuthId.of(trait_id);

        pub const Value = struct {
            /// The signing name to use in the [credential scope](https://docs.aws.amazon.com/general/latest/gr/sigv4-create-string-to-sign.html)
            /// when signing requests.
            name: []const u8,
        };

        pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
            const value = try arena.create(Value);
            errdefer arena.destroy(value);

            var required: usize = 1;
            try reader.nextObjectBegin();
            while (try reader.peek() != .object_end) {
                const prop = try reader.nextString();
                if (mem.eql(u8, prop, "name")) {
                    value.name = try reader.nextStringAlloc(arena);
                    required -= 1;
                } else {
                    std.log.warn("Unknown `" ++ trait_id ++ "` trait property `{s}`", .{prop});
                    try reader.skipValueOrScope();
                }
            }
            try reader.nextObjectEnd();

            if (required > 0) return error.AuthTraitMissingRequiredProperties;
            return value;
        }

        pub fn get(symbols: *SymbolsProvider, shape_id: SmithyId) ?*const Value {
            return symbols.getTrait(Value, shape_id, id);
        }
    };
}

test "AuthTrait" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc,
        \\{ "name": "Foo" }
    );
    errdefer reader.deinit();

    const TestAuth = AuthTrait("smithy.api#testAuth");
    const auth: *const TestAuth.Value = @ptrCast(@alignCast(try TestAuth.parse(arena_alloc, &reader)));
    reader.deinit();
    try testing.expectEqualDeep(&TestAuth.Value{ .name = "Foo" }, auth);
}
