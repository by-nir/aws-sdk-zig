const std = @import("std");
const TraitsManager = @import("symbols/traits.zig").TraitsManager;
const spc_compliance = @import("specs/compliance.zig");
const spc_smoke = @import("specs/smoke.zig");
const spc_waiters = @import("specs/waiters.zig");
const spc_mqtt = @import("specs/mqtt.zig");
const spc_rules = @import("specs/rules.zig");

pub fn registerTraits(allocator: std.mem.Allocator, manager: *TraitsManager) !void {
    try manager.registerAll(allocator, spc_compliance.traits);
    try manager.registerAll(allocator, spc_smoke.traits);
    try manager.registerAll(allocator, spc_waiters.traits);
    try manager.registerAll(allocator, spc_mqtt.traits);
    try manager.registerAll(allocator, spc_rules.traits);
}

pub const RulesEngine = spc_rules.Public;

test {
    _ = spc_compliance;
    _ = spc_smoke;
    _ = spc_waiters;
    _ = spc_mqtt;
    _ = spc_rules;
}
