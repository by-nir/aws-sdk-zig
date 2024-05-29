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

pub const ZIG_INDENT = " " ** 4;

const Self = @This();
const Statement = union(enum) {
    @"if": flow.If,
    @"for": flow.For,
    @"while": flow.While,
    @"switch": flow.Switch,
    @"defer": flow.Defer,
    @"errdefer": flow.Errdefer,
};

allocator: Allocator,
statements: std.ArrayListUnmanaged(Statement) = .{},

pub fn init(allocator: Allocator) Self {
    return Self{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    for (self.statements.items) |s| switch (s) {
        inline else => |t| t.deinit(self.allocator),
    };
    self.statements.deinit(self.allocator);
}

fn castCtx(ctx: *anyopaque) *Self {
    return @alignCast(@ptrCast(ctx));
}

fn appendStatement(self: *Self, comptime tag: []const u8, t: anytype) !void {
    try self.statements.append(
        self.allocator,
        @unionInit(Statement, tag, t),
    );
}

//
// Control Flow
//

pub fn @"if"(self: *Self, condition: ExprBuild) flow.If.Build(@TypeOf(endIf)) {
    return flow.If.build(self.allocator, endIf, self, condition);
}

fn endIf(self: *Self, value: flow.If) !void {
    try self.appendStatement("if", value);
}

test "if" {
    var self = init(test_alloc);
    defer self.deinit();

    try self.@"if"(_xpr("foo")).body(_xpr("bar")).end();
    try Writer.expect(
        \\{
        \\    if (foo) bar;
        \\}
    , self);
}

pub fn @"for"(self: *Self) flow.For.Build(@TypeOf(endFor)) {
    return flow.For.build(self.allocator, endFor, self);
}

fn endFor(self: *Self, t: flow.For) !void {
    try self.appendStatement("for", t);
}

test "for" {
    var self = init(test_alloc);
    defer self.deinit();

    try self.@"for"().iter(_xpr("foo"), "_").body(_xpr("bar")).end();
    try Writer.expect(
        \\{
        \\    for (foo) |_| bar;
        \\}
    , self);
}

pub fn @"while"(self: *Self, condition: ExprBuild) flow.While.Build(@TypeOf(endWhile)) {
    return flow.While.build(self.allocator, endWhile, self, condition);
}

fn endWhile(self: *Self, t: flow.While) !void {
    try self.appendStatement("while", t);
}

test "while" {
    var self = init(test_alloc);
    defer self.deinit();

    try self.@"while"(_xpr("foo")).body(_xpr("bar")).end();
    try Writer.expect(
        \\{
        \\    while (foo) bar;
        \\}
    , self);
}

pub fn @"switch"(self: *Self, value: ExprBuild, build: flow.SwitchFn) !void {
    try self.switchWith(value, {}, build);
}

pub fn switchWith(
    self: *Self,
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
    try self.appendStatement("switch", data);
}

test "switch" {
    var self = init(test_alloc);
    defer self.deinit();

    try self.@"switch"(_xpr("foo"), struct {
        fn f(_: *flow.Switch.Build) !void {}
    }.f);

    var tag: []const u8 = "bar";
    _ = &tag;
    try self.switchWith(_xpr("foo"), tag, struct {
        fn f(ctx: []const u8, build: *flow.Switch.Build) !void {
            try build.branch().case(_xpr(ctx)).body(_xpr("baz"));
        }
    }.f);

    try Writer.expect(
        \\{
        \\    switch (foo) {};
        \\
        \\    switch (foo) {
        \\        bar => baz,
        \\    };
        \\}
    , self);
}

pub fn @"defer"(self: *Self, expr: ExprBuild) !void {
    try self.appendStatement("defer", flow.Defer{
        .body = try expr.consume(),
    });
}

test "defer" {
    var self = init(test_alloc);
    defer self.deinit();

    try self.@"defer"(_xpr("foo"));
    try Writer.expect(
        \\{
        \\    defer foo;
        \\}
    , self);
}

pub fn @"errdefer"(self: *Self) flow.Errdefer.Build(@TypeOf(endErrdefer)) {
    return flow.Errdefer.build(endErrdefer, self);
}

fn endErrdefer(self: *Self, t: flow.Errdefer) !void {
    try self.appendStatement("errdefer", t);
}

test "errdefer" {
    var self = init(test_alloc);
    defer self.deinit();

    try self.@"errdefer"().body(_xpr("foo"));
    try Writer.expect(
        \\{
        \\    errdefer foo;
        \\}
    , self);
}

pub fn __write(self: Self, writer: *Writer) !void {
    if (self.statements.items.len == 0) return writer.appendString("{}");

    try writer.appendChar('{');
    try writer.indentPush(ZIG_INDENT);
    for (self.statements.items, 0..) |statement, i| {
        if (i > 0) try writer.breakEmpty(1);
        switch (statement) {
            inline else => |t| try writer.breakValue(t),
        }
        if (true) try writer.appendChar(';');
    }
    writer.indentPop();
    try writer.breakChar('}');
}
