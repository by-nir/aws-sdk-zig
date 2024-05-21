const std = @import("std");
const TraitsManager = @import("symbols/traits.zig").TraitsManager;

const compliance = @import("specs/compliance.zig");
const smoke = @import("specs/smoke.zig");
const waiters = @import("specs/waiters.zig");
const mqtt = @import("specs/mqtt.zig");
const rules = @import("specs/rules.zig");

pub fn registerTraits(allocator: std.mem.Allocator, manager: *TraitsManager) !void {
    try manager.registerAll(allocator, compliance.traits);
    try manager.registerAll(allocator, smoke.traits);
    try manager.registerAll(allocator, waiters.traits);
    try manager.registerAll(allocator, mqtt.traits);
    try manager.registerAll(allocator, rules.traits);
}

test {
    _ = compliance;
    _ = smoke;
    _ = waiters;
    _ = mqtt;
    _ = rules;
}
