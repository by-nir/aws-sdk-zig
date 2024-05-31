const std = @import("std");
const ZigTag = std.zig.Token.Tag;
const Allocator = std.mem.Allocator;
const decl = @import("../../utils/declarative.zig");
const StackChain = decl.StackChain;
const Closure = decl.Closure;
const callClosure = decl.callClosure;
const Writer = @import("../CodegenWriter.zig");
const testing = @import("../testing.zig");
const test_alloc = testing.allocator;
const flow = @import("flow.zig");
const scope = @import("scope.zig");

pub const Expr = union(enum) {
    _empty,
    _error: anyerror,
    _chain: []const Expr,
    raw: []const u8,
    keyword: ExprKeyword,
    type: ExprType,
    value: ExprValue,
    flow: ExprFlow,

    pub fn deinit(self: Expr, allocator: Allocator) void {
        switch (self) {
            ._chain => |chain| {
                for (chain) |t| t.deinit(allocator);
                allocator.free(chain);
            },
            .flow => |f| f.deinit(allocator),
            else => {},
        }
    }

    pub fn write(self: Expr, writer: *Writer, comptime format: []const u8) anyerror!void {
        switch (self) {
            ._empty => unreachable,
            ._error => |err| return err,
            ._chain => |chain| {
                std.debug.assert(chain.len > 0);
                if (comptime scope.isStatement(format)) {
                    const last = chain.len - 1;
                    for (chain[0..last]) |x| try x.write(writer, "");
                    try chain[last].write(writer, format);
                } else {
                    for (chain) |t| try t.write(writer, format);
                }
            },
            .raw => |s| try writer.appendString(s),
            .flow => |t| try t.write(writer, format),
            inline else => |t| {
                try t.write(writer);
                try scope.statementSemicolon(writer, format, null);
            },
        }
    }
};

const ExprType = union(enum) {
    PLACEHOLDER,

    pub fn write(self: ExprType, writer: *Writer) anyerror!void {
        _ = self; // autofix
        _ = writer; // autofix
    }
};

const ExprValue = union(enum) {
    PLACEHOLDER,

    pub fn write(self: ExprValue, writer: *Writer) anyerror!void {
        _ = self; // autofix
        _ = writer; // autofix
    }
};

const ExprFlow = union(enum) {
    @"if": flow.If,
    @"for": flow.For,
    @"while": *const flow.While,
    @"switch": *const flow.Switch,
    word_expr: *const WordExpr,
    word_capture: *const WordCaptureExpr,
    word_label: flow.WordLabel,
    block: scope.Block,

    pub fn deinit(self: ExprFlow, allocator: Allocator) void {
        switch (self) {
            .word_label => {},
            inline .@"if", .@"for", .block => |t| t.deinit(allocator),
            inline else => |t| {
                t.deinit(allocator);
                allocator.destroy(t);
            },
        }
    }

    pub fn write(self: ExprFlow, writer: *Writer, comptime format: []const u8) !void {
        switch (self) {
            inline .block, .@"switch" => |t| try t.write(writer),
            inline else => |t| try t.write(writer, format),
        }
    }
};

const ExprKeyword = union(enum) {
    PLACEHOLDER,

    pub fn write(self: ExprKeyword, writer: *Writer) anyerror!void {
        _ = self; // autofix
        _ = writer; // autofix
    }
};

pub const ExprBuild = struct {
    allocator: Allocator,
    exprs: StackChain(?Expr) = .{},
    callback_ctx: ?*anyopaque = null,
    callback_fn: ?*const fn (*anyopaque, Expr) anyerror!void = null,

    pub fn init(allocator: Allocator) ExprBuild {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: ExprBuild) void {
        if (self.exprs.isEmpty()) return;
        var it = self.exprs.iterateReversed();
        while (it.next()) |t| t.deinit(self.allocator);
    }

    fn append(self: *const ExprBuild, expr: anyerror!Expr) ExprBuild {
        const value = expr catch |err| Expr{ ._error = err };
        var dupe = self.*;
        dupe.exprs = self.exprs.append(value);
        return dupe;
    }

    fn dupeValue(self: ExprBuild, value: anytype) !*@TypeOf(value) {
        const data = try self.allocator.create(@TypeOf(value));
        data.* = value;
        return data;
    }

    pub fn consume(self: ExprBuild) !Expr {
        if (self.exprs.isEmpty()) {
            return ._empty;
        } else if (self.exprs.len == 1) {
            return self.exprs.value.?;
        } else if (self.exprs.unwrapAlloc(self.allocator)) |chain| {
            return .{ ._chain = chain };
        } else |err| {
            self.deinit();
            return err;
        }
    }

    /// Only use when the expression builder is provided by an external function
    pub fn end(self: ExprBuild) !void {
        const expr = try self.consume();
        if (self.callback_fn) |callback| {
            errdefer expr.deinit(self.allocator);
            try callback(self.callback_ctx.?, expr);
        } else {
            return error.NonCallbackExprBuilder;
        }
    }

    pub fn raw(self: *const ExprBuild, value: []const u8) ExprBuild {
        return self.append(.{ .raw = value });
    }

    //
    // Control Flow
    //

    pub fn @"if"(self: *const ExprBuild, condition: ExprBuild) flow.If.Build(@TypeOf(endIf)) {
        return flow.If.build(self.allocator, endIf, self, condition);
    }

    fn endIf(self: *const ExprBuild, value: anyerror!flow.If) ExprBuild {
        const data = value catch |err| return self.append(err);
        return self.append(.{ .flow = .{ .@"if" = data } });
    }

    test "if" {
        var build = ExprBuild.init(test_alloc);
        const expr = try build.@"if"(_raw("foo")).body(_raw("bar")).end().consume();
        defer expr.deinit(test_alloc);
        try Writer.expectValue("if (foo) bar", expr);
    }

    pub fn @"for"(self: *const ExprBuild) flow.For.Build(@TypeOf(endFor)) {
        return flow.For.build(self.allocator, endFor, self);
    }

    fn endFor(self: *const ExprBuild, value: anyerror!flow.For) ExprBuild {
        const data = value catch |err| return self.append(err);
        return self.append(.{ .flow = .{ .@"for" = data } });
    }

    test "for" {
        var build = ExprBuild.init(test_alloc);
        const expr = try build.@"for"().iter(_raw("foo"), "_")
            .body(_raw("bar")).end().consume();
        defer expr.deinit(test_alloc);
        try Writer.expectValue("for (foo) |_| bar", expr);
    }

    pub fn @"while"(self: *const ExprBuild, condition: ExprBuild) flow.While.Build(@TypeOf(endWhile)) {
        return flow.While.build(self.allocator, endWhile, self, condition);
    }

    fn endWhile(self: *const ExprBuild, value: anyerror!flow.While) ExprBuild {
        const data = value catch |err| return self.append(err);
        const dupe = self.dupeValue(data) catch |err| {
            data.deinit(self.allocator);
            return self.append(err);
        };
        return self.append(.{ .flow = .{ .@"while" = dupe } });
    }

    test "while" {
        var build = ExprBuild.init(test_alloc);
        const expr = try build.@"while"(_raw("foo"))
            .body(_raw("bar")).end().consume();
        defer expr.deinit(test_alloc);
        try Writer.expectValue("while (foo) bar", expr);
    }

    pub fn @"switch"(self: *const ExprBuild, value: ExprBuild, closure: flow.SwitchClosure) ExprBuild {
        return self.switchWith(self, value, {}, closure);
    }

    pub fn switchWith(
        self: *const ExprBuild,
        value: ExprBuild,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), flow.SwitchClosure),
    ) ExprBuild {
        var builder = flow.Switch.build(self.allocator, value);
        callClosure(ctx, closure, .{&builder}) catch |err| {
            builder.deinit();
            return self.append(err);
        };

        const expr = builder.consume() catch |err| return self.append(err);
        const dupe = self.dupeValue(expr) catch |err| {
            expr.deinit(self.allocator);
            return self.append(err);
        };
        return self.append(.{ .flow = .{ .@"switch" = dupe } });
    }

    test "switch" {
        var tag: []const u8 = "bar";
        _ = &tag;

        var builder = ExprBuild.init(test_alloc);
        const expr = try builder.switchWith(_raw("foo"), tag, struct {
            fn f(ctx: []const u8, b: *flow.Switch.Build) !void {
                try b.branch().case(b.xpr.raw(ctx)).body(b.xpr.raw("baz"));
            }
        }.f).consume();
        defer expr.deinit(test_alloc);

        try Writer.expectValue(
            \\switch (foo) {
            \\    bar => baz,
            \\}
        , expr);
    }

    pub fn @"catch"(self: *const ExprBuild) WordCaptureExpr.Build(@TypeOf(endCatch)) {
        return WordCaptureExpr.build(endCatch, self, .keyword_catch);
    }

    fn endCatch(self: *const ExprBuild, value: anyerror!WordCaptureExpr) ExprBuild {
        const data = value catch |err| return self.append(err);
        const dupe = self.dupeValue(data) catch |err| {
            data.deinit(self.allocator);
            return self.append(err);
        };
        return self.append(.{ .flow = .{ .word_capture = dupe } });
    }

    test "catch" {
        var b = ExprBuild.init(test_alloc);
        const expr = try b.@"catch"().capture("foo").body(_raw("bar")).consume();
        defer expr.deinit(test_alloc);
        try Writer.expectValue("catch |foo| bar", expr);
    }

    pub fn returns(self: *const ExprBuild) ExprBuild {
        const data = flow.WordLabel{
            .tag = .keyword_return,
            .label = null,
        };
        return self.append(.{ .flow = .{ .word_label = data } });
    }

    test "returns" {
        var b = ExprBuild.init(test_alloc);
        const expr = try b.returns().raw("foo").consume();
        defer expr.deinit(test_alloc);
        try Writer.expectValue("return foo", expr);
    }

    pub fn breaks(self: *const ExprBuild, label: ?[]const u8) ExprBuild {
        const data = flow.WordLabel{
            .tag = .keyword_break,
            .label = label,
        };
        return self.append(.{ .flow = .{ .word_label = data } });
    }

    test "breaks" {
        var b = ExprBuild.init(test_alloc);
        const expr = try b.breaks("foo").raw("bar").consume();
        defer expr.deinit(test_alloc);
        try Writer.expectValue("break :foo bar", expr);
    }

    pub fn continues(self: *const ExprBuild, label: ?[]const u8) ExprBuild {
        const data = flow.WordLabel{
            .tag = .keyword_continue,
            .label = label,
        };
        return self.append(.{ .flow = .{ .word_label = data } });
    }

    test "continues" {
        var b = ExprBuild.init(test_alloc);
        const expr = try b.continues("foo").raw("bar").consume();
        defer expr.deinit(test_alloc);
        try Writer.expectValue("continue :foo bar", expr);
    }

    pub fn block(self: *const ExprBuild, closure: scope.BlockClosure) ExprBuild {
        return self.blockWith({}, closure);
    }

    pub fn blockWith(
        self: *const ExprBuild,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), scope.BlockClosure),
    ) ExprBuild {
        var builder = scope.BlockBuild.init(self.allocator);
        callClosure(ctx, closure, .{&builder}) catch |err| {
            builder.deinit();
            return self.append(err);
        };
        const data = builder.consume() catch |err| return self.append(err);
        return self.append(.{ .flow = .{ .block = data } });
    }

    test "block" {
        var tag: []const u8 = "bar";
        _ = &tag;

        var builder = ExprBuild.init(test_alloc);
        const expr = try builder.blockWith(tag, struct {
            fn f(ctx: []const u8, b: *scope.BlockBuild) !void {
                try b.@"defer"(b.xpr.raw(ctx));
            }
        }.f).consume();
        defer expr.deinit(test_alloc);

        try Writer.expectValue(
            \\{
            \\    defer bar;
            \\}
        , expr);
    }
};

pub const WordExpr = struct {
    tag: ZigTag,
    expr: ?Expr,

    pub fn deinit(self: WordExpr, allocator: Allocator) void {
        if (self.expr) |t| t.deinit(allocator);
    }

    pub fn write(self: WordExpr, writer: *Writer, comptime format: []const u8) !void {
        const keyword = self.tag.lexeme().?;
        if (self.expr) |t| {
            try writer.appendFmt("{s} {}", .{ keyword, t });
            try scope.statementSemicolon(writer, format, self.expr);
        } else {
            try writer.appendString(keyword);
            try scope.statementSemicolon(writer, format, null);
        }
    }
};

test "WordExpr" {
    var expr = WordExpr{ .tag = .keyword_return, .expr = null };
    {
        defer expr.deinit(test_alloc);
        try Writer.expectValue("return", expr);
        try Writer.expectFmt("return;", "{;}", .{expr});
    }

    expr = WordExpr{ .tag = .keyword_defer, .expr = .{ .raw = "foo" } };
    {
        defer expr.deinit(test_alloc);
        try Writer.expectValue("defer foo", expr);
        try Writer.expectFmt("defer foo;", "{;}", .{expr});
    }

    expr = WordExpr{
        .tag = .keyword_defer,
        .expr = .{ .flow = .{ .block = .{ .statements = &.{} } } },
    };
    {
        defer expr.deinit(test_alloc);
        try Writer.expectFmt("defer {}", "{;}", .{expr});
    }
}

pub const WordCaptureExpr = struct {
    tag: ZigTag,
    payload: ?[]const u8 = null,
    body: Expr,

    pub fn deinit(self: WordCaptureExpr, allocator: Allocator) void {
        self.body.deinit(allocator);
    }

    pub fn write(self: WordCaptureExpr, writer: *Writer, comptime format: []const u8) !void {
        try writer.appendFmt("{s} ", .{self.tag.lexeme().?});
        if (self.payload) |p| {
            try writer.appendFmt("|{_}| ", .{std.zig.fmtId(p)});
        }
        try writer.appendValue(self.body);
        try scope.statementSemicolon(writer, format, self.body);
    }

    pub fn build(callback: anytype, ctx: anytype, tag: ZigTag) Build(@TypeOf(callback)) {
        return .{
            .callback = decl.callback(ctx, callback),
            .tag = tag,
        };
    }

    pub fn Build(comptime Fn: type) type {
        const Callback = decl.InferCallback(Fn);
        return struct {
            const Self = @This();

            callback: Callback,
            tag: ZigTag,
            payload: ?[]const u8 = null,

            pub fn capture(self: Self, payload: []const u8) Self {
                std.debug.assert(self.payload == null);
                var dupe = self;
                dupe.payload = payload;
                return dupe;
            }

            pub fn body(self: Self, expr: ExprBuild) Callback.Return {
                if (expr.consume()) |data| {
                    return self.callback.invoke(.{
                        .tag = self.tag,
                        .payload = self.payload,
                        .body = data,
                    });
                } else |err| {
                    return self.callback.fail(err);
                }
            }
        };
    }
};

test "WordCaptureExpr" {
    const Test = testing.TestVal(WordCaptureExpr);
    var tester = Test{ .expected = "errdefer foo" };
    try WordCaptureExpr.build(Test.callback, &tester, .keyword_errdefer).body(_raw("foo"));

    tester.expected = "errdefer |foo| bar";
    try WordCaptureExpr.build(Test.callback, &tester, .keyword_errdefer)
        .capture("foo").body(_raw("bar"));
}

test "WordCaptureExpr: statement" {
    const Test = testing.TestFmt(WordCaptureExpr, "{;}");
    var tester = Test{ .expected = "errdefer foo;" };
    try WordCaptureExpr.build(Test.callback, &tester, .keyword_errdefer).body(_raw("foo"));

    tester.expected = "errdefer {}";
    try WordCaptureExpr.build(Test.callback, &tester, .keyword_errdefer).body(_blk);
}

pub fn _raw(str: []const u8) ExprBuild {
    return .{
        .allocator = test_alloc,
        .exprs = StackChain(?Expr).start(.{ .raw = str }),
    };
}

pub const _blk = ExprBuild{
    .allocator = test_alloc,
    .exprs = StackChain(?Expr).start(Expr{
        .flow = .{ .block = .{ .statements = &.{} } },
    }),
};

test {
    _ = ExprBuild;
}
