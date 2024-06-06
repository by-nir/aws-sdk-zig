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

const auth = @import("traits/auth.zig");
const behavior = @import("traits/behavior.zig");
const constraint = @import("traits/constraint.zig");
const docs = @import("traits/docs.zig");
const endpoint = @import("traits/endpoint.zig");
const http = @import("traits/http.zig");
const protocol = @import("traits/protocol.zig");
const refine = @import("traits/refine.zig");
const resource = @import("traits/resource.zig");
const stream = @import("traits/stream.zig");
const validate = @import("traits/validate.zig");

const compliance = @import("traits/compliance.zig");
const smoke = @import("traits/smoke.zig");
const waiters = @import("traits/waiters.zig");
const mqtt = @import("traits/mqtt.zig");
const rules = @import("traits/rules.zig");

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
    try manager.registerAll(allocator, auth.traits);
    try manager.registerAll(allocator, behavior.traits);
    try manager.registerAll(allocator, constraint.traits);
    try manager.registerAll(allocator, docs.traits);
    try manager.registerAll(allocator, endpoint.traits);
    try manager.registerAll(allocator, http.traits);
    try manager.registerAll(allocator, protocol.traits);
    try manager.registerAll(allocator, refine.traits);
    try manager.registerAll(allocator, resource.traits);
    try manager.registerAll(allocator, stream.traits);
    try manager.registerAll(allocator, validate.traits);
    try manager.registerAll(allocator, compliance.traits);
    try manager.registerAll(allocator, smoke.traits);
    try manager.registerAll(allocator, waiters.traits);
    try manager.registerAll(allocator, mqtt.traits);
    try manager.registerAll(allocator, rules.traits);
}

test {
    _ = auth;
    _ = behavior;
    _ = constraint;
    _ = docs;
    _ = endpoint;
    _ = http;
    _ = protocol;
    _ = refine;
    _ = resource;
    _ = stream;
    _ = validate;
    _ = compliance;
    _ = smoke;
    _ = waiters;
    _ = mqtt;
    _ = rules;
}
