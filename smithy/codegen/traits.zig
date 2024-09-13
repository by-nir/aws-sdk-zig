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

pub const prelude = struct {
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

pub fn registerTraits(allocator: std.mem.Allocator, manager: *TraitsManager) !void {
    try manager.registerAll(allocator, prelude.auth.registry);
    try manager.registerAll(allocator, prelude.behavior.registry);
    try manager.registerAll(allocator, prelude.constraint.registry);
    try manager.registerAll(allocator, prelude.docs.registry);
    try manager.registerAll(allocator, prelude.endpoint.registry);
    try manager.registerAll(allocator, prelude.http.registry);
    try manager.registerAll(allocator, prelude.protocol.registry);
    try manager.registerAll(allocator, prelude.refine.registry);
    try manager.registerAll(allocator, prelude.resource.registry);
    try manager.registerAll(allocator, prelude.stream.registry);

    try manager.registerAll(allocator, prelude.validate.registry);
    try manager.registerAll(allocator, prelude.compliance.registry);
    try manager.registerAll(allocator, prelude.smoke.registry);
    try manager.registerAll(allocator, prelude.waiters.registry);
    try manager.registerAll(allocator, prelude.mqtt.registry);
    try manager.registerAll(allocator, prelude.rules.registry);
}

test {
    _ = prelude.auth;
    _ = prelude.behavior;
    _ = prelude.constraint;
    _ = prelude.docs;
    _ = prelude.endpoint;
    _ = prelude.http;
    _ = prelude.protocol;
    _ = prelude.refine;
    _ = prelude.resource;
    _ = prelude.stream;
    _ = prelude.validate;
    _ = prelude.compliance;
    _ = prelude.smoke;
    _ = prelude.waiters;
    _ = prelude.mqtt;
    _ = prelude.rules;
}
