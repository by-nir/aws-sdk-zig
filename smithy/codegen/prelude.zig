//! All Smithy models automatically include a prelude.
//!
//! The prelude defines various simple shapes and every trait defined in the
//! core specification. When using the IDL, shapes defined in the prelude that
//! are not marked with the private trait can be referenced from within any
//! namespace using a relative shape ID.
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/model.html#prelude)
const std = @import("std");
const TraitsManager = @import("systems/traits.zig").TraitsManager;

pub const traits = struct {
    pub const auth = @import("traits/auth.zig");
    pub const behavior = @import("traits/behavior.zig");
    pub const constraint = @import("traits/constraint.zig");
    pub const docs = @import("traits/docs.zig");
    pub const endpoint = @import("traits/endpoint.zig");
    pub const http = @import("traits/http.zig");
    pub const protocol = @import("traits/protocol.zig");
    pub const refine = @import("traits/refine.zig");
    pub const resource = @import("traits/resource.zig");
    pub const stream = @import("traits/stream.zig");
    pub const validate = @import("traits/validate.zig");

    pub const compliance = @import("traits/compliance.zig");
    pub const smoke = @import("traits/smoke.zig");
    pub const waiters = @import("traits/waiters.zig");
    pub const mqtt = @import("traits/mqtt.zig");
    pub const rules = @import("traits/rules.zig");
};

pub const TYPE_UNIT = "smithy.api#Unit";
pub const TYPE_BLOB = "smithy.api#Blob";
pub const TYPE_BOOL = "smithy.api#Boolean";
pub const TYPE_STRING = "smithy.api#String";
pub const TYPE_BYTE = "smithy.api#Byte";
pub const TYPE_SHORT = "smithy.api#Short";
pub const TYPE_INT = "smithy.api#Integer";
pub const TYPE_LONG = "smithy.api#Long";
pub const TYPE_FLOAT = "smithy.api#Float";
pub const TYPE_DOUBLE = "smithy.api#Double";
pub const TYPE_BIGINT = "smithy.api#BigInteger";
pub const TYPE_BIGDEC = "smithy.api#BigDecimal";
pub const TYPE_TIMESTAMP = "smithy.api#Timestamp";
pub const TYPE_DOCUMENT = "smithy.api#Document";

pub const PRIMITIVE_BOOL = "smithy.api#PrimitiveBoolean";
pub const PRIMITIVE_BYTE = "smithy.api#PrimitiveByte";
pub const PRIMITIVE_SHORT = "smithy.api#PrimitiveShort";
pub const PRIMITIVE_INT = "smithy.api#PrimitiveInteger";
pub const PRIMITIVE_LONG = "smithy.api#PrimitiveLong";
pub const PRIMITIVE_FLOAT = "smithy.api#PrimitiveFloat";
pub const PRIMITIVE_DOUBLE = "smithy.api#PrimitiveDouble";

pub fn registerTraits(allocator: std.mem.Allocator, manager: *TraitsManager) !void {
    try manager.registerAll(allocator, traits.auth.registry);
    try manager.registerAll(allocator, traits.behavior.registry);
    try manager.registerAll(allocator, traits.constraint.registry);
    try manager.registerAll(allocator, traits.docs.registry);
    try manager.registerAll(allocator, traits.endpoint.registry);
    try manager.registerAll(allocator, traits.http.registry);
    try manager.registerAll(allocator, traits.protocol.registry);
    try manager.registerAll(allocator, traits.refine.registry);
    try manager.registerAll(allocator, traits.resource.registry);
    try manager.registerAll(allocator, traits.stream.registry);

    try manager.registerAll(allocator, traits.validate.registry);
    try manager.registerAll(allocator, traits.compliance.registry);
    try manager.registerAll(allocator, traits.smoke.registry);
    try manager.registerAll(allocator, traits.waiters.registry);
    try manager.registerAll(allocator, traits.mqtt.registry);
    try manager.registerAll(allocator, traits.rules.registry);
}

test {
    _ = traits.auth;
    _ = traits.behavior;
    _ = traits.constraint;
    _ = traits.docs;
    _ = traits.endpoint;
    _ = traits.http;
    _ = traits.protocol;
    _ = traits.refine;
    _ = traits.resource;
    _ = traits.stream;
    _ = traits.validate;
    _ = traits.compliance;
    _ = traits.smoke;
    _ = traits.waiters;
    _ = traits.mqtt;
    _ = traits.rules;
}
