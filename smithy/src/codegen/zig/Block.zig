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
const Expr = @import("expr.zig").Expr;
const x = Expr.new;

pub const ZIG_INDENT = " " ** 4;

const Self = @This();
const Statement = union(enum) {
    @"if": flow.If,
    @"for": flow.For,
    @"while": flow.While,
    @"switch": flow.Switch,
    @"defer": flow.Defer,
    @"errdefer": flow.ErrorDefer,
};

allocator: Allocator,
statements: std.ArrayListUnmanaged(Statement) = .{},

pub fn init(allocator: Allocator) Self {
    return Self{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    for (self.statements.items) |s| switch (s) {
        inline .@"if", .@"for", .@"switch", .@"while" => |t| t.deinit(self.allocator),
        else => {},
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

pub fn @"if"(self: *Self, condition: Expr) flow.If.Build(@TypeOf(endIf)) {
    return flow.If.build(self.allocator, endIf, self, condition);
}

fn endIf(self: *Self, value: flow.If) !void {
    try self.appendStatement("if", value);
}

test "if" {
    var self = init(test_alloc);
    defer self.deinit();

    try self.@"if"(x._raw("foo")).body(x._raw("bar")).end();
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

    try self.@"for"().iter(x._raw("foo"), "_").body(x._raw("bar")).end();
    try Writer.expect(
        \\{
        \\    for (foo) |_| bar;
        \\}
    , self);
}

pub fn @"while"(self: *Self, condition: Expr) flow.While.Build(@TypeOf(endWhile)) {
    return flow.While.build(self.allocator, endWhile, self, condition);
}

fn endWhile(self: *Self, t: flow.While) !void {
    try self.appendStatement("while", t);
}

test "while" {
    var self = init(test_alloc);
    defer self.deinit();

    try self.@"while"(x._raw("foo")).body(x._raw("bar")).end();
    try Writer.expect(
        \\{
        \\    while (foo) bar;
        \\}
    , self);
}

pub fn @"switch"(self: *Self, value: Expr, build: flow.SwitchFn) !void {
    try self.switchWith(value, {}, build);
}

pub fn switchWith(
    self: *Self,
    value: Expr,
    ctx: anytype,
    build: Closure(@TypeOf(ctx), flow.SwitchFn),
) !void {
    var builder = flow.Switch.Build.init(self.allocator, value);
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

    try self.@"switch"(x._raw("foo"), struct {
        fn f(_: *flow.Switch.Build) !void {}
    }.f);

    var tag: []const u8 = "bar";
    _ = &tag;
    try self.switchWith(x._raw("foo"), tag, struct {
        fn f(ctx: []const u8, build: *flow.Switch.Build) !void {
            try build.branch().case(x._raw(ctx)).body(x._raw("baz"));
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

pub fn @"defer"(self: *Self, expr: Expr) !void {
    try self.appendStatement("defer", flow.Defer{ .body = expr });
}

test "defer" {
    var self = init(test_alloc);
    defer self.deinit();

    try self.@"defer"(x._raw("foo"));
    try Writer.expect(
        \\{
        \\    defer foo;
        \\}
    , self);
}

pub fn errorDefer(self: *Self) flow.ErrorDefer.Build(@TypeOf(endErrorDefer)) {
    return flow.ErrorDefer.build(endErrorDefer, self);
}

fn endErrorDefer(self: *Self, t: flow.ErrorDefer) !void {
    try self.appendStatement("errdefer", t);
}

test "errorDefer" {
    var self = init(test_alloc);
    defer self.deinit();

    try self.errorDefer().body(x._raw("foo"));
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