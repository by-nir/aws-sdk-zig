const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const dcl = @import("../utils/declarative.zig");
const StackChain = dcl.StackChain;
const Writer = @import("../CodegenWriter.zig");
const exp = @import("expr.zig");
const Expr = exp.Expr;
const ExprBuild = exp.ExprBuild;

pub const INDENT_STR = " " ** 4;

pub fn isStatement(comptime format: []const u8) bool {
    return comptime std.mem.eql(u8, format, ";");
}

/// If provided an expression, it will make sure to ignore a block.
pub fn statementSemicolon(writer: *Writer, comptime format: []const u8, expr: ?Expr) !void {
    if (comptime !isStatement(format)) return;
    if (expr) |t| if (t == .flow and t.flow == .block) return;
    try writer.appendChar(';');
}

pub fn consumeChainAs(
    allocator: Allocator,
    comptime Src: type,
    comptime Dest: type,
    chain: StackChain(?Src),
) ![]const Dest {
    if (chain.isEmpty()) return &.{};

    const total = chain.count();
    var consumed: usize = 0;
    const list = allocator.alloc(Dest, total) catch |err| {
        var it = chain.iterateReversed();
        while (it.next()) |t| t.deinit();
        return err;
    };
    errdefer {
        for (list[0..consumed]) |t| t.deinit(allocator);
        allocator.free(list);
    }

    var has_error: ?anyerror = null;
    var it = chain.iterateReversed();
    while (it.next()) |source| {
        if (has_error == null) {
            const index = total - consumed - 1;
            list[index] = source.consume() catch |err| {
                has_error = err;
                continue;
            };
            consumed += 1;
        } else {
            source.deinit();
        }
    }

    return has_error orelse list;
}

pub fn consumeExprBuildList(allocator: Allocator, builders: []const ExprBuild) ![]const Expr {
    if (builders.len == 0) return &.{};

    var processed: usize = 0;
    const exprs = try allocator.alloc(Expr, builders.len);
    errdefer {
        for (exprs[0..processed]) |t| t.deinit(allocator);
        allocator.free(exprs);
    }

    for (builders, 0..) |builder, i| {
        exprs[i] = try builder.consume();
        processed += 1;
    }

    return exprs;
}

pub fn TestVal(comptime T: type) type {
    return struct {
        expected: []const u8 = "",

        pub fn callback(self: *@This(), value: T) !void {
            defer value.deinit(testing.allocator);
            try Writer.expectValue(self.expected, value);
        }
    };
}

pub fn TestFmt(comptime T: type, comptime format: []const u8) type {
    return struct {
        expected: []const u8 = "",

        pub fn callback(self: *@This(), value: T) !void {
            defer value.deinit(testing.allocator);
            try Writer.expectFmt(self.expected, format, .{value});
        }
    };
}
