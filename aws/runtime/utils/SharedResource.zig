//! Thread safe reference counter.
const std = @import("std");
const testing = std.testing;

const Self = @This();

count: usize = 0,
mutex: std.Thread.Mutex = .{},

/// Returns the current reference count.
/// Waits for all mutations to complete before reading the value.
pub fn countSafe(self: *Self) usize {
    self.mutex.lock();
    defer self.mutex.unlock();

    return self.count;
}

/// Returns `true` when the first reference is created.
pub fn retain(self: *Self) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    std.debug.assert(self.count < std.math.maxInt(usize));

    defer self.count += 1;
    return self.count == 0;
}

/// Returns `true` when the last reference is released.
pub fn release(self: *Self) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    std.debug.assert(self.count > 0);

    defer self.count -= 1;
    return self.count == 1;
}

/// Runs a callback when the first reference is created.
/// The resource is locked during the callback invocation.
/// The counter will not increase if the callback returns an error.
pub fn retainCallback(self: *Self, cb: anytype, ctx: Cb.of(cb).Arg) Cb.of(cb).Return {
    self.mutex.lock();
    defer self.mutex.unlock();
    std.debug.assert(self.count < std.math.maxInt(usize));

    if (self.count == 0) switch (Cb.of(cb).Return) {
        void => cb(ctx),
        else => try cb(ctx),
    };

    self.count += 1;
}

/// Runs a callback when the last reference is released.
/// The resource is locked during the callback invocation.
/// The counter will not decrease if the callback returns an error.
pub fn releaseCallback(self: *Self, cb: anytype, ctx: Cb.of(cb).Arg) Cb.of(cb).Return {
    self.mutex.lock();
    defer self.mutex.unlock();
    std.debug.assert(self.count > 0);

    if (self.count == 1) switch (Cb.of(cb).Return) {
        void => cb(ctx),
        else => try cb(ctx),
    };

    self.count -= 1;
}

const Cb = struct {
    Arg: type,
    Return: type,

    fn of(comptime cb: anytype) Cb {
        const meta = switch (@typeInfo(@TypeOf(cb))) {
            .@"fn" => |m| m,
            .pointer => |m| blk: {
                const child = @typeInfo(m.child);
                if (m.size != .One or child != .@"fn") @compileError("Callback must be a function.");
                break :blk child.Fn;
            },
            else => @compileError("Callback must be a function."),
        };

        if (meta.params.len != 1) @compileError("Callback function must have exactly a single argument.");

        const Return = meta.return_type.?;
        const valid = switch (@typeInfo(Return)) {
            .void => true,
            .error_union => |m| m.payload == void,
            else => false,
        };
        if (!valid) @compileError("Callback function must return `void` or an error union with `void` payload.");

        return .{
            .Arg = meta.params[0].type.?,
            .Return = Return,
        };
    }
};

test {
    const Demo = struct {
        var value: usize = 0;
        var should_fail = false;

        fn cbSafe(val: usize) void {
            value = val;
        }

        fn cbFailable(val: usize) !void {
            if (should_fail) return error.Fail;
            value = val;
        }
    };

    var resource: Self = .{};

    try testing.expectEqual(true, resource.retain());
    try testing.expectEqual(1, resource.countSafe());
    try testing.expectEqual(false, resource.retain());
    try testing.expectEqual(false, resource.retain());
    try testing.expectEqual(3, resource.countSafe());
    try testing.expectEqual(false, resource.release());
    try testing.expectEqual(2, resource.countSafe());
    try testing.expectEqual(false, resource.release());
    try testing.expectEqual(true, resource.release());
    try testing.expectEqual(0, resource.countSafe());

    Demo.value = 0;
    Demo.should_fail = false;

    resource.retainCallback(Demo.cbSafe, 1);
    try testing.expectEqual(1, resource.countSafe());
    try testing.expectEqual(1, Demo.value);
    resource.retainCallback(Demo.cbSafe, 2);
    resource.retainCallback(Demo.cbSafe, 3);
    try testing.expectEqual(3, resource.countSafe());
    try testing.expectEqual(1, Demo.value);

    resource.releaseCallback(Demo.cbSafe, 4);
    try testing.expectEqual(2, resource.countSafe());
    try testing.expectEqual(1, Demo.value);
    resource.releaseCallback(Demo.cbSafe, 5);
    resource.releaseCallback(Demo.cbSafe, 6);
    try testing.expectEqual(0, resource.countSafe());
    try testing.expectEqual(6, Demo.value);

    Demo.should_fail = true;
    try testing.expectError(error.Fail, resource.retainCallback(Demo.cbFailable, 7));
    try testing.expectEqual(0, resource.countSafe());
    try testing.expectEqual(6, Demo.value);

    Demo.should_fail = false;
    try resource.retainCallback(Demo.cbFailable, 8);
    try testing.expectEqual(1, resource.countSafe());
    try testing.expectEqual(8, Demo.value);
}
