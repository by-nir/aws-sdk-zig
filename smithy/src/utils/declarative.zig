const std = @import("std");
const testing = std.testing;

/// A simple linked list for active stack scoped without heap allocations.
/// As long as all the relevant scopes are not dismissed the whole chain is accessible.
pub fn StackChain(comptime T: type) type {
    const is_optional = @typeInfo(T) == .Optional;
    const Value = if (is_optional) @typeInfo(T).Optional.child else T;

    return struct {
        const Self = @This();

        value: T = if (is_optional) null else undefined,
        prev: ?*const Self = null,

        pub fn start(value: Value) Self {
            return .{ .value = value };
        }

        pub fn append(self: *const Self, value: Value) Self {
            return .{
                .value = value,
                .prev = if (is_optional and self.value == null) self.prev else self,
            };
        }

        pub fn isEmpty(self: *const Self) bool {
            if (is_optional) {
                return self.value == null and self.prev == null;
            } else {
                return false;
            }
        }

        pub fn unwrap(self: *const Self, buffer: []Value) ![]const Value {
            if (is_optional and self.value == null) return &.{};

            var count: usize = 1;
            var current = self.prev;
            while (current) |c| : (count += 1) {
                current = c.prev;
            }

            if (count > buffer.len) {
                return error.InsufficientBufferSize;
            }

            var i = count;
            current = self;
            while (i > 0) {
                i -= 1;
                const value = current.?.value;
                buffer[i] = if (is_optional) value.? else value;
                current = current.?.prev;
            }

            return buffer[0..count];
        }
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

test "StackChain.unwrap" {
    const chain = StackChain([]const u8).start("foo").append("bar").append("baz");

    var buffer_small: [2][]const u8 = undefined;
    try testing.expectError(
        error.InsufficientBufferSize,
        chain.unwrap(&buffer_small),
    );

    var buffer: [4][]const u8 = undefined;
    try testing.expectEqualDeep(
        &[_][]const u8{ "foo", "bar", "baz" },
        try chain.unwrap(&buffer),
    );
}

test "StackChain.unwrap optional" {
    var chain = StackChain(?[]const u8){};
    try testing.expect(chain.isEmpty());

    chain = chain.append("foo").append("bar").append("baz");
    try testing.expectEqual(false, chain.isEmpty());

    var buffer_small: [2][]const u8 = undefined;
    try testing.expectError(
        error.InsufficientBufferSize,
        chain.unwrap(&buffer_small),
    );

    var buffer: [4][]const u8 = undefined;
    try testing.expectEqualDeep(
        &[_][]const u8{ "foo", "bar", "baz" },
        try chain.unwrap(&buffer),
    );
}
