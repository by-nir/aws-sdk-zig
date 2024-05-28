const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const declarative = @import("../../utils/declarative.zig");
const Closure = declarative.Closure;
const callClosure = declarative.callClosure;
const Writer = @import("../CodegenWriter.zig");
const flow = @import("flow.zig");
const Expr = @import("expr.zig").Expr;
const x = Expr.new;

pub const ZIG_INDENT = "    ";

pub const Scope = struct {
    allocator: Allocator,
    statements: std.ArrayListUnmanaged(Statement) = .{},

    const Prefix = union(enum) {};
    const Statement = union(enum) {
        @"if": flow.If,
        @"for": flow.For,
        @"while": flow.While,
        @"switch": flow.Switch,
        @"defer": flow.Defer,
        @"errdefer": flow.ErrorDefer,
    };

    pub fn init(allocator: Allocator) Scope {
        return Scope{ .allocator = allocator };
    }

    pub fn deinit(self: *Scope) void {
        for (self.statements.items) |s| switch (s) {
            .@"switch" => |t| t.deinit(self.allocator),
            else => {},
        };
        self.statements.deinit(self.allocator);
    }

    fn castCtx(ctx: *anyopaque) *Scope {
        return @alignCast(@ptrCast(ctx));
    }

    fn appendStatement(self: *Scope, comptime tag: []const u8, t: anytype) !void {
        try self.statements.append(
            self.allocator,
            @unionInit(Statement, tag, t),
        );
    }

    //
    // Control Flow
    //

    pub fn @"if"(self: *Scope, condition: Expr) flow.If.BuildType(endIf) {
        return flow.If.build(endIf, self, condition);
    }

    fn endIf(self: *Scope, value: flow.If) !void {
        try self.appendStatement("if", value);
    }

    test "if" {
        var self = init(test_alloc);
        defer self.deinit();

        try self.@"if"(x.raw("foo")).body(x.raw("bar")).end();
        try Writer.expect(
            \\{
            \\    if (foo) bar;
            \\}
        , self);
    }

    pub fn @"for"(self: *Scope) flow.For.BuildType(endFor) {
        return flow.For.build(endFor, self);
    }

    fn endFor(self: *Scope, t: flow.For) !void {
        try self.appendStatement("for", t);
    }

    test "for" {
        var self = init(test_alloc);
        defer self.deinit();

        try self.@"for"().iter(x.raw("foo"), "_").body(x.raw("bar")).end();
        try Writer.expect(
            \\{
            \\    for (foo) |_| bar;
            \\}
        , self);
    }

    pub fn @"while"(self: *Scope, condition: Expr) flow.While.BuildType(endWhile) {
        return flow.While.build(endWhile, self, condition);
    }

    fn endWhile(self: *Scope, t: flow.While) !void {
        try self.appendStatement("while", t);
    }

    test "while" {
        var self = init(test_alloc);
        defer self.deinit();

        try self.@"while"(x.raw("foo")).body(x.raw("bar")).end();
        try Writer.expect(
            \\{
            \\    while (foo) bar;
            \\}
        , self);
    }

    pub fn @"switch"(self: *Scope, value: Expr, build: flow.SwitchFn) !void {
        try self.switchWith(value, {}, build);
    }

    pub fn switchWith(
        self: *Scope,
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

        try self.@"switch"(x.raw("foo"), struct {
            fn f(_: *flow.Switch.Build) !void {}
        }.f);

        var tag: []const u8 = "bar";
        _ = &tag;
        try self.switchWith(x.raw("foo"), tag, struct {
            fn f(ctx: []const u8, build: *flow.Switch.Build) !void {
                try build.branch().case(x.raw(ctx)).body(x.raw("baz"));
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

    pub fn @"defer"(self: *Scope, expr: Expr) !void {
        try self.appendStatement("defer", flow.Defer{ .body = expr });
    }

    test "defer" {
        var self = init(test_alloc);
        defer self.deinit();

        try self.@"defer"(x.raw("foo"));
        try Writer.expect(
            \\{
            \\    defer foo;
            \\}
        , self);
    }

    pub fn errorDefer(self: *Scope) flow.ErrorDefer.BuildType(endErrorDefer) {
        return flow.ErrorDefer.build(endErrorDefer, self);
    }

    fn endErrorDefer(self: *Scope, t: flow.ErrorDefer) !void {
        try self.appendStatement("errdefer", t);
    }

    test "errorDefer" {
        var self = init(test_alloc);
        defer self.deinit();

        try self.errorDefer().body(x.raw("foo"));
        try Writer.expect(
            \\{
            \\    errdefer foo;
            \\}
        , self);
    }

    pub fn __write(self: Scope, writer: *Writer) !void {
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
};

test {
    _ = Scope;
}
