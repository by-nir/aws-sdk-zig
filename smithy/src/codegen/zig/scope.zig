const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const decl = @import("../../utils/declarative.zig");
const Closure = decl.Closure;
const callClosure = decl.callClosure;
const Writer = @import("../CodegenWriter.zig");
const flow = @import("flow.zig");
const exp = @import("expr.zig");
const Expr = exp.Expr;
const ExprBuild = exp.ExprBuild;
const _xpr = exp._tst;

pub const INDENT_STR = " " ** 4;

const Block = struct {
    statements: []const Expr,

    pub fn deinit(self: Block, allocator: Allocator) void {
        for (self.statements) |t| t.deinit(allocator);
        allocator.free(self.statements);
    }

    pub fn __write(self: Block, writer: *Writer) !void {
        if (self.statements.len == 0) return writer.appendString("{}");

        try writer.appendChar('{');
        try writer.indentPush(INDENT_STR);
        for (self.statements, 0..) |statement, i| {
            if (i > 0) try writer.breakEmpty(1);
            try writer.breakValue(statement);
            if (true) try writer.appendChar(';');
        }
        writer.indentPop();
        try writer.breakChar('}');
    }
};

const BlockBuild = struct {
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
        try self.append(.{ .flow = .{ .@"if" = value } });
    }

    test "if" {
        var build = init(test_alloc);
        defer build.deinit();
        try build.@"if"(_xpr("foo")).body(_xpr("bar")).end();
        try build.expect(&.{"if (foo) bar"});
    }

    pub fn @"for"(self: *BlockBuild) flow.For.Build(@TypeOf(endFor)) {
        return flow.For.build(self.allocator, endFor, self);
    }

    fn endFor(self: *BlockBuild, value: flow.For) !void {
        try self.append(.{ .flow = .{ .@"for" = value } });
    }

    test "for" {
        var build = init(test_alloc);
        defer build.deinit();
        try build.@"for"().iter(_xpr("foo"), "_").body(_xpr("bar")).end();
        try build.expect(&.{"for (foo) |_| bar"});
    }

    pub fn @"while"(self: *BlockBuild, condition: ExprBuild) flow.While.Build(@TypeOf(endWhile)) {
        return flow.While.build(self.allocator, endWhile, self, condition);
    }

    fn endWhile(self: *BlockBuild, value: flow.While) !void {
        const data = try self.dupeValue(value);
        errdefer self.allocator.destroy(data);
        try self.append(.{ .flow = .{ .@"while" = data } });
    }

    test "while" {
        var build = init(test_alloc);
        defer build.deinit();
        try build.@"while"(_xpr("foo")).body(_xpr("bar")).end();
        try build.expect(&.{"while (foo) bar"});
    }

    pub fn @"switch"(self: *BlockBuild, value: ExprBuild, build: flow.SwitchFn) !void {
        try self.switchWith(value, {}, build);
    }

    pub fn switchWith(
        self: *BlockBuild,
        value: ExprBuild,
        ctx: anytype,
        build: Closure(@TypeOf(ctx), flow.SwitchFn),
    ) !void {
        var builder = flow.Switch.build(self.allocator, value);
        callClosure(ctx, build, .{&builder}) catch |err| {
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
        var build = init(test_alloc);
        defer build.deinit();

        try build.@"switch"(_xpr("foo"), struct {
            fn f(_: *flow.Switch.Build) !void {}
        }.f);

        var tag: []const u8 = "bar";
        _ = &tag;
        try build.switchWith(_xpr("foo"), tag, struct {
            fn f(ctx: []const u8, b: *flow.Switch.Build) !void {
                try b.branch().case(_xpr(ctx)).body(_xpr("baz"));
            }
        }.f);

        try build.expect(&.{
            "switch (foo) {}",
            \\switch (foo) {
            \\    bar => baz,
            \\}
        });
    }

    pub fn @"defer"(self: *BlockBuild, expr: ExprBuild) !void {
        const data = flow.Defer{ .body = try expr.consume() };
        errdefer data.deinit(self.allocator);
        const dupe = try self.dupeValue(data);
        errdefer self.allocator.destroy(dupe);
        try self.append(.{ .flow = .{ .@"defer" = dupe } });
    }

    test "defer" {
        var build = init(test_alloc);
        defer build.deinit();
        try build.@"defer"(_xpr("foo"));
        try build.expect(&.{"defer foo"});
    }

    pub fn @"errdefer"(self: *BlockBuild) flow.Errdefer.Build(@TypeOf(endErrdefer)) {
        return flow.Errdefer.build(endErrdefer, self);
    }

    fn endErrdefer(self: *BlockBuild, value: flow.Errdefer) !void {
        const data = try self.dupeValue(value);
        errdefer self.allocator.destroy(data);
        try self.append(.{ .flow = .{ .@"errdefer" = data } });
    }

    test "errdefer" {
        var build = init(test_alloc);
        defer build.deinit();
        try build.@"errdefer"().body(_xpr("foo"));
        try build.expect(&.{"errdefer foo"});
    }

    fn expect(self: *BlockBuild, expected: []const []const u8) !void {
        const data = try self.consume();
        defer data.deinit(test_alloc);
        try testing.expectEqual(expected.len, data.statements.len);
        for (expected, 0..) |string, i| {
            try Writer.expect(string, data.statements[i]);
        }
    }
};

test {
    _ = Block;
    _ = BlockBuild;
}
