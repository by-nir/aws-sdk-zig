const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const declarative = @import("../../utils/declarative.zig");
const Closure = declarative.Closure;
const callClosure = declarative.callClosure;
const Writer = @import("../CodegenWriter.zig");
const Expr = @import("Expr.zig");
const flow = @import("flow.zig");

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

    fn delegate(self: *Scope, comptime T: type, endFn: Delegate(T).EndFn) Delegate(T) {
        return .{
            .ctx = self,
            .didEndFn = endFn,
        };
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

    pub fn @"if"(self: *Scope, condition: Expr) flow.If.Build {
        return flow.If.Build.new(self.delegate(flow.If, endIf), condition);
    }

    fn endIf(ctx: *anyopaque, t: flow.If) !void {
        try castCtx(ctx).appendStatement("if", t);
    }

    test "if" {
        var self = init(test_alloc);
        defer self.deinit();

        try self.@"if"(Expr.raw("foo")).body(Expr.raw("bar")).end();
        try Writer.expect(
            \\{
            \\    if (foo) bar;
            \\}
        , self);
    }

    pub fn @"for"(self: *Scope) flow.For.Build {
        return flow.For.Build.new(self.delegate(flow.For, endFor));
    }

    fn endFor(ctx: *anyopaque, t: flow.For) !void {
        try castCtx(ctx).appendStatement("for", t);
    }

    test "for" {
        var self = init(test_alloc);
        defer self.deinit();

        try self.@"for"().iter(Expr.raw("foo"), "_").body(Expr.raw("bar")).end();
        try Writer.expect(
            \\{
            \\    for (foo) |_| bar;
            \\}
        , self);
    }

    pub fn @"while"(self: *Scope, condition: Expr) flow.While.Build {
        return flow.While.Build.new(self.delegate(flow.While, endWhile), condition);
    }

    fn endWhile(ctx: *anyopaque, t: flow.While) !void {
        try castCtx(ctx).appendStatement("while", t);
    }

    test "while" {
        var self = init(test_alloc);
        defer self.deinit();

        try self.@"while"(Expr.raw("foo")).body(Expr.raw("bar")).end();
        try Writer.expect(
            \\{
            \\    while (foo) bar;
            \\}
        , self);
    }

    const SwitchFn = *const fn (*flow.Switch.Build) anyerror!void;

    pub fn @"switch"(self: *Scope, value: Expr, build: SwitchFn) !void {
        try self.switchWith(value, {}, build);
    }

    pub fn switchWith(
        self: *Scope,
        value: Expr,
        ctx: anytype,
        build: Closure(@TypeOf(ctx), SwitchFn),
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

        try self.@"switch"(Expr.raw("foo"), struct {
            fn f(_: *flow.Switch.Build) !void {}
        }.f);

        var tag: []const u8 = "bar";
        _ = &tag;
        try self.switchWith(Expr.raw("foo"), tag, struct {
            fn f(ctx: []const u8, build: *flow.Switch.Build) !void {
                try build.branch().case(Expr.raw(ctx)).body(Expr.raw("baz"));
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

        try self.@"defer"(Expr.raw("foo"));
        try Writer.expect(
            \\{
            \\    defer foo;
            \\}
        , self);
    }

    pub fn errorDefer(self: *Scope) flow.ErrorDefer.Build {
        return flow.ErrorDefer.Build.new(self.delegate(flow.ErrorDefer, endErrorDefer));
    }

    fn endErrorDefer(ctx: *anyopaque, t: flow.ErrorDefer) !void {
        try castCtx(ctx).appendStatement("errdefer", t);
    }

    test "errorDefer" {
        var self = init(test_alloc);
        defer self.deinit();

        try self.errorDefer().body(Expr.raw("foo"));
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

pub fn Delegate(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const EndFn = *const fn (ctx: *anyopaque, t: T) anyerror!void;

        ctx: *anyopaque,
        didEndFn: EndFn,

        pub fn new(self: *anyopaque, didEndFn: EndFn) Self {
            return .{
                .ctx = self,
                .didEndFn = didEndFn,
            };
        }

        pub fn end(self: Self, t: T) !void {
            try self.didEndFn(self.ctx, t);
        }

        pub const Tester = struct {
            expected: []const u8 = "",

            pub fn dlg(self: *@This()) Self {
                return .{
                    .ctx = self,
                    .didEndFn = Tester.end,
                };
            }

            fn end(ctx: *anyopaque, t: T) !void {
                const self = @as(*Tester, @alignCast(@ptrCast(ctx)));
                try Writer.expect(self.expected, t);
            }
        };
    };
}

test {
    _ = Scope;
}
