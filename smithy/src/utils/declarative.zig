const std = @import("std");
const testing = std.testing;

/// A simple linked list for active stack scoped without heap allocations.
/// As long as all the relevant scopes are not dismissed the whole chain is accessible.
pub fn StackChain(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .Optional => |t| struct {
            const Self = @This();

            value: T = null,
            prev: ?*const Self = null,

            pub fn start(value: t.child) Self {
                return .{ .value = value };
            }

            pub fn append(self: *const Self, value: t.child) Self {
                // If we don't have a value, we set the current value instead of
                // appending a new one.
                return .{
                    .value = value,
                    .prev = if (self.value == null) self.prev else self,
                };
            }
        },
        else => struct {
            const Self = @This();

            value: T,
            prev: ?*const @This() = null,

            pub fn start(value: T) @This() {
                return .{ .value = value };
            }

            pub fn append(self: *const @This(), value: T) @This() {
                return .{
                    .value = value,
                    .prev = self,
                };
            }
        },
    };
}

test "StackChain: same scope linking" {
    const chain = StackChain([]const u8).start("foo").append("bar").append("baz");
    try testing.expectEqualStrings("baz", chain.value);
    try testing.expectEqualStrings("bar", chain.prev.?.value);
    try testing.expectEqualStrings("foo", chain.prev.?.prev.?.value);
}

test "StackChain: cross-scope behavior" {
    const Chain = StackChain([]const u8);
    const Scope = struct {
        fn extend(prev: Chain, append: []const u8) !Chain {
            // Works while all relevant scope are still on the stack:
            const chain = prev.append("bar").append(append);
            try testing.expectEqualStrings("baz", chain.value);
            try testing.expectEqualStrings("bar", chain.prev.?.value);
            try testing.expectEqualStrings("foo", chain.prev.?.prev.?.value);
            return chain;
        }
    };

    // Fails when some of the scopes are dismissed:
    const chain = try Scope.extend(Chain.start("foo"), "baz");
    try testing.expectEqualStrings("baz", chain.value);
    try testing.expect("bar".ptr != chain.prev.?.value.ptr);
}

test "StackChain: optional append" {
    const chain = StackChain(?[]const u8).start("foo").append("bar").append("baz");
    try testing.expectEqualDeep("baz", chain.value);
    try testing.expectEqualDeep("bar", chain.prev.?.value);
    try testing.expectEqualDeep("foo", chain.prev.?.prev.?.value);
}

test "StackChain: optional override" {
    var chain = StackChain(?[]const u8).start("foo").append("REMOVE");
    chain.value = null;
    chain = chain.append("bar");
    try testing.expectEqualDeep("bar", chain.value);
    try testing.expectEqualDeep("foo", chain.prev.?.value);
    try testing.expectEqual(null, chain.prev.?.prev);
}
