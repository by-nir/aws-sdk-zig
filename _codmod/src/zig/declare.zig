const std = @import("std");
const ZigToken = std.zig.Token.Tag;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const test_alloc = std.testing.allocator;
const dcl = @import("../utils/declarative.zig");
const StackChain = dcl.StackChain;
const cb = dcl.callback;
const InferCallback = dcl.InferCallback;
const Closure = dcl.Closure;
const callClosure = dcl.callClosure;
const Writer = @import("../CodegenWriter.zig");
const scope = @import("scope.zig");
const utils = @import("utils.zig");
const exp = @import("expr.zig");
const Expr = exp.Expr;
const ExprBuild = exp.ExprBuild;
const _xpr = exp._raw;

pub const Field = struct {
    /// `null` when part of a tuple.
    name: ?[]const u8,
    /// may be `null` when part of an enum/union.
    type: ?Expr,
    alignment: ?Expr,
    assign: ?Expr,

    pub fn deinit(self: Field, allocator: Allocator) void {
        if (self.type) |t| t.deinit(allocator);
        if (self.alignment) |t| t.deinit(allocator);
        if (self.assign) |t| t.deinit(allocator);
    }

    pub fn write(self: Field, writer: *Writer) !void {
        if (self.name) |s| {
            try writer.appendFmt("{_}", .{std.zig.fmtId(s)});
        }
        if (self.type) |t| {
            if (self.name == null) {
                try writer.appendValue(t);
            } else {
                try writer.appendFmt(": {}", .{t});
            }
            if (self.alignment) |a| try writer.appendFmt(" align({})", .{a});
        }
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
                const alloc_type = if (self.type) |t| t.consume() catch |err| {
                    if (self.@"align") |x| x.deinit();
                    if (assignment) |x| x.deinit();
                    return err;
                } else null;
                errdefer if (alloc_type) |t| t.deinit(self.type.?.allocator);

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
    const Test = utils.TestVal(Field);
    var tester = Test{ .expected = "foo" };
    try Field.build(Test.callback, &tester, "foo").end();

    tester.expected = "foo: Bar";
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
    expr: Expr,
    is_assign: bool,

    pub fn deinit(self: Variable, allocator: Allocator) void {
        if (self.type) |t| t.deinit(allocator);
        if (self.alignment) |t| t.deinit(allocator);
        self.expr.deinit(allocator);
    }

    pub fn write(self: Variable, writer: *Writer) !void {
        try writer.appendString(if (self.is_const) "const " else "var ");
        try writer.appendFmt("{}", .{std.zig.fmtId(self.name)});
        if (self.type) |t| {
            try writer.appendFmt(": {}", .{t});
            if (self.alignment) |a| try writer.appendFmt(" align({})", .{a});
        }
        if (self.is_assign) {
            try writer.appendFmt(" = {}", .{self.expr});
        } else {
            try writer.appendFmt(", {}", .{self.expr});
        }
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
                if (self.consume(expr, true)) |data| {
                    return self.callback.invoke(data);
                } else |err| {
                    return self.callback.fail(err);
                }
            }

            pub fn comma(self: Self, expr: ExprBuild) Callback.Return {
                if (self.consume(expr, false)) |data| {
                    return self.callback.invoke(data);
                } else |err| {
                    return self.callback.fail(err);
                }
            }

            fn consume(self: Self, expr: ExprBuild, is_assign: bool) !Variable {
                const alloc_expr = expr.consume() catch |err| {
                    if (self.type) |t| t.deinit();
                    if (self.@"align") |x| x.deinit();
                    return err;
                };
                errdefer alloc_expr.deinit(expr.allocator);

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
                    .expr = alloc_expr,
                    .is_assign = is_assign,
                };
            }
        };
    }
};

test "Variable" {
    const Test = utils.TestVal(Variable);
    var tester = Test{ .expected = "var foo = bar" };
    try Variable.build(Test.callback, &tester, false, "foo").assign(_xpr("bar"));

    tester.expected = "var @\"test\", foo";
    try Variable.build(Test.callback, &tester, false, "test").comma(_xpr("foo"));

    tester.expected = "const foo: Bar align(baz) = qux";
    try Variable.build(Test.callback, &tester, true, "foo").typing(_xpr("Bar"))
        .alignment(_xpr("baz")).assign(_xpr("qux"));
}

pub const Namespace = struct {
    token: ZigToken,
    type: ?Expr,
    container: scope.Container,

    pub fn deinit(self: Namespace, allocator: Allocator) void {
        self.container.deinit(allocator);
        if (self.type) |t| t.deinit(allocator);
    }

    pub fn write(self: Namespace, writer: *Writer) !void {
        try writer.appendString(self.token.lexeme().?);
        if (self.type) |t| {
            try writer.appendFmt("({})", .{t});
        } else if (self.token == .keyword_union) {
            try writer.appendString("(enum)");
        }

        if (self.container.statements.len == 0) {
            return writer.appendString(" {}");
        } else {
            try writer.appendString(" {\n");
            try writer.pushIndent(utils.INDENT_STR);
            try self.container.write(writer);
            writer.popIndent();
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
            type: ?ExprBuild = null,

            pub fn deinit(self: Self) void {
                if (self.type) |t| t.deinit();
            }

            pub fn backedBy(self: Self, expr: ExprBuild) Self {
                assert(self.type == null);
                var dupe = self;
                dupe.type = expr;
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
                const alloc_type = if (self.type) |t| t.consume() catch |err| {
                    return self.callback.fail(err);
                } else null;

                const data = scope.Container.init(self.allocator, ctx, closure) catch |err| {
                    if (alloc_type) |t| t.deinit(self.allocator);
                    return self.callback.fail(err);
                };

                return self.callback.invoke(.{
                    .token = self.token,
                    .type = alloc_type,
                    .container = data,
                });
            }
        };
    }
};

test "Namespace" {
    const Test = utils.TestVal(Namespace);
    var tester = Test{ .expected = "union(enum) {}" };
    try Namespace.build(test_alloc, Test.callback, &tester, .keyword_union).body(struct {
        fn f(_: *scope.ContainerBuild) !void {}
    }.f);

    tester.expected = "enum(u8) {}";
    try Namespace.build(test_alloc, Test.callback, &tester, .keyword_enum)
        .backedBy(_xpr("u8")).body(struct {
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
            try b.field("foo").typing(b.x.raw(ctx)).end();
        }
    }.f);
}

pub const TokenBlock = struct {
    tokan: ZigToken,
    name: ?[]const u8,
    block: scope.Block,

    pub fn init(
        allocator: Allocator,
        tokan: ZigToken,
        name: ?[]const u8,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), scope.BlockClosure),
    ) !TokenBlock {
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

    pub fn deinit(self: TokenBlock, allocator: Allocator) void {
        self.block.deinit(allocator);
    }

    pub fn write(self: TokenBlock, writer: *Writer) !void {
        try writer.appendFmt("{s} ", .{self.tokan.lexeme().?});
        if (self.name) |s| {
            try writer.appendFmt("\"{}\" ", .{std.zig.fmtEscapes(s)});
        }
        try self.block.write(writer);
    }
};

test "TokenBlock" {
    var tag: [3]u8 = "bar".*;
    const block = try TokenBlock.init(
        test_alloc,
        .keyword_test,
        "foo",
        @as([]u8, &tag),
        struct {
            fn f(ctx: []u8, b: *scope.BlockBuild) !void {
                try b.defers(b.x.raw(ctx));
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

pub const Function = struct {
    name: []const u8,
    args: []const Arg,
    conv: ?std.builtin.CallingConvention,
    @"return": ?Expr,
    body: scope.Block,

    pub const Arg = struct {
        name: []const u8,
        type: ?Expr,

        pub fn deinit(self: Arg, allocator: Allocator) void {
            if (self.type) |t| t.deinit(allocator);
        }

        pub fn write(self: Arg, writer: *Writer) !void {
            const name = if (std.mem.startsWith(u8, self.name, "comptime ")) blk: {
                try writer.appendString("comptime ");
                break :blk std.zig.fmtId(self.name[9..self.name.len]);
            } else std.zig.fmtId(self.name);

            if (self.type) |t| {
                try writer.appendFmt("{_}: {}", .{ name, t });
            } else {
                try writer.appendFmt("{_}: anytype", .{name});
            }
        }
    };

    pub fn deinit(self: Function, allocator: Allocator) void {
        for (self.args) |t| t.deinit(allocator);
        allocator.free(self.args);
        if (self.@"return") |t| t.deinit(allocator);
        self.body.deinit(allocator);
    }

    pub fn write(self: Function, writer: *Writer) !void {
        try writer.appendFmt("fn {}(", .{std.zig.fmtId(self.name)});
        try writer.appendList(Arg, self.args, .{
            .delimiter = ", ",
        });
        try writer.appendString(") ");
        if (self.conv) |c| {
            try writer.appendFmt("callconv(.{s}) ", .{@tagName(c)});
        }
        if (self.@"return") |t| {
            try writer.appendFmt("{} ", .{t});
        } else {
            try writer.appendString("void ");
        }
        try self.body.write(writer);
    }

    pub fn build(
        allocator: Allocator,
        callback: anytype,
        ctx: anytype,
        name: []const u8,
    ) Build(@TypeOf(callback)) {
        return .{
            .allocator = allocator,
            .callback = cb(ctx, callback),
            .name = name,
        };
    }

    pub const ArgBuild = struct {
        name: []const u8,
        type: ?ExprBuild,

        pub fn deinit(self: ArgBuild) void {
            if (self.type) |t| t.deinit();
        }

        pub fn consume(self: ArgBuild) !Arg {
            return .{
                .name = self.name,
                .type = if (self.type) |t| try t.consume() else null,
            };
        }
    };

    pub fn Build(comptime Fn: type) type {
        const Callback = InferCallback(Fn);
        return struct {
            const Self = @This();

            allocator: Allocator,
            callback: Callback,
            name: []const u8,
            args: StackChain(?ArgBuild) = .{},
            conv: ?std.builtin.CallingConvention = null,
            @"return": ?ExprBuild = null,

            pub fn deinit(self: Self) void {
                var it = self.args.iterateReversed();
                while (it.next()) |a| if (a.type) |at| at.deinit();
                if (self.@"return") |t| t.deinit();
            }

            pub fn arg(self: *const Self, name: []const u8, typing: ?ExprBuild) Self {
                assert(self.@"return" == null);
                var dupe = self.*;
                dupe.args = self.args.append(.{
                    .name = name,
                    .type = typing,
                });
                return dupe;
            }

            pub fn callConv(self: Self, conv: std.builtin.CallingConvention) Self {
                assert(self.conv == null);
                assert(self.@"return" == null);
                var dupe = self;
                dupe.conv = conv;
                return dupe;
            }

            pub fn returns(self: Self, typing: ExprBuild) Self {
                assert(self.@"return" == null);
                var dupe = self;
                dupe.@"return" = typing;
                return dupe;
            }

            pub fn body(self: Self, closure: scope.BlockClosure) Callback.Return {
                if (self.consume({}, closure)) |data| {
                    return self.callback.invoke(data);
                } else |err| {
                    return self.callback.fail(err);
                }
            }

            pub fn bodyWith(
                self: Self,
                ctx: anytype,
                closure: Closure(@TypeOf(ctx), scope.BlockClosure),
            ) Callback.Return {
                if (self.consume(ctx, closure)) |data| {
                    return self.callback.invoke(data);
                } else |err| {
                    return self.callback.fail(err);
                }
            }

            fn consume(
                self: Self,
                ctx: anytype,
                closure: Closure(@TypeOf(ctx), scope.BlockClosure),
            ) !Function {
                const alloc_args = utils.consumeChainAs(
                    self.allocator,
                    ArgBuild,
                    Arg,
                    self.args,
                ) catch |err| {
                    if (self.@"return") |t| t.deinit();
                    return err;
                };
                errdefer {
                    for (alloc_args) |t| t.deinit(self.allocator);
                    self.allocator.free(alloc_args);
                }

                const alloc_return = if (self.@"return") |t| try t.consume() else null;
                errdefer if (alloc_return) |t| t.deinit(self.allocator);

                var builder = scope.BlockBuild.init(self.allocator);
                errdefer builder.deinit();
                try callClosure(ctx, closure, .{&builder});

                return .{
                    .name = self.name,
                    .args = alloc_args,
                    .conv = self.conv,
                    .@"return" = alloc_return,
                    .body = try builder.consume(),
                };
            }
        };
    }
};

test "Function" {
    const Test = utils.TestVal(Function);
    var tester = Test{ .expected = 
    \\fn foo(bar: Bar, baz: anytype) callconv(.C) Qux {
    \\    defer foo;
    \\}
    };
    try Function.build(test_alloc, Test.callback, &tester, "foo")
        .arg("bar", _xpr("Bar")).arg("baz", null)
        .callConv(.C)
        .returns(_xpr("Qux")).body(struct {
        fn f(b: *scope.BlockBuild) !void {
            try b.defers(b.x.raw("foo"));
        }
    }.f);
}
