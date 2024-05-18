//! All Smithy models automatically include a prelude.
//!
//! The prelude defines various simple shapes and every trait defined in the
//! core specification. When using the IDL, shapes defined in the prelude that
//! are not marked with the private trait can be referenced from within any
//! namespace using a relative shape ID.
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/model.html#prelude)

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

const std = @import("std");
const TraitsManager = @import("symbols/traits.zig").TraitsManager;
const trt_auth = @import("prelude/auth.zig");
const trt_behavior = @import("prelude/behavior.zig");
const trt_constraint = @import("prelude/constraint.zig");
const trt_docs = @import("prelude/docs.zig");
const trt_endpoint = @import("prelude/endpoint.zig");
const trt_http = @import("prelude/http.zig");
const trt_protocol = @import("prelude/protocol.zig");
const trt_refine = @import("prelude/refine.zig");
const trt_resource = @import("prelude/resource.zig");
const trt_stream = @import("prelude/stream.zig");
const trt_validate = @import("prelude/validate.zig");

pub fn registerTraits(allocator: std.mem.Allocator, manager: *TraitsManager) !void {
    try manager.registerAll(allocator, trt_auth.traits);
    try manager.registerAll(allocator, trt_behavior.traits);
    try manager.registerAll(allocator, trt_constraint.traits);
    try manager.registerAll(allocator, trt_docs.traits);
    try manager.registerAll(allocator, trt_endpoint.traits);
    try manager.registerAll(allocator, trt_http.traits);
    try manager.registerAll(allocator, trt_protocol.traits);
    try manager.registerAll(allocator, trt_refine.traits);
    try manager.registerAll(allocator, trt_resource.traits);
    try manager.registerAll(allocator, trt_stream.traits);
    try manager.registerAll(allocator, trt_validate.traits);
}

test {
    _ = trt_auth;
    _ = trt_behavior;
    _ = trt_constraint;
    _ = trt_docs;
    _ = trt_endpoint;
    _ = trt_http;
    _ = trt_protocol;
    _ = trt_refine;
    _ = trt_resource;
    _ = trt_stream;
    _ = trt_validate;
}
