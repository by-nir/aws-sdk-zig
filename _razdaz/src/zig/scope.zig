const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const test_alloc = std.testing.allocator;
const dcl = @import("../utils/declarative.zig");
const StackChain = dcl.StackChain;
const Closure = dcl.Closure;
const callClosure = dcl.callClosure;
const md = @import("../md.zig");
const Writer = @import("../CodegenWriter.zig");
const declare = @import("declare.zig");
const utils = @import("utils.zig");
const flow = @import("flow.zig");
const exp = @import("expr.zig");
const Expr = exp.Expr;
const ExprBuild = exp.ExprBuild;
const ExprComment = exp.ExprComment;

pub const Container = struct {
    statements: []const Expr,

    pub fn init(
        allocator: Allocator,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), ContainerClosure),
    ) !Container {
        var build = ContainerBuild{
            .allocator = allocator,
            .x = .{ .allocator = allocator },
        };
        errdefer build.deinit();
        try callClosure(ctx, closure, .{&build});
        return build.consume();
    }

    pub fn deinit(self: Container, allocator: Allocator) void {
        for (self.statements) |t| t.deinit(allocator);
        allocator.free(self.statements);
    }

    pub fn write(self: Container, writer: *Writer) !void {
        for (self.statements, 0..) |expr, i| {
            if (i == 0) {
                try writer.appendFmt("{s}{;}", .{ writer.prefix, expr });
            } else {
                if (self.shouldPadStatement(expr, i)) try writer.breakEmpty(1);
                try writer.breakFmt("{;}", .{expr});
            }
        }
    }

    fn shouldPadStatement(self: Container, current: Expr, i: usize) bool {
        const prev = self.statements[i - 1];
        if (prev == .comment) return false;
        if (prev == .declare and prev.declare == .field) {
            switch (current) {
                .declare => |t| return t != .field,
                .comment => {
                    if (i == self.statements.len - 1) return true;
                    const next = self.statements[i + 1];
                    if (next == .declare and next.declare == .field) return false;
                },
                else => {},
            }
        }
        return true;
    }
};

test "Container" {
    try Writer.expectValue(
        \\foo: Bar,
        \\baz: Qux,
        \\
        \\usingnamespace foo;
    , Container{
        .statements = &.{
            .{ .declare = .{ .field = &declare.Field{
                .name = "foo",
                .type = .{ .raw = "Bar" },
                .alignment = null,
                .assign = null,
            } } },
            .{ .declare = .{ .field = &declare.Field{
                .name = "baz",
                .type = .{ .raw = "Qux" },
                .alignment = null,
                .assign = null,
            } } },
            .{ .declare = .{ .token_expr = &exp.TokenExpr{
                .token = .keyword_usingnamespace,
                .expr = .{ .raw = "foo" },
            } } },
        },
    });
}

pub const ContainerClosure = *const fn (*ContainerBuild) anyerror!void;
pub const ContainerBuild = struct {
    allocator: Allocator,
    prefix_len: u3 = 0,
    prefixes: [4]Expr = undefined,
    statements: std.ArrayListUnmanaged(Expr) = .{},
    x: ExprBuild,

    pub fn init(allocator: Allocator) ContainerBuild {
        return .{
            .allocator = allocator,
            .x = .{ .allocator = allocator },
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

    fn appendPrefix(self: *ContainerBuild, expr: Expr) *ContainerBuild {
        assert(self.prefix_len < 4);
        self.prefixes[self.prefix_len] = expr;
        self.prefix_len += 1;
        return self;
    }

    fn appendStatement(self: *ContainerBuild, expr: Expr) !void {
        if (self.prefix_len == 0) {
            try self.statements.append(self.allocator, expr);
        } else switch (expr) {
            ._chain => |c| {
                defer self.prefix_len = 0;
                const statement = try self.allocator.alloc(Expr, self.prefix_len + c.len);
                errdefer self.allocator.free(statement);
                @memcpy(statement[0..self.prefix_len], self.prefixes[0..self.prefix_len]);
                @memcpy(statement[self.prefix_len..], c);
                try self.statements.append(self.allocator, .{
                    ._chain = statement,
                });
                self.allocator.free(c);
            },
            else => {
                defer self.prefix_len = 0;
                const statement = try self.allocator.alloc(Expr, self.prefix_len + 1);
                errdefer self.allocator.free(statement);
                @memcpy(statement[0..self.prefix_len], self.prefixes[0..self.prefix_len]);
                statement[self.prefix_len] = expr;
                try self.statements.append(self.allocator, .{
                    ._chain = statement,
                });
            },
        }
    }

    fn dupeValue(self: ContainerBuild, value: anytype) !*@TypeOf(value) {
        const data = try self.allocator.create(@TypeOf(value));
        data.* = value;
        return data;
    }

    pub fn comment(self: *ContainerBuild, kind: ExprComment.Kind, value: []const u8) !void {
        try self.appendStatement(.{ .comment = .{
            .kind = kind,
            .source = .{ .plain = value },
        } });
    }

    test "comment" {
        var b = init(test_alloc);
        errdefer b.deinit();

        try b.comment(.normal, "foo\nbar");
        try b.constant("foo").assign(b.x.raw("bar"));

        const data = try b.consume();
        defer data.deinit(test_alloc);
        try Writer.expectValue(
            \\// foo
            \\// bar
            \\const foo = bar;
        , data);
    }

    pub fn commentMarkdown(
        self: *ContainerBuild,
        kind: ExprComment.Kind,
        closure: md.DocumentClosure,
    ) !void {
        try self.commentMarkdownWith(kind, {}, closure);
    }

    pub fn commentMarkdownWith(
        self: *ContainerBuild,
        kind: ExprComment.Kind,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), md.DocumentClosure),
    ) !void {
        var doc = try md.authorDocument(self.allocator, ctx, closure);
        errdefer doc.deinit(self.allocator);

        try self.appendStatement(.{ .comment = .{
            .kind = kind,
            .source = .{ .markdown = doc },
        } });
    }

    test "commentMarkdown" {
        var b = init(test_alloc);
        errdefer b.deinit();

        try b.commentMarkdown(.doc, struct {
            fn f(m: md.ContainerAuthor) !void {
                try m.heading(1, "qux");
            }
        }.f);
        try b.constant("foo").assign(b.x.raw("bar"));

        const data = try b.consume();
        defer data.deinit(test_alloc);
        try Writer.expectValue(
            \\/// # qux
            \\const foo = bar;
        , data);
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
        try self.appendStatement(.{
            .declare = .{ .field = dupe },
        });
    }

    test "field" {
        var b = init(test_alloc);
        errdefer b.deinit();
        try b.field("foo").typing(b.x.raw("Bar")).end();
        try b.expect("foo: Bar");
    }

    pub fn using(self: *ContainerBuild, expr: ExprBuild) !void {
        const data = try expr.consume();
        errdefer data.deinit(self.allocator);
        const dupe = try self.dupeValue(exp.TokenExpr{
            .token = .keyword_usingnamespace,
            .expr = data,
        });
        errdefer self.allocator.destroy(dupe);
        try self.appendStatement(.{
            .declare = .{ .token_expr = dupe },
        });
    }

    test "using" {
        var b = init(test_alloc);
        errdefer b.deinit();
        try b.using(b.x.raw("foo"));
        try b.expect("usingnamespace foo");
    }

    pub fn variable(
        self: *ContainerBuild,
        name: []const u8,
    ) declare.Variable.Build(@TypeOf(endVariable)) {
        return declare.Variable.build(endVariable, self, false, name);
    }

    pub fn constant(
        self: *ContainerBuild,
        name: []const u8,
    ) declare.Variable.Build(@TypeOf(endVariable)) {
        return declare.Variable.build(endVariable, self, true, name);
    }

    fn endVariable(self: *ContainerBuild, value: declare.Variable) !void {
        errdefer value.deinit(self.allocator);
        const dupe = try self.dupeValue(value);
        errdefer self.allocator.destroy(dupe);
        try self.appendStatement(.{
            .declare = .{ .variable = dupe },
        });
    }

    test "variables" {
        var b = init(test_alloc);
        errdefer b.deinit();
        try b.variable("foo").assign(b.x.raw("bar"));
        try b.expect("var foo = bar");

        b.deinit();
        b = init(test_alloc);
        try b.constant("foo").assign(b.x.raw("bar"));
        try b.expect("const foo = bar");
    }

    pub fn function(self: *ContainerBuild, name: []const u8) declare.Function.Build(@TypeOf(endFunction)) {
        return declare.Function.build(self.allocator, endFunction, self, name);
    }

    fn endFunction(self: *ContainerBuild, value: declare.Function) !void {
        errdefer value.deinit(self.allocator);
        const dupe = try self.dupeValue(value);
        errdefer self.allocator.destroy(dupe);
        try self.appendStatement(.{
            .declare = .{ .function = dupe },
        });
    }

    test "function" {
        var b = init(test_alloc);
        errdefer b.deinit();
        try b.function("foo").arg("bar", b.x.raw("Bar"))
            .arg("baz", null).returns(b.x.raw("Qux")).body(struct {
            fn f(bf: *BlockBuild) !void {
                try bf.defers(bf.x.raw("foo"));
            }
        }.f);
        try b.expect(
            \\fn foo(bar: Bar, baz: anytype) Qux {
            \\    defer foo;
            \\}
        );
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
        const data = try declare.TokenBlock.init(
            self.allocator,
            .keyword_comptime,
            null,
            ctx,
            closure,
        );
        errdefer data.deinit(self.allocator);
        try self.appendStatement(.{
            .declare = .{ .token_block = data },
        });
    }

    test "comptimeBlock" {
        var b = init(test_alloc);
        errdefer b.deinit();
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
        const data = try declare.TokenBlock.init(self.allocator, .keyword_test, name, ctx, closure);
        errdefer data.deinit(self.allocator);
        try self.appendStatement(.{
            .declare = .{ .token_block = data },
        });
    }

    test "testBlock" {
        var b = init(test_alloc);
        errdefer b.deinit();
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

    //
    // Prefix
    //

    pub fn public(self: *ContainerBuild) *ContainerBuild {
        return self.appendPrefix(.{ .keyword_space = .keyword_pub });
    }

    pub fn threadLocal(self: *ContainerBuild) *ContainerBuild {
        return self.appendPrefix(.{ .keyword_space = .keyword_threadlocal });
    }

    pub fn exports(self: *ContainerBuild) *ContainerBuild {
        return self.appendPrefix(.{ .keyword_space = .keyword_export });
    }

    pub fn externs(self: *ContainerBuild, name: ?[]const u8) *ContainerBuild {
        const data = exp.TokenStrExpr{
            .token = .keyword_extern,
            .string = name,
        };
        return self.appendPrefix(.{ .declare = .{ .token_str = data } });
    }

    pub fn inlines(self: *ContainerBuild) *ContainerBuild {
        return self.appendPrefix(.{ .keyword = .keyword_inline });
    }

    pub fn noInline(self: *ContainerBuild) *ContainerBuild {
        return self.appendPrefix(.{ .keyword = .keyword_noinline });
    }

    test "prefix" {
        var b = init(test_alloc);
        errdefer b.deinit();
        try b.public().exports().using(b.x.raw("foo"));
        try b.expect("pub export usingnamespace foo");
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
        try writer.pushIndent(utils.INDENT_STR);
        for (self.statements, 0..) |statement, i| {
            // Empty line padding, unless previous is a comment
            if (i > 0 and self.statements[i - 1] != .comment) try writer.breakEmpty(1);
            try writer.breakFmt("{;}", .{statement});
        }
        writer.popIndent();
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
    x: ExprBuild,

    pub fn init(allocator: Allocator) BlockBuild {
        return .{
            .allocator = allocator,
            .x = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *BlockBuild) void {
        for (self.statements.items) |t| t.deinit(self.allocator);
        self.statements.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn consume(self: *BlockBuild) !Block {
        const statements = try self.statements.toOwnedSlice(self.allocator);
        return .{ .statements = statements };
    }

    fn startChain(self: *BlockBuild) ExprBuild {
        var expr = self.x;
        expr.callback_ctx = self;
        expr.callback_fn = appendChain;
        return expr;
    }

    fn startChainWith(self: *BlockBuild, expr: Expr) ExprBuild {
        return .{
            .allocator = self.allocator,
            .callback_ctx = self,
            .callback_fn = appendChain,
            .exprs = StackChain(?Expr).start(expr),
        };
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

    pub fn raw(self: *BlockBuild, string: []const u8) !void {
        return self.append(.{ .raw = string });
    }

    pub fn id(self: *BlockBuild, name: []const u8) ExprBuild {
        return self.startChain().id(name);
    }

    test "id" {
        var b = init(test_alloc);
        errdefer b.deinit();
        try b.id("foo").dot().raw("bar").end();
        try b.expect("foo.bar");
    }

    pub fn fromExpr(self: *BlockBuild, value: Expr) ExprBuild {
        return self.startChain().fromExpr(value);
    }

    pub fn buildExpr(self: *BlockBuild, value: ExprBuild) ExprBuild {
        return self.startChain().buildExpr(value);
    }

    pub fn comment(self: *BlockBuild, kind: ExprComment.Kind, value: []const u8) !void {
        try self.append(.{ .comment = .{
            .kind = kind,
            .source = .{ .plain = value },
        } });
    }

    test "comment" {
        var b = init(test_alloc);
        errdefer b.deinit();

        try b.comment(.normal, "foo\nbar");
        try b.constant("foo").assign(b.x.raw("bar"));

        const data = try b.consume();
        defer data.deinit(test_alloc);
        try Writer.expectValue(
            \\{
            \\    // foo
            \\    // bar
            \\    const foo = bar;
            \\}
        , data);
    }

    pub fn commentMarkdown(
        self: *BlockBuild,
        kind: ExprComment.Kind,
        closure: md.DocumentClosure,
    ) !void {
        try self.commentMarkdownWith(kind, {}, closure);
    }

    pub fn commentMarkdownWith(
        self: *BlockBuild,
        kind: ExprComment.Kind,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), md.DocumentClosure),
    ) !void {
        var doc = try md.authorDocument(self.allocator, ctx, closure);
        errdefer doc.deinit(self.allocator);

        try self.append(.{ .comment = .{
            .kind = kind,
            .source = .{ .markdown = doc },
        } });
    }

    test "commentMarkdown" {
        var b = init(test_alloc);
        errdefer b.deinit();

        try b.commentMarkdown(.doc, struct {
            fn f(m: md.ContainerAuthor) !void {
                try m.heading(1, "qux");
            }
        }.f);
        try b.constant("foo").assign(b.x.raw("bar"));

        const data = try b.consume();
        defer data.deinit(test_alloc);
        try Writer.expectValue(
            \\{
            \\    /// # qux
            \\    const foo = bar;
            \\}
        , data);
    }

    pub fn variable(
        self: *BlockBuild,
        name: []const u8,
    ) declare.Variable.Build(@TypeOf(endVariable)) {
        return declare.Variable.build(endVariable, self, false, name);
    }

    pub fn constant(
        self: *BlockBuild,
        name: []const u8,
    ) declare.Variable.Build(@TypeOf(endVariable)) {
        return declare.Variable.build(endVariable, self, true, name);
    }

    fn endVariable(self: *BlockBuild, value: declare.Variable) !void {
        errdefer value.deinit(self.allocator);
        const dupe = try self.dupeValue(value);
        errdefer self.allocator.destroy(dupe);
        try self.append(.{
            .declare = .{ .variable = dupe },
        });
    }

    test "variables" {
        var b = init(test_alloc);
        errdefer b.deinit();
        try b.variable("foo").comma(b.x.constant("bar").assign(b.x.raw("baz")));
        try b.expect("var foo, const bar = baz");
    }

    pub fn discard(self: *BlockBuild) ExprBuild {
        return self.startChain().raw("_ = ");
    }

    pub fn valueOf(self: *BlockBuild, v: anytype) ExprBuild {
        return self.startChain().valueOf(v);
    }

    pub fn typeOf(self: *BlockBuild, comptime T: type) ExprBuild {
        return self.startChain().typeOf(T);
    }

    pub fn This(self: *BlockBuild) ExprBuild {
        return self.startChain().This();
    }

    pub fn compTime(self: *BlockBuild, name: []const u8, args: []const ExprBuild) ExprBuild {
        return self.startChain().compTime(name, args);
    }

    pub fn @"if"(self: *BlockBuild, condition: ExprBuild) flow.If.Build(@TypeOf(endIf)) {
        return flow.If.build(self.allocator, endIf, self, condition);
    }

    fn endIf(self: *BlockBuild, value: flow.If) !void {
        errdefer value.deinit(self.allocator);
        try self.append(.{ .flow = .{ .@"if" = value } });
    }

    test "if" {
        var b = init(test_alloc);
        errdefer b.deinit();
        try b.@"if"(b.x.raw("foo")).body(b.x.raw("bar")).end();
        try b.expect("if (foo) bar");
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
        errdefer b.deinit();
        try b.@"for"().iter(b.x.raw("foo"), "_").body(b.x.raw("bar")).end();
        try b.expect("for (foo) |_| bar");
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
        errdefer b.deinit();
        try b.@"while"(b.x.raw("foo")).body(b.x.raw("bar")).end();
        try b.expect("while (foo) bar");
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
        errdefer b.deinit();
        try b.@"switch"(b.x.raw("foo"), struct {
            fn f(_: *flow.Switch.Build) !void {}
        }.f);
        try b.expect("switch (foo) {}");

        var tag: [3]u8 = "bar".*;
        try b.switchWith(b.x.raw("foo"), @as([]u8, &tag), struct {
            fn f(ctx: []u8, s: *flow.Switch.Build) !void {
                try s.branch().case(s.x.raw(ctx)).body(s.x.raw("baz"));
            }
        }.f);
        try b.expect(
            \\switch (foo) {
            \\    bar => baz,
            \\}
        );
    }

    pub fn call(self: *BlockBuild, name: []const u8, args: []const ExprBuild) ExprBuild {
        return self.startChain().call(name, args);
    }

    test "call" {
        var b = init(test_alloc);
        errdefer b.deinit();
        try b.call("foo", &.{ b.x.raw("bar"), b.x.raw("baz") }).end();
        try b.expect("foo(bar, baz)");
    }

    pub fn defers(self: *BlockBuild, expr: ExprBuild) !void {
        const data = exp.TokenExpr{
            .token = .keyword_defer,
            .expr = try expr.consume(),
        };
        errdefer data.deinit(self.allocator);
        const dupe = try self.dupeValue(data);
        errdefer self.allocator.destroy(dupe);
        try self.append(.{ .flow = .{ .token_expr = dupe } });
    }

    test "defers" {
        var b = init(test_alloc);
        errdefer b.deinit();
        try b.defers(b.x.raw("foo"));
        try b.expect("defer foo");
    }

    pub fn errorDefers(self: *BlockBuild) exp.TokenCaptureExpr.Build(@TypeOf(endErrorDefers)) {
        return exp.TokenCaptureExpr.build(endErrorDefers, self, .keyword_errdefer);
    }

    fn endErrorDefers(self: *BlockBuild, value: exp.TokenCaptureExpr) !void {
        errdefer value.deinit(self.allocator);
        const data = try self.dupeValue(value);
        errdefer self.allocator.destroy(data);
        try self.append(.{ .flow = .{ .token_capture = data } });
    }

    test "errorDefers" {
        var b = init(test_alloc);
        errdefer b.deinit();
        try b.errorDefers().body(b.x.raw("foo"));
        try b.expect("errdefer foo");
    }

    pub fn label(self: *BlockBuild, name: []const u8) ExprBuild {
        return self.startChain().label(name);
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
        errdefer b.deinit();
        try b.block(struct {
            fn f(_: *BlockBuild) !void {}
        }.f);
        try b.expect("{}");

        var tag: [3]u8 = "bar".*;
        try b.blockWith(@as([]u8, &tag), struct {
            fn f(ctx: []u8, k: *BlockBuild) !void {
                try k.defers(k.x.raw(ctx));
            }
        }.f);
        try b.expect(
            \\{
            \\    defer bar;
            \\}
        );
    }

    pub fn trys(self: *BlockBuild) ExprBuild {
        return self.startChain().trys();
    }

    pub fn inlines(self: *BlockBuild) ExprBuild {
        return self.startChain().inlines();
    }

    pub fn returns(self: *BlockBuild) ExprBuild {
        return self.startChain().returns();
    }

    pub fn breaks(self: *BlockBuild, lbl: ?[]const u8) ExprBuild {
        return self.startChain().breaks(lbl);
    }

    pub fn continues(self: *BlockBuild, lbl: ?[]const u8) ExprBuild {
        return self.startChain().continues(lbl);
    }

    test "reflows" {
        var b = init(test_alloc);
        errdefer b.deinit();
        try b.trys().raw("foo").end();
        try b.expect("try foo");

        try b.inlines().raw("foo").end();
        try b.expect("inline foo");

        try b.returns().raw("foo").end();
        try b.expect("return foo");

        try b.breaks("foo").raw("bar").end();
        try b.expect("break :foo bar");

        try b.continues("foo").raw("bar").end();
        try b.expect("continue :foo bar");
    }

    fn expect(self: *BlockBuild, expected: []const u8) !void {
        const data = try self.consume();
        defer data.deinit(test_alloc);
        try Writer.expectValue(expected, data.statements[0]);
    }
};

pub const BlockLabel = struct {
    name: []const u8,

    pub fn write(self: BlockLabel, writer: *Writer) !void {
        try writer.appendFmt("{_}: ", .{std.zig.fmtId(self.name)});
    }
};

test "BlockLabel" {
    const expr = BlockLabel{ .name = "foo" };
    try Writer.expectValue("foo: ", expr);
}

test {
    _ = BlockBuild;
    _ = ContainerBuild;
}
