const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const StackChain = @import("../../utils/declarative.zig").StackChain;
const Writer = @import("../CodegenWriter.zig");
const Expr = @import("Expr.zig");
const flow = @import("flow.zig");

pub const ZIG_INDENT = "    ";

pub fn Delegate(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const EndFn = *const fn (ctx: *anyopaque, t: *const T) anyerror!void;

        ctx: *anyopaque,
        didEndFn: EndFn,

        pub fn end(self: Self, t: *const T) !void {
            try self.didEndFn(self.ctx, t);
        }

        pub const WriteTester = struct {
            expected: []const u8 = "",

            pub fn dlg(self: *@This()) Self {
                return .{
                    .ctx = self,
                    .didEndFn = WriteTester.end,
                };
            }

            fn end(ctx: *anyopaque, t: *const T) !void {
                const self = @as(*WriteTester, @alignCast(@ptrCast(ctx)));
                try Writer.expect(self.expected, t);
            }
        };
    };
}
