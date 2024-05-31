const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const decl = @import("../../utils/declarative.zig");
const Closure = decl.Closure;
const callClosure = decl.callClosure;
const Writer = @import("../CodegenWriter.zig");
const exp = @import("expr.zig");
const Expr = exp.Expr;
const ExprBuild = exp.ExprBuild;
const flow = @import("flow.zig");

pub const INDENT_STR = " " ** 4;

pub const Block = struct {
    statements: []const Expr,

    pub fn deinit(self: Block, allocator: Allocator) void {
        for (self.statements) |t| t.deinit(allocator);
        allocator.free(self.statements);
    }

    pub fn write(self: Block, writer: *Writer) !void {
        if (self.statements.len == 0) return writer.appendString("{}");

        try writer.appendChar('{');
        try writer.indentPush(INDENT_STR);
        for (self.statements, 0..) |statement, i| {
            if (i > 0) try writer.breakEmpty(1);
            try writer.breakFmt("{;}", .{statement});
        }
        writer.indentPop();
        try writer.breakChar('}');
    }
};

test "Block" {
    const block = Block{
        .statements = &.{
            Expr{ .flow = .{
                .@"if" = flow.If{ .branches = &.{flow.Branch{
                    .condition = .{ .raw = "foo" },
                    .body = .{ .raw = "bar" },
                }} },
            } },
            Expr{ .flow = .{
                .@"if" = flow.If{ .branches = &.{flow.Branch{
                    .condition = .{ .raw = "foo" },
                    .body = Expr{ .flow = .{
                        .block = Block{ .statements = &.{} },
                    } },
                }} },
            } },
        },
    };

    try Writer.expectValue(
        \\{
        \\    if (foo) bar;
        \\
        \\    if (foo) {}
        \\}
    , block);
}

pub const BlockClosure = *const fn (*BlockBuild) anyerror!void;

pub const BlockBuild = struct {
    allocator: Allocator,
    statements: std.ArrayListUnmanaged(Expr) = .{},
    xpr: ExprBuild,

    pub fn init(allocator: Allocator) BlockBuild {
        return .{
            .allocator = allocator,
            .xpr = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *BlockBuild) void {
        for (self.statements.items) |t| t.deinit(self.allocator);
        self.statements.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn consume(self: *BlockBuild) !Block {
        return .{
            .statements = try self.statements.toOwnedSlice(self.allocator),
        };
    }

    fn startChain(self: *BlockBuild) ExprBuild {
        var expr = self.xpr;
        expr.callback_ctx = self;
        expr.callback_fn = appendChain;
        return expr;
    }

    fn appendChain(ctx: *anyopaque, expr: Expr) !void {
        const self: *BlockBuild = @alignCast(@ptrCast(ctx));
        try self.statements.append(self.allocator, expr);
    }

    fn append(self: *BlockBuild, expr: Expr) !void {
        try self.statements.append(self.allocator, expr);
    }

    fn dupeValue(self: BlockBuild, value: anytype) !*@TypeOf(value) {
        const data = try self.allocator.create(@TypeOf(value));
        data.* = value;
        return data;
    }

    //
    // Control Flow
    //

    pub fn @"if"(self: *BlockBuild, condition: ExprBuild) flow.If.Build(@TypeOf(endIf)) {
        return flow.If.build(self.allocator, endIf, self, condition);
    }

    fn endIf(self: *BlockBuild, value: flow.If) !void {
        errdefer value.deinit(self.allocator);
        try self.append(.{ .flow = .{ .@"if" = value } });
    }

    test "if" {
        var b = init(test_alloc);
        defer b.deinit();
        try b.@"if"(b.xpr.raw("foo")).body(b.xpr.raw("bar")).end();
        try b.expect(&.{"if (foo) bar"});
    }

    pub fn @"for"(self: *BlockBuild) flow.For.Build(@TypeOf(endFor)) {
        return flow.For.build(self.allocator, endFor, self);
    }

    fn endFor(self: *BlockBuild, value: flow.For) !void {
        errdefer value.deinit(self.allocator);
        try self.append(.{ .flow = .{ .@"for" = value } });
    }

    test "for" {
        var b = init(test_alloc);
        defer b.deinit();
        try b.@"for"().iter(b.xpr.raw("foo"), "_").body(b.xpr.raw("bar")).end();
        try b.expect(&.{"for (foo) |_| bar"});
    }

    pub fn @"while"(self: *BlockBuild, condition: ExprBuild) flow.While.Build(@TypeOf(endWhile)) {
        return flow.While.build(self.allocator, endWhile, self, condition);
    }

    fn endWhile(self: *BlockBuild, value: flow.While) !void {
        errdefer value.deinit(self.allocator);
        const data = try self.dupeValue(value);
        errdefer self.allocator.destroy(data);
        try self.append(.{ .flow = .{ .@"while" = data } });
    }

    test "while" {
        var b = init(test_alloc);
        defer b.deinit();
        try b.@"while"(b.xpr.raw("foo")).body(b.xpr.raw("bar")).end();
        try b.expect(&.{"while (foo) bar"});
    }

    pub fn @"switch"(self: *BlockBuild, value: ExprBuild, closure: flow.SwitchClosure) !void {
        try self.switchWith(value, {}, closure);
    }

    pub fn switchWith(
        self: *BlockBuild,
        value: ExprBuild,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), flow.SwitchClosure),
    ) !void {
        var builder = flow.Switch.build(self.allocator, value);
        callClosure(ctx, closure, .{&builder}) catch |err| {
            builder.deinit();
            return err;
        };
        const data = try builder.consume();
        errdefer data.deinit(self.allocator);

        const dupe = try self.dupeValue(data);
        errdefer self.allocator.destroy(dupe);
        try self.append(.{ .flow = .{ .@"switch" = dupe } });
    }

    test "switch" {
        var b = init(test_alloc);
        defer b.deinit();

        try b.@"switch"(b.xpr.raw("foo"), struct {
            fn f(_: *flow.Switch.Build) !void {}
        }.f);

        var tag: []const u8 = "bar";
        _ = &tag;
        try b.switchWith(b.xpr.raw("foo"), tag, struct {
            fn f(ctx: []const u8, s: *flow.Switch.Build) !void {
                try s.branch().case(s.xpr.raw(ctx)).body(s.xpr.raw("baz"));
            }
        }.f);

        try b.expect(&.{
            "switch (foo) {}",
            \\switch (foo) {
            \\    bar => baz,
            \\}
        });
    }

    pub fn @"defer"(self: *BlockBuild, expr: ExprBuild) !void {
        const data = exp.WordExpr{
            .tag = .keyword_defer,
            .expr = try expr.consume(),
        };
        errdefer data.deinit(self.allocator);
        const dupe = try self.dupeValue(data);
        errdefer self.allocator.destroy(dupe);
        try self.append(.{ .flow = .{ .word_expr = dupe } });
    }

    test "defer" {
        var b = init(test_alloc);
        defer b.deinit();
        try b.@"defer"(b.xpr.raw("foo"));
        try b.expect(&.{"defer foo"});
    }

    pub fn @"errdefer"(self: *BlockBuild) exp.WordCaptureExpr.Build(@TypeOf(endErrdefer)) {
        return exp.WordCaptureExpr.build(endErrdefer, self, .keyword_errdefer);
    }

    fn endErrdefer(self: *BlockBuild, value: exp.WordCaptureExpr) !void {
        errdefer value.deinit(self.allocator);
        const data = try self.dupeValue(value);
        errdefer self.allocator.destroy(data);
        try self.append(.{ .flow = .{ .word_capture = data } });
    }

    test "errdefer" {
        var b = init(test_alloc);
        defer b.deinit();
        try b.@"errdefer"().body(b.xpr.raw("foo"));
        try b.expect(&.{"errdefer foo"});
    }

    pub fn returns(self: *BlockBuild) ExprBuild {
        return self.startChain().returns();
    }

    test "returns" {
        var b = init(test_alloc);
        defer b.deinit();
        try b.returns().raw("foo").end();
        try b.expect(&.{"return foo"});
    }

    pub fn breaks(self: *BlockBuild, label: ?[]const u8) ExprBuild {
        return self.startChain().breaks(label);
    }

    test "breaks" {
        var b = init(test_alloc);
        defer b.deinit();
        try b.breaks("foo").raw("bar").end();
        try b.expect(&.{"break :foo bar"});
    }

    pub fn continues(self: *BlockBuild, label: ?[]const u8) ExprBuild {
        return self.startChain().continues(label);
    }

    test "continues" {
        var b = init(test_alloc);
        defer b.deinit();
        try b.continues("foo").raw("bar").end();
        try b.expect(&.{"continue :foo bar"});
    }

    pub fn block(self: *BlockBuild, closure: BlockClosure) !void {
        try self.blockWith({}, closure);
    }

    pub fn blockWith(
        self: *BlockBuild,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), BlockClosure),
    ) !void {
        var builder = BlockBuild.init(self.allocator);
        callClosure(ctx, closure, .{&builder}) catch |err| {
            builder.deinit();
            return err;
        };
        const data = try builder.consume();
        errdefer data.deinit(self.allocator);
        try self.append(.{ .flow = .{ .block = data } });
    }

    test "block" {
        var b = init(test_alloc);
        defer b.deinit();

        try b.block(struct {
            fn f(_: *BlockBuild) !void {}
        }.f);

        var tag: []const u8 = "bar";
        _ = &tag;
        try b.blockWith(tag, struct {
            fn f(ctx: []const u8, k: *BlockBuild) !void {
                try k.@"defer"(k.xpr.raw(ctx));
            }
        }.f);

        try b.expect(&.{
            "{}",
            \\{
            \\    defer bar;
            \\}
        });
    }

    fn expect(self: *BlockBuild, expected: []const []const u8) !void {
        const data = try self.consume();
        defer data.deinit(test_alloc);
        try testing.expectEqual(expected.len, data.statements.len);
        for (expected, 0..) |string, i| {
            try Writer.expectValue(string, data.statements[i]);
        }
    }
};

pub fn isStatement(comptime format: []const u8) bool {
    return comptime std.mem.eql(u8, format, ";");
}

/// If provided an expression, it will make sure to ignore a block.
pub fn statementSemicolon(writer: *Writer, comptime format: []const u8, expr: ?Expr) !void {
    if (comptime !isStatement(format)) return;
    if (expr) |t| if (t == .flow and t.flow == .block) return;
    try writer.appendChar(';');
}

test {
    _ = BlockBuild;
}
