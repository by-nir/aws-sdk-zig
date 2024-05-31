const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const dcl = @import("../../utils/declarative.zig");
const Closure = dcl.Closure;
const callClosure = dcl.callClosure;
const Writer = @import("../CodegenWriter.zig");
const declare = @import("declare.zig");
const flow = @import("flow.zig");
const exp = @import("expr.zig");
const Expr = exp.Expr;
const ExprBuild = exp.ExprBuild;

pub const INDENT_STR = " " ** 4;

pub const Container = struct {
    statements: []const Expr,

    pub fn deinit(self: Container, allocator: Allocator) void {
        for (self.statements) |t| t.deinit(allocator);
        allocator.free(self.statements);
    }

    pub fn write(self: Container, writer: *Writer) !void {
        for (self.statements, 0..) |statement, i| {
            if (i == 0) {
                try writer.appendFmt("{s}{;}", .{ writer.prefix, statement });
            } else {
                try writer.breakEmpty(1);
                try writer.breakFmt("{;}", .{statement});
            }
        }
    }
};

test "Container" {
    try Writer.expectValue(
        \\foo: Bar,
        \\
        \\foo: Bar,
    , Container{
        .statements = &.{
            .{ .declare = .{ .field = &declare.Field{
                .name = "foo",
                .type = .{ .raw = "Bar" },
                .alignment = null,
                .assign = null,
            } } },
            .{ .declare = .{ .field = &declare.Field{
                .name = "foo",
                .type = .{ .raw = "Bar" },
                .alignment = null,
                .assign = null,
            } } },
        },
    });
}

pub const ContainerClosure = *const fn (*ContainerBuild) anyerror!void;
pub const ContainerBuild = struct {
    allocator: Allocator,
    statements: std.ArrayListUnmanaged(Expr) = .{},
    xpr: ExprBuild,

    pub fn init(allocator: Allocator) ContainerBuild {
        return .{
            .allocator = allocator,
            .xpr = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *ContainerBuild) void {
        for (self.statements.items) |t| t.deinit(self.allocator);
        self.statements.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn consume(self: *ContainerBuild) !Container {
        return .{
            .statements = try self.statements.toOwnedSlice(self.allocator),
        };
    }

    fn append(self: *ContainerBuild, stmnt: Expr) !void {
        try self.statements.append(self.allocator, stmnt);
    }

    fn dupeValue(self: ContainerBuild, value: anytype) !*@TypeOf(value) {
        const data = try self.allocator.create(@TypeOf(value));
        data.* = value;
        return data;
    }
    //
    // Declare
    //

    pub fn field(self: *ContainerBuild, name: ?[]const u8) declare.Field.Build(@TypeOf(endField)) {
        return declare.Field.build(endField, self, name);
    }

    fn endField(self: *ContainerBuild, value: declare.Field) !void {
        errdefer value.deinit(self.allocator);
        const dupe = try self.dupeValue(value);
        errdefer self.allocator.destroy(dupe);
        try self.append(.{ .declare = .{ .field = dupe } });
    }

    test "field" {
        var b = init(test_alloc);
        defer b.deinit();
        try b.field("foo").typing(b.xpr.raw("Bar")).end();
        try b.expect("foo: Bar");
    }

    pub fn using(self: *ContainerBuild, expr: ExprBuild) !void {
        const data = try expr.consume();
        errdefer data.deinit(self.allocator);
        const dupe = try self.dupeValue(exp.WordExpr{
            .token = .keyword_usingnamespace,
            .expr = data,
        });
        errdefer self.allocator.destroy(dupe);
        try self.append(.{ .declare = .{ .word_expr = dupe } });
    }

    test "using" {
        var b = init(test_alloc);
        defer b.deinit();
        try b.using(b.xpr.raw("foo"));
        try b.expect("usingnamespace foo");
    }

    pub fn variable(self: *ContainerBuild, name: []const u8) declare.Variable.Build(@TypeOf(endVariable)) {
        return declare.Variable.build(endVariable, self, false, name);
    }

    pub fn constant(self: *ContainerBuild, name: []const u8) declare.Variable.Build(@TypeOf(endVariable)) {
        return declare.Variable.build(endVariable, self, true, name);
    }

    fn endVariable(self: *ContainerBuild, value: declare.Variable) !void {
        errdefer value.deinit(self.allocator);
        const dupe = try self.dupeValue(value);
        errdefer self.allocator.destroy(dupe);
        try self.append(.{ .declare = .{ .variable = dupe } });
    }

    test "variable" {
        var b = init(test_alloc);
        defer b.deinit();
        try b.variable("foo").assign(b.xpr.raw("bar"));
        try b.expect("var foo = bar");

        b.deinit();
        b = init(test_alloc);
        try b.constant("foo").assign(b.xpr.raw("bar"));
        try b.expect("const foo = bar");
    }

    //
    // Block
    //

    pub fn comptimeBlock(self: *ContainerBuild, closure: BlockClosure) !void {
        return self.comptimeBlockWith({}, closure);
    }

    pub fn comptimeBlockWith(
        self: *ContainerBuild,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), BlockClosure),
    ) !void {
        const data = try declare.WordBlock.init(
            self.allocator,
            .keyword_comptime,
            null,
            ctx,
            closure,
        );
        errdefer data.deinit(self.allocator);
        try self.append(.{ .declare = .{ .word_block = data } });
    }

    test "comptimeBlock" {
        var b = init(test_alloc);
        defer b.deinit();
        try b.comptimeBlock(struct {
            fn f(_: *BlockBuild) !void {}
        }.f);
        try b.expect("comptime {}");
    }

    pub fn testBlock(self: *ContainerBuild, name: ?[]const u8, closure: BlockClosure) !void {
        return self.testBlockWith(name, {}, closure);
    }

    pub fn testBlockWith(
        self: *ContainerBuild,
        name: ?[]const u8,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), BlockClosure),
    ) !void {
        const data = try declare.WordBlock.init(self.allocator, .keyword_test, name, ctx, closure);
        errdefer data.deinit(self.allocator);
        try self.append(.{ .declare = .{ .word_block = data } });
    }

    test "testBlock" {
        var b = init(test_alloc);
        defer b.deinit();
        try b.testBlock("foo", struct {
            fn f(_: *BlockBuild) !void {}
        }.f);
        try b.expect("test \"foo\" {}");
    }

    fn expect(self: *ContainerBuild, expected: []const u8) !void {
        const data = try self.consume();
        defer data.deinit(test_alloc);
        try Writer.expectValue(expected, data.statements[0]);
    }
};

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
    try Writer.expectValue(
        \\{
        \\    if (foo) bar;
        \\
        \\    if (foo) {}
        \\}
    , Block{ .statements = &.{
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
    } });
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

        var tag: [3]u8 = "bar".*;
        try b.switchWith(b.xpr.raw("foo"), @as([]u8, &tag), struct {
            fn f(ctx: []u8, s: *flow.Switch.Build) !void {
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

    pub fn defers(self: *BlockBuild, expr: ExprBuild) !void {
        const data = exp.WordExpr{
            .token = .keyword_defer,
            .expr = try expr.consume(),
        };
        errdefer data.deinit(self.allocator);
        const dupe = try self.dupeValue(data);
        errdefer self.allocator.destroy(dupe);
        try self.append(.{ .flow = .{ .word_expr = dupe } });
    }

    test "defers" {
        var b = init(test_alloc);
        defer b.deinit();
        try b.defers(b.xpr.raw("foo"));
        try b.expect(&.{"defer foo"});
    }

    pub fn errorDefers(self: *BlockBuild) exp.WordCaptureExpr.Build(@TypeOf(endErrorDefers)) {
        return exp.WordCaptureExpr.build(endErrorDefers, self, .keyword_errdefer);
    }

    fn endErrorDefers(self: *BlockBuild, value: exp.WordCaptureExpr) !void {
        errdefer value.deinit(self.allocator);
        const data = try self.dupeValue(value);
        errdefer self.allocator.destroy(data);
        try self.append(.{ .flow = .{ .word_capture = data } });
    }

    test "errorDefers" {
        var b = init(test_alloc);
        defer b.deinit();
        try b.errorDefers().body(b.xpr.raw("foo"));
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

        var tag: [3]u8 = "bar".*;
        try b.blockWith(@as([]u8, &tag), struct {
            fn f(ctx: []u8, k: *BlockBuild) !void {
                try k.defers(k.xpr.raw(ctx));
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
    _ = ContainerBuild;
}
