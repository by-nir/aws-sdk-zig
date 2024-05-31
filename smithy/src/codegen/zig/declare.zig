const std = @import("std");
const ZigToken = std.zig.Token.Tag;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const dcl = @import("../../utils/declarative.zig");
const cb = dcl.callback;
const InferCallback = dcl.InferCallback;
const Closure = dcl.Closure;
const callClosure = dcl.callClosure;
const Writer = @import("../CodegenWriter.zig");
const testing = @import("../testing.zig");
const test_alloc = testing.allocator;
const scope = @import("scope.zig");
const exp = @import("expr.zig");
const Expr = exp.Expr;
const ExprBuild = exp.ExprBuild;
const _xpr = exp._raw;

pub const Field = struct {
    /// `null` when part of a tuple.
    name: ?[]const u8,
    type: Expr,
    alignment: ?Expr,
    assign: ?Expr,

    pub fn deinit(self: Field, allocator: Allocator) void {
        self.type.deinit(allocator);
        if (self.alignment) |t| t.deinit(allocator);
        if (self.assign) |t| t.deinit(allocator);
    }

    pub fn write(self: Field, writer: *Writer) !void {
        if (self.name) |s| {
            try writer.appendFmt("{_}: {}", .{ std.zig.fmtId(s), self.type });
        } else {
            try writer.appendValue(self.type);
        }
        if (self.alignment) |t| try writer.appendFmt(" align({})", .{t});
        if (self.assign) |t| try writer.appendFmt(" = {}", .{t});
    }

    pub fn build(callback: anytype, ctx: anytype, name: ?[]const u8) Build(@TypeOf(callback)) {
        return .{
            .callback = cb(ctx, callback),
            .name = name,
        };
    }

    pub fn Build(comptime Fn: type) type {
        const Callback = InferCallback(Fn);
        return struct {
            const Self = @This();

            callback: Callback,
            name: ?[]const u8,
            type: ?ExprBuild = null,
            @"align": ?ExprBuild = null,

            pub fn deinit(self: Self) void {
                if (self.type) |t| t.deinit();
                if (self.@"align") |t| t.deinit();
            }

            pub fn typing(self: Self, expr: ExprBuild) Self {
                assert(self.type == null);
                assert(self.@"align" == null);
                var dupe = self;
                dupe.type = expr;
                return dupe;
            }

            pub fn alignment(self: Self, expr: ExprBuild) Self {
                assert(self.type != null);
                assert(self.@"align" == null);
                var dupe = self;
                dupe.@"align" = expr;
                return dupe;
            }

            pub fn assign(self: Self, expr: ExprBuild) Callback.Return {
                if (self.consume(expr)) |data| {
                    return self.callback.invoke(data);
                } else |err| {
                    return self.callback.fail(err);
                }
            }

            pub fn end(self: Self) Callback.Return {
                if (self.consume(null)) |data| {
                    return self.callback.invoke(data);
                } else |err| {
                    return self.callback.fail(err);
                }
            }

            fn consume(self: Self, assignment: ?ExprBuild) !Field {
                const alloc_type = self.type.?.consume() catch |err| {
                    if (self.@"align") |x| x.deinit();
                    if (assignment) |x| x.deinit();
                    return err;
                };
                errdefer alloc_type.deinit(self.type.?.allocator);

                const alloc_align = if (self.@"align") |t| t.consume() catch |err| {
                    if (assignment) |x| x.deinit();
                    return err;
                } else null;
                errdefer if (alloc_align) |t| t.deinit(self.@"align".?.allocator);

                const alloc_assign = if (assignment) |t| try t.consume() else null;
                return .{
                    .name = self.name,
                    .type = alloc_type,
                    .alignment = alloc_align,
                    .assign = alloc_assign,
                };
            }
        };
    }
};

test "Field" {
    const Test = testing.TestVal(Field);
    var tester = Test{ .expected = "foo: Bar" };
    try Field.build(Test.callback, &tester, "foo").typing(_xpr("Bar")).end();

    tester.expected = "@\"test\": Foo";
    try Field.build(Test.callback, &tester, "test").typing(_xpr("Foo")).end();

    tester.expected = "foo: Bar align(baz) = qux";
    try Field.build(Test.callback, &tester, "foo").typing(_xpr("Bar"))
        .alignment(_xpr("baz")).assign(_xpr("qux"));

    tester.expected = "Foo align(bar) = baz";
    try Field.build(Test.callback, &tester, null).typing(_xpr("Foo"))
        .alignment(_xpr("bar")).assign(_xpr("baz"));
}

pub const Variable = struct {
    is_const: bool,
    name: []const u8,
    type: ?Expr,
    alignment: ?Expr,
    assign: Expr,

    pub fn deinit(self: Variable, allocator: Allocator) void {
        if (self.type) |t| t.deinit(allocator);
        if (self.alignment) |t| t.deinit(allocator);
        self.assign.deinit(allocator);
    }

    pub fn write(self: Variable, writer: *Writer) !void {
        try writer.appendString(if (self.is_const) "const " else "var ");
        try writer.appendFmt("{_}", .{std.zig.fmtId(self.name)});
        if (self.type) |t| {
            try writer.appendFmt(": {}", .{t});
            if (self.alignment) |a| try writer.appendFmt(" align({})", .{a});
        }
        try writer.appendFmt(" = {}", .{self.assign});
    }

    pub fn build(callback: anytype, ctx: anytype, is_const: bool, name: []const u8) Build(@TypeOf(callback)) {
        return .{
            .callback = cb(ctx, callback),
            .is_const = is_const,
            .name = name,
        };
    }

    pub fn Build(comptime Fn: type) type {
        const Callback = InferCallback(Fn);
        return struct {
            const Self = @This();

            callback: Callback,
            is_const: bool,
            name: []const u8,
            type: ?ExprBuild = null,
            @"align": ?ExprBuild = null,

            pub fn deinit(self: Self) void {
                if (self.type) |t| t.deinit();
                if (self.@"align") |t| t.deinit();
            }

            pub fn typing(self: Self, expr: ExprBuild) Self {
                assert(self.type == null);
                assert(self.@"align" == null);
                var dupe = self;
                dupe.type = expr;
                return dupe;
            }

            pub fn alignment(self: Self, expr: ExprBuild) Self {
                assert(self.type != null);
                assert(self.@"align" == null);
                var dupe = self;
                dupe.@"align" = expr;
                return dupe;
            }

            pub fn assign(self: Self, expr: ExprBuild) Callback.Return {
                if (self.consume(expr)) |data| {
                    return self.callback.invoke(data);
                } else |err| {
                    return self.callback.fail(err);
                }
            }

            fn consume(self: Self, expr: ExprBuild) !Variable {
                const alloc_assign = expr.consume() catch |err| {
                    if (self.type) |x| x.deinit();
                    if (self.@"align") |x| x.deinit();
                    return err;
                };
                errdefer alloc_assign.deinit(expr.allocator);

                const alloc_type = if (self.type) |t| t.consume() catch |err| {
                    if (self.@"align") |x| x.deinit();
                    return err;
                } else null;
                errdefer if (alloc_type) |t| t.deinit(self.type.?.allocator);

                const alloc_align = if (self.@"align") |t| try t.consume() else null;
                return .{
                    .is_const = self.is_const,
                    .name = self.name,
                    .type = alloc_type,
                    .alignment = alloc_align,
                    .assign = alloc_assign,
                };
            }
        };
    }
};

test "Variable" {
    const Test = testing.TestVal(Variable);
    var tester = Test{ .expected = "var foo = bar" };
    try Variable.build(Test.callback, &tester, false, "foo").assign(_xpr("bar"));

    tester.expected = "var @\"test\" = foo";
    try Variable.build(Test.callback, &tester, false, "test").assign(_xpr("foo"));

    tester.expected = "const foo: Bar align(baz) = qux";
    try Variable.build(Test.callback, &tester, true, "foo").typing(_xpr("Bar"))
        .alignment(_xpr("baz")).assign(_xpr("qux"));
}

pub const Namespace = struct {
    token: ZigToken,
    backing: ?Expr,
    container: scope.Container,

    pub fn deinit(self: Namespace, allocator: Allocator) void {
        self.container.deinit(allocator);
        if (self.backing) |t| t.deinit(allocator);
    }

    pub fn write(self: Namespace, writer: *Writer) !void {
        try writer.appendString(self.token.lexeme().?);
        if (self.backing) |t| {
            try writer.appendFmt("({})", .{t});
        } else if (self.token == .keyword_union) {
            try writer.appendString("(enum)");
        }

        if (self.container.statements.len == 0) {
            return writer.appendString(" {}");
        } else {
            try writer.appendString(" {\n");
            try writer.indentPush(scope.INDENT_STR);
            try self.container.write(writer);
            writer.indentPop();
            try writer.breakChar('}');
        }
    }

    pub fn build(
        allocator: Allocator,
        callback: anytype,
        ctx: anytype,
        token: ZigToken,
    ) Build(@TypeOf(callback)) {
        return .{
            .allocator = allocator,
            .callback = cb(ctx, callback),
            .token = token,
        };
    }

    pub fn Build(comptime Fn: type) type {
        const Callback = InferCallback(Fn);
        return struct {
            const Self = @This();

            allocator: Allocator,
            callback: Callback,
            token: ZigToken,
            backing: ?ExprBuild = null,

            pub fn deinit(self: Self) void {
                if (self.backing) |t| t.deinit();
            }

            pub fn typing(self: Self, expr: ExprBuild) Self {
                assert(self.backing == null);
                var dupe = self;
                dupe.backing = expr;
                return dupe;
            }

            pub fn body(self: Self, closure: scope.ContainerClosure) Callback.Return {
                return self.bodyWith({}, closure);
            }

            pub fn bodyWith(
                self: Self,
                ctx: anytype,
                closure: Closure(@TypeOf(ctx), scope.ContainerClosure),
            ) Callback.Return {
                const alloc_backing = if (self.backing) |t| t.consume() catch |err| {
                    return self.callback.fail(err);
                } else null;

                var builder = scope.ContainerBuild.init(self.allocator);
                callClosure(ctx, closure, .{&builder}) catch |err| {
                    builder.deinit();
                    if (alloc_backing) |t| t.deinit(self.allocator);
                    return self.callback.fail(err);
                };

                if (builder.consume()) |data| {
                    return self.callback.invoke(.{
                        .token = self.token,
                        .backing = alloc_backing,
                        .container = data,
                    });
                } else |err| {
                    if (alloc_backing) |t| t.deinit(self.allocator);
                    return self.callback.fail(err);
                }
            }
        };
    }
};

test "Namespace" {
    const Test = testing.TestVal(Namespace);
    var tester = Test{ .expected = "union(enum) {}" };
    try Namespace.build(test_alloc, Test.callback, &tester, .keyword_union).body(struct {
        fn f(_: *scope.ContainerBuild) !void {}
    }.f);

    tester.expected = "enum(u8) {}";
    try Namespace.build(test_alloc, Test.callback, &tester, .keyword_enum)
        .typing(_xpr("u8")).body(struct {
        fn f(_: *scope.ContainerBuild) !void {}
    }.f);

    tester.expected =
        \\struct {
        \\    foo: Bar,
        \\}
    ;
    var tag: [3]u8 = "Bar".*;
    try Namespace.build(test_alloc, Test.callback, &tester, .keyword_struct)
        .bodyWith(@as([]u8, &tag), struct {
        fn f(ctx: []u8, b: *scope.ContainerBuild) !void {
            try b.field("foo").typing(b.xpr.raw(ctx)).end();
        }
    }.f);
}

pub const WordBlock = struct {
    tokan: ZigToken,
    name: ?[]const u8,
    block: scope.Block,

    pub fn init(
        allocator: Allocator,
        tokan: ZigToken,
        name: ?[]const u8,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), scope.BlockClosure),
    ) !WordBlock {
        var builder = scope.BlockBuild.init(allocator);
        callClosure(ctx, closure, .{&builder}) catch |err| {
            builder.deinit();
            return err;
        };
        return .{
            .tokan = tokan,
            .name = name,
            .block = try builder.consume(),
        };
    }

    pub fn deinit(self: WordBlock, allocator: Allocator) void {
        self.block.deinit(allocator);
    }

    pub fn write(self: WordBlock, writer: *Writer) !void {
        try writer.appendFmt("{s} ", .{self.tokan.lexeme().?});
        if (self.name) |s| {
            try writer.appendFmt("\"{}\" ", .{std.zig.fmtEscapes(s)});
        }
        try self.block.write(writer);
    }
};

test "WordBlock" {
    var tag: [3]u8 = "bar".*;
    const block = try WordBlock.init(
        test_alloc,
        .keyword_test,
        "foo",
        @as([]u8, &tag),
        struct {
            fn f(ctx: []u8, b: *scope.BlockBuild) !void {
                try b.defers(b.xpr.raw(ctx));
            }
        }.f,
    );
    defer block.deinit(test_alloc);
    try Writer.expectValue(
        \\test "foo" {
        \\    defer bar;
        \\}
    , block);
}
