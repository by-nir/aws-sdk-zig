const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const test_alloc = std.testing.allocator;
const dcl = @import("../utils/declarative.zig");
const StackChain = dcl.StackChain;
const InferCallback = dcl.InferCallback;
const Cb = dcl.Callback;
const createCallback = dcl.callback;
const Closure = dcl.Closure;
const md = @import("../md.zig");
const Writer = @import("../CodegenWriter.zig");
const declare = @import("declare.zig");
const utils = @import("utils.zig");
const exp = @import("expr.zig");
const Expr = exp.Expr;
const ExprBuild = exp.ExprBuild;
const ExprComment = exp.ExprComment;
const _blk = exp._blk;
const _raw = exp._raw;

pub const If = struct {
    branches: []const Branch,

    pub fn deinit(self: If, allocator: Allocator) void {
        for (self.branches) |t| t.deinit(allocator);
        allocator.free(self.branches);
    }

    pub fn write(self: If, writer: *Writer, comptime format: []const u8) !void {
        assert(self.branches.len > 0);
        for (self.branches, 0..) |branch, i| {
            if (i == 0) {
                try writer.appendFmt("if ({}) ", .{branch.condition.?});
                try branch.writeBody(writer);
            } else {
                try writer.appendValue(branch);
            }
        }
        try utils.statementSemicolon(writer, format, self.branches[self.branches.len - 1].body);
    }

    pub fn build(
        allocator: Allocator,
        callback: anytype,
        ctx: anytype,
        condition: ExprBuild,
    ) Build(@TypeOf(callback)) {
        return .{
            .allocator = allocator,
            .callback = createCallback(ctx, callback),
            .condition = condition,
        };
    }

    pub fn Build(comptime Fn: type) type {
        const Callback = InferCallback(Fn);
        return struct {
            const Self = @This();
            const BranchBuild = Branch.Build(*const Self, Callback.Return);

            allocator: Allocator,
            callback: Callback,
            condition: ExprBuild,

            pub fn capture(self: *const Self, payload: []const u8) BranchBuild {
                const cb = createCallback(self, end);
                const partial = Branch.Partial.new(self.condition, payload, null);
                return BranchBuild.newPartial(self.allocator, cb, partial);
            }

            pub fn body(self: *const Self, expr: ExprBuild) BranchBuild {
                const cb = createCallback(self, end);
                const partial = Branch.Partial.new(self.condition, null, expr);
                return BranchBuild.newPartial(self.allocator, cb, partial);
            }

            fn end(self: *const Self, branches: anyerror![]const Branch) Callback.Return {
                return self.callback.invoke(.{
                    .branches = branches catch |err| return self.callback.fail(err),
                });
            }
        };
    }
};

test "If" {
    const Test = utils.TestVal(If);
    var tester = Test{ .expected = "if (foo) bar" };
    try If.build(test_alloc, Test.callback, &tester, _raw("foo"))
        .body(_raw("bar")).end();

    tester.expected =
        \\if (foo) |bar| baz
        \\// foo
        \\// bar
        \\else qux
    ;
    try If.build(test_alloc, Test.callback, &tester, _raw("foo"))
        .capture("bar").body(_raw("baz"))
        .comment("foo\nbar")
        .@"else"().body(_raw("qux")).end();

    tester.expected =
        \\if (foo) bar else if (baz) qux
        \\// # foo
        \\else quxx
    ;
    try If.build(test_alloc, Test.callback, &tester, _raw("foo"))
        .body(_raw("bar"))
        .elseIf(_raw("baz")).body(_raw("qux"))
        .commentMarkdown(struct {
        fn f(b: md.ContainerAuthor) !void {
            try b.heading(1, "foo");
        }
    }.f)
        .@"else"().body(_raw("quxx")).end();
}

test "If: statement" {
    const Test = utils.TestFmt(If, "{;}");
    var tester = Test{ .expected = "if (foo) bar else baz;" };
    try If.build(test_alloc, Test.callback, &tester, _raw("foo"))
        .body(_raw("bar")).@"else"().body(_raw("baz")).end();

    tester.expected = "if (foo) bar else {}";
    try If.build(test_alloc, Test.callback, &tester, _raw("foo"))
        .body(_raw("bar")).@"else"().body(_blk).end();
}

pub const For = struct {
    iterables: []const Iterable,
    branches: []const Branch,

    const Iterable = struct {
        expr: Expr,
        payload: []const u8,

        pub fn deinit(self: Iterable, allocator: Allocator) void {
            self.expr.deinit(allocator);
        }
    };

    pub fn deinit(self: For, allocator: Allocator) void {
        for (self.iterables) |t| t.expr.deinit(allocator);
        allocator.free(self.iterables);

        for (self.branches) |t| t.deinit(allocator);
        allocator.free(self.branches);
    }

    pub fn write(self: For, writer: *Writer, comptime format: []const u8) !void {
        assert(self.branches.len > 0);
        for (self.branches, 0..) |branch, i| {
            if (i == 0) {
                try writer.appendString("for (");
                try writer.appendList(Iterable, self.iterables, .{
                    .delimiter = ", ",
                    .field = "expr",
                });
                try writer.appendString(") |");
                try writer.appendList(Iterable, self.iterables, .{
                    .delimiter = ", ",
                    .field = "payload",
                    .format = "_",
                    .process = Writer.Processor.from(std.zig.fmtId),
                });
                try writer.appendFmt("| {}", .{branch.body});
            } else {
                try writer.appendValue(branch);
            }
        }
        try utils.statementSemicolon(writer, format, self.branches[self.branches.len - 1].body);
    }

    pub fn build(allocator: Allocator, callback: anytype, ctx: anytype) Build(@TypeOf(callback)) {
        return .{
            .allocator = allocator,
            .callback = createCallback(ctx, callback),
        };
    }

    const IterableBuild = struct {
        expr: ExprBuild,
        payload: []const u8,

        pub fn deinit(self: IterableBuild) void {
            self.expr.deinit();
        }

        pub fn consume(self: IterableBuild) !Iterable {
            return .{
                .expr = self.expr.consume() catch |err| return err,
                .payload = self.payload,
            };
        }
    };

    pub fn Build(comptime Fn: type) type {
        const Callback = InferCallback(Fn);
        return struct {
            const Self = @This();
            const BranchBuild = Branch.Build(*const Self, Callback.Return);

            allocator: Allocator,
            callback: Callback,
            iterables: StackChain(?IterableBuild) = .{},

            pub fn iter(self: *const Self, expr: ExprBuild, payload: []const u8) Self {
                var dupe = self.*;
                dupe.iterables = self.iterables.append(.{
                    .expr = expr,
                    .payload = payload,
                });
                return dupe;
            }

            pub fn body(self: *const Self, expr: ExprBuild) BranchBuild {
                const cb = createCallback(self, end);
                return BranchBuild.newAppend(self.allocator, cb, .{
                    .body = expr,
                });
            }

            fn end(self: *const Self, branches: anyerror![]const Branch) Callback.Return {
                const alloc_branch = branches catch |err| {
                    var it = self.iterables.iterateReversed();
                    while (it.next()) |t| t.deinit();
                    return self.callback.fail(err);
                };
                const iterables = utils.consumeChainAs(
                    self.allocator,
                    IterableBuild,
                    Iterable,
                    self.iterables,
                ) catch |err| {
                    for (alloc_branch) |t| t.deinit(self.allocator);
                    self.allocator.free(alloc_branch);
                    return self.callback.fail(err);
                };
                return self.callback.invoke(.{
                    .iterables = iterables,
                    .branches = alloc_branch,
                });
            }
        };
    }
};

test "For" {
    const Test = utils.TestVal(For);
    var tester = Test{ .expected = "for (foo) |bar| baz" };
    try For.build(test_alloc, Test.callback, &tester).iter(_raw("foo"), "bar")
        .body(_raw("baz")).end();

    tester.expected = "for (foo, bar) |baz, _| qux";
    try For.build(test_alloc, Test.callback, &tester)
        .iter(_raw("foo"), "baz").iter(_raw("bar"), "_")
        .body(_raw("qux")).end();

    tester.expected = "for (foo) |_| bar else baz";
    try For.build(test_alloc, Test.callback, &tester).iter(_raw("foo"), "_")
        .body(_raw("bar"))
        .@"else"().body(_raw("baz")).end();
}

test "For: statement" {
    const Test = utils.TestFmt(For, "{;}");
    var tester = Test{ .expected = "for (foo) |_| bar else baz;" };
    try For.build(test_alloc, Test.callback, &tester).iter(_raw("foo"), "_")
        .body(_raw("bar")).@"else"().body(_raw("baz")).end();

    tester.expected = "for (foo) |_| bar else {}";
    try For.build(test_alloc, Test.callback, &tester).iter(_raw("foo"), "_")
        .body(_raw("bar")).@"else"().body(_blk).end();
}

pub const While = struct {
    branches: []const Branch,
    continue_expr: ?Expr,

    pub fn deinit(self: While, allocator: Allocator) void {
        if (self.continue_expr) |cont| cont.deinit(allocator);
        for (self.branches) |t| t.deinit(allocator);
        allocator.free(self.branches);
    }

    pub fn write(self: While, writer: *Writer, comptime format: []const u8) !void {
        assert(self.branches.len > 0);
        for (self.branches, 0..) |branch, i| {
            if (i == 0) {
                try writer.appendFmt("while ({}) ", .{branch.condition.?});
                if (branch.payload) |p| {
                    try writer.appendFmt("|{_}| ", .{std.zig.fmtId(p)});
                }
                if (i == 0) if (self.continue_expr) |expr| {
                    try writer.appendFmt(": ({}) ", .{expr});
                };
                try writer.appendValue(branch.body);
            } else {
                try writer.appendValue(branch);
            }
        }
        try utils.statementSemicolon(writer, format, self.branches[self.branches.len - 1].body);
    }

    pub fn build(
        allocator: Allocator,
        callback: anytype,
        ctx: anytype,
        condition: ExprBuild,
    ) Build(@TypeOf(callback)) {
        return .{
            .allocator = allocator,
            .callback = createCallback(ctx, callback),
            .condition = condition,
        };
    }

    pub fn Build(comptime Fn: type) type {
        const Callback = InferCallback(Fn);
        return struct {
            const Self = @This();
            const BranchBuild = Branch.Build(*const Self, Callback.Return);

            allocator: Allocator,
            callback: Callback,
            condition: ExprBuild,
            payload: ?[]const u8 = null,
            continue_expr: ?ExprBuild = null,

            pub fn capture(self: Self, payload: []const u8) Self {
                assert(self.payload == null);
                var dupe = self;
                dupe.payload = payload;
                return dupe;
            }

            pub fn onContinue(self: Self, expr: ExprBuild) Self {
                var dupe = self;
                dupe.continue_expr = expr;
                return dupe;
            }

            pub fn body(self: *const Self, expr: ExprBuild) BranchBuild {
                const cb = createCallback(self, end);
                const partial = Branch.Partial.new(self.condition, self.payload, expr);
                return BranchBuild.newPartial(self.allocator, cb, partial);
            }

            fn end(self: *const Self, branches: anyerror![]const Branch) Callback.Return {
                const alloc_branch = branches catch |err| {
                    if (self.continue_expr) |c| c.deinit();
                    return self.callback.fail(err);
                };
                const alloc_continue = if (self.continue_expr) |c| c.consume() catch |err| {
                    for (alloc_branch) |t| t.deinit(self.allocator);
                    self.allocator.free(alloc_branch);
                    return self.callback.fail(err);
                } else null;
                return self.callback.invoke(.{
                    .branches = alloc_branch,
                    .continue_expr = alloc_continue,
                });
            }
        };
    }
};

test "While" {
    const Test = utils.TestVal(While);
    var tester = Test{ .expected = "while (foo) bar" };
    try While.build(test_alloc, Test.callback, &tester, _raw("foo"))
        .body(_raw("bar")).end();

    tester.expected = "while (foo) : (bar) baz";
    try While.build(test_alloc, Test.callback, &tester, _raw("foo"))
        .onContinue(_raw("bar")).body(_raw("baz")).end();

    tester.expected = "while (foo) |_| : (bar) baz else qux";
    try While.build(test_alloc, Test.callback, &tester, _raw("foo"))
        .capture("_").onContinue(_raw("bar")).body(_raw("baz"))
        .@"else"().body(_raw("qux")).end();
}

test "While: statement" {
    const Test = utils.TestFmt(While, "{;}");
    var tester = Test{ .expected = "while (foo) bar else baz;" };
    try While.build(test_alloc, Test.callback, &tester, _raw("foo"))
        .body(_raw("bar")).@"else"().body(_raw("baz")).end();

    tester.expected = "while (foo) bar else {}";
    try While.build(test_alloc, Test.callback, &tester, _raw("foo"))
        .body(_raw("bar")).@"else"().body(_blk).end();
}

pub const Branch = struct {
    comment: ?anyerror!ExprComment = null,
    condition: ?Expr = null,
    payload: ?[]const u8 = null,
    body: Expr,

    pub fn deinit(self: Branch, allocator: Allocator) void {
        if (self.comment) |comment| {
            if (comment) |t| t.deinit(allocator) else |_| {}
        }
        if (self.condition) |condition| condition.deinit(allocator);
        self.body.deinit(allocator);
    }

    pub fn write(self: Branch, writer: *Writer) !void {
        if (self.comment) |comment| {
            try writer.breakValue(comment catch |err| return err);

            if (self.condition) |condition| {
                try writer.breakFmt("else if ({}) ", .{condition});
            } else {
                try writer.breakString("else ");
            }
        } else if (self.condition) |condition| {
            try writer.appendFmt(" else if ({}) ", .{condition});
        } else {
            try writer.appendString(" else ");
        }

        try self.writeBody(writer);
    }

    fn writeBody(self: Branch, writer: *Writer) !void {
        if (self.payload) |p| try writer.appendFmt("|{_}| ", .{std.zig.fmtId(p)});
        try writer.appendValue(self.body);
    }

    const Partial = struct {
        comment: ?anyerror!ExprComment = null,
        condition: ?ExprBuild = null,
        payload: ?[]const u8 = null,
        body: ?ExprBuild = null,

        pub fn new(condition: ?ExprBuild, payload: ?[]const u8, body: ?ExprBuild) Partial {
            return .{
                .condition = condition,
                .payload = payload,
                .body = body,
            };
        }

        pub fn deinit(self: Partial) void {
            if (self.body) |t| t.deinit();
            if (self.condition) |t| t.deinit();
        }

        pub fn isEmpty(self: Partial) bool {
            return (self.condition orelse self.body) == null and self.payload == null;
        }

        pub fn consume(self: Partial) !Branch {
            const alloc_body = try self.body.?.consume();
            const alloc_cond = if (self.condition) |t| t.consume() catch |err| {
                alloc_body.deinit(self.body.?.allocator);
                return err;
            } else null;
            return .{
                .comment = self.comment,
                .condition = alloc_cond,
                .payload = self.payload,
                .body = alloc_body,
            };
        }
    };

    pub fn Build(comptime Context: type, comptime Return: type) type {
        const Callback = Cb(Context, anyerror![]const Branch, Return);
        return struct {
            const Self = @This();

            allocator: Allocator,
            callback: Callback,
            branches: StackChain(?Partial) = .{},
            partial: Partial = .{},

            pub fn newAppend(allocator: Allocator, callback: Callback, branch: Partial) Self {
                assert(branch.body != null);
                return .{
                    .allocator = allocator,
                    .callback = callback,
                    .branches = StackChain(?Partial).start(branch),
                };
            }

            pub fn newPartial(allocator: Allocator, callback: Callback, partial: Partial) Self {
                return .{
                    .allocator = allocator,
                    .callback = callback,
                    .partial = partial,
                };
            }

            pub fn capture(self: Self, payload: []const u8) Self {
                assert(self.partial.body == null);
                assert(self.partial.payload == null);
                var dupe = self;
                dupe.partial.payload = payload;
                return dupe;
            }

            pub fn body(self: Self, expr: ExprBuild) Self {
                assert(self.partial.body == null);
                var dupe = self;
                dupe.partial.body = expr;
                return dupe;
            }

            pub fn comment(self: *const Self, value: []const u8) Self {
                return self.flushAndReset(null, ExprComment{
                    .kind = .normal,
                    .source = .{ .plain = value },
                });
            }

            pub fn commentMarkdown(self: *const Self, closure: md.DocumentClosure) Self {
                return self.commentMarkdownWith({}, closure);
            }

            pub fn commentMarkdownWith(
                self: *const Self,
                ctx: anytype,
                closure: Closure(@TypeOf(ctx), md.DocumentClosure),
            ) Self {
                if (md.authorDocument(self.allocator, ctx, closure)) |data| {
                    return self.flushAndReset(null, ExprComment{
                        .kind = .normal,
                        .source = .{ .markdown = data },
                    });
                } else |err| {
                    return self.flushAndReset(null, err);
                }
            }

            pub fn elseIf(self: *const Self, condition: ExprBuild) Self {
                if (self.partial.comment == null) {
                    return self.flushAndReset(condition, null);
                } else {
                    var dupe = self.*;
                    dupe.partial.condition = condition;
                    return dupe;
                }
            }

            pub fn @"else"(self: *const Self) Self {
                if (self.partial.comment == null) {
                    return self.flushAndReset(null, null);
                } else {
                    return self.*;
                }
            }

            pub fn end(self: *const Self) Return {
                if (utils.consumeChainAs(
                    self.allocator,
                    Partial,
                    Branch,
                    self.flushPartial(),
                )) |branches| {
                    return self.callback.invoke(branches);
                } else |err| {
                    return self.callback.fail(err);
                }
            }

            fn flushAndReset(self: *const Self, condition: ?ExprBuild, comm: ?anyerror!ExprComment) Self {
                var dupe = self.*;
                dupe.branches = self.flushPartial();
                dupe.partial = .{ .condition = condition, .comment = comm };
                return dupe;
            }

            fn flushPartial(self: *const Self) StackChain(?Partial) {
                if (self.branches.isEmpty() or !self.partial.isEmpty()) {
                    assert(self.partial.body != null);
                    return self.branches.append(self.partial);
                } else {
                    return self.branches;
                }
            }
        };
    }
};

pub const SwitchClosure = *const fn (*Switch.Build) anyerror!void;
pub const Switch = struct {
    value: Expr,
    statements: []const Statement,

    pub fn deinit(self: Switch, allocator: Allocator) void {
        for (self.statements) |t| t.deinit(allocator);
        allocator.free(self.statements);
    }

    pub fn write(self: Switch, writer: *Writer) !void {
        if (self.statements.len == 0) {
            try writer.appendFmt("switch ({}) {{}}", .{self.value});
        } else {
            try writer.appendFmt("switch ({}) {{", .{self.value});
            try writer.breakList(Statement, self.statements, .{
                .line = .{ .indent = utils.INDENT_STR },
            });
            try writer.breakChar('}');
        }
    }

    pub fn build(allocator: Allocator, value: ExprBuild) Build {
        return .{
            .allocator = allocator,
            .value = value,
            .x = .{ .allocator = allocator },
        };
    }

    const Case = union(enum) {
        single: Expr,
        range: [2]Expr,

        pub fn deinit(self: Case, allocator: Allocator) void {
            switch (self) {
                .single => |t| t.deinit(allocator),
                .range => |r| for (r) |t| t.deinit(allocator),
            }
        }

        pub fn write(self: Case, writer: *Writer) !void {
            switch (self) {
                .single => |expr| try writer.appendValue(expr),
                .range => |range| try writer.appendFmt("{}...{}", .{ range[0], range[1] }),
            }
        }
    };

    const Statement = union(enum) {
        comment: ExprComment,
        prong: struct {
            is_inline: bool,
            cases: []const Case,
            payload: []const []const u8,
            body: Expr,
        },

        pub fn deinit(self: Statement, allocator: Allocator) void {
            switch (self) {
                .comment => |t| t.deinit(allocator),
                .prong => |p| {
                    for (p.cases) |t| t.deinit(allocator);
                    allocator.free(p.cases);
                    allocator.free(p.payload);
                    p.body.deinit(allocator);
                },
            }
        }

        pub fn write(self: Statement, writer: *Writer) !void {
            switch (self) {
                .prong => |prong| {
                    assert(prong.cases.len > 0);
                    if (prong.is_inline) try writer.appendString("inline ");
                    try writer.appendList(Case, prong.cases, .{
                        .delimiter = ", ",
                    });
                    try writer.appendString(" =>");
                    if (prong.payload.len > 0) {
                        try writer.appendString(" |");
                        try writer.appendList([]const u8, prong.payload, .{
                            .delimiter = ", ",
                            .format = "_",
                            .process = Writer.Processor.from(std.zig.fmtId),
                        });
                        try writer.appendChar('|');
                    }
                    try writer.appendFmt(" {},", .{prong.body});
                },
                .comment => |t| try writer.appendValue(t),
            }
        }
    };

    pub const Build = struct {
        allocator: Allocator,
        value: ExprBuild,
        statements: std.ArrayListUnmanaged(Statement) = .{},
        state: State = .idle,
        x: ExprBuild,

        const State = enum { idle, inlined, end_inlined, end };

        pub fn deinit(self: Build) void {
            self.value.deinit();
            for (self.statements.items) |t| t.deinit(self.allocator);
            var list = self.statements;
            list.deinit(self.allocator);
        }

        pub fn consume(self: *Build) !Switch {
            if (self.state == .inlined) {
                return error.IncompleteProng;
            } else {
                const statements = self.statements.toOwnedSlice(self.allocator) catch |err| {
                    self.value.deinit();
                    return err;
                };
                const value = self.value.consume() catch |err| {
                    for (statements) |t| t.deinit(self.allocator);
                    self.allocator.free(statements);
                    return err;
                };
                return .{ .value = value, .statements = statements };
            }
        }

        pub fn comment(self: *Build, value: []const u8) !void {
            assert(self.state == .idle or self.state == .inlined);
            try self.statements.append(self.allocator, .{ .comment = ExprComment{
                .kind = .normal,
                .source = .{ .plain = value },
            } });
        }

        pub fn commentMarkdown(self: *Build, closure: md.DocumentClosure) !void {
            try self.commentMarkdownWith({}, closure);
        }

        pub fn commentMarkdownWith(
            self: *Build,
            ctx: anytype,
            closure: Closure(@TypeOf(ctx), md.DocumentClosure),
        ) !void {
            assert(self.state == .idle or self.state == .inlined);
            var doc = try md.authorDocument(self.allocator, ctx, closure);
            errdefer doc.deinit(self.allocator);

            try self.statements.append(self.allocator, .{ .comment = ExprComment{
                .kind = .normal,
                .source = .{ .markdown = doc },
            } });
        }

        pub fn inlined(self: *Build) *Build {
            assert(self.state == .idle);
            self.state = .inlined;
            return self;
        }

        pub fn branch(self: *Build) ProngBuild {
            assert(self.state == .idle or self.state == .inlined);
            return .{ .parent = self };
        }

        pub fn @"else"(self: *Build) ProngBuild {
            self.state = switch (self.state) {
                .idle => .end,
                .inlined => .end_inlined,
                else => unreachable,
            };
            return .{
                .parent = self,
                .cases = StackChain(?CaseBuild).start(.{ .single = _raw("else") }),
                .allow_case = false,
            };
        }

        pub fn nonExhaustive(self: *Build) ProngBuild {
            self.state = switch (self.state) {
                .idle => .end,
                .inlined => .end_inlined,
                else => unreachable,
            };
            return .{
                .parent = self,
                .cases = StackChain(?CaseBuild).start(.{ .single = _raw("_") }),
                .allow_case = false,
            };
        }

        fn prongCallback(
            self: *Build,
            cases: StackChain(?CaseBuild),
            payload: StackChain(?[]const u8),
            body: ExprBuild,
        ) !void {
            const body_expr = body.consume() catch |err| {
                var it = cases.iterateReversed();
                while (it.next()) |t| t.deinit();
                return err;
            };
            errdefer body_expr.deinit(self.allocator);

            const alloc_payload = payload.unwrapAlloc(self.allocator) catch |err| {
                var it = cases.iterateReversed();
                while (it.next()) |t| t.deinit();
                return err;
            };
            errdefer self.allocator.free(alloc_payload);

            const alloc_cases = try utils.consumeChainAs(
                self.allocator,
                CaseBuild,
                Case,
                cases,
            );

            const is_inline = switch (self.state) {
                .idle, .end => false,
                .inlined => blk: {
                    self.state = .idle;
                    break :blk true;
                },
                .end_inlined => true,
            };

            try self.statements.append(self.allocator, .{
                .prong = .{
                    .is_inline = is_inline,
                    .cases = alloc_cases,
                    .payload = alloc_payload,
                    .body = body_expr,
                },
            });
        }
    };

    const CaseBuild = union(enum) {
        single: ExprBuild,
        range: [2]ExprBuild,

        pub fn deinit(self: CaseBuild) void {
            switch (self) {
                .single => |t| t.deinit(),
                .range => |r| for (r) |t| t.deinit(),
            }
        }

        pub fn consume(self: CaseBuild) !Case {
            switch (self) {
                .single => |c| return .{ .single = try c.consume() },
                .range => |c| {
                    const from = c[0].consume() catch |err| {
                        c[1].deinit();
                        return err;
                    };
                    const to = c[1].consume() catch |err| {
                        from.deinit(c[0].allocator);
                        return err;
                    };
                    return .{ .range = .{ from, to } };
                },
            }
        }
    };

    pub const ProngBuild = struct {
        parent: *Build,
        allow_case: bool = true,
        cases: StackChain(?CaseBuild) = .{},
        payload: StackChain(?[]const u8) = .{},

        pub fn case(self: *const ProngBuild, expr: ExprBuild) ProngBuild {
            assert(self.allow_case);
            var dupe = self.*;
            dupe.cases = self.cases.append(.{ .single = expr });
            return dupe;
        }

        pub fn caseRange(self: *const ProngBuild, from: ExprBuild, to: ExprBuild) ProngBuild {
            assert(self.allow_case);
            var dupe = self.*;
            dupe.cases = self.cases.append(.{ .range = .{ from, to } });
            return dupe;
        }

        pub fn capture(self: *const ProngBuild, payload: []const u8) ProngBuild {
            var dupe = self.*;
            dupe.payload = self.payload.append(payload);
            dupe.allow_case = false;
            return dupe;
        }

        pub fn body(self: ProngBuild, expr: ExprBuild) !void {
            if (self.cases.isEmpty()) {
                expr.deinit();
                return error.MissingCase;
            } else {
                try self.parent.prongCallback(self.cases, self.payload, expr);
            }
        }
    };
};

test "Switch" {
    var b = Switch.build(test_alloc, _raw("foo"));
    errdefer b.deinit();

    try b.branch().case(b.x.raw("bar")).case(b.x.raw("baz"))
        .capture("val").capture("tag").body(b.x.raw("qux"));
    try b.comment("foo\nbar");
    try b.branch().caseRange(b.x.raw("18"), b.x.raw("108"))
        .body(b.x.raw("unreachable"));
    try b.commentMarkdown(struct {
        fn f(m: md.ContainerAuthor) !void {
            try m.heading(1, "foo");
        }
    }.f);
    try b.inlined().@"else"().body(b.x.raw("unreachable"));

    const data = try b.consume();
    defer data.deinit(test_alloc);
    try Writer.expectValue(
        \\switch (foo) {
        \\    bar, baz => |val, tag| qux,
        \\    // foo
        \\    // bar
        \\    18...108 => unreachable,
        \\    // # foo
        \\    inline else => unreachable,
        \\}
    , data);
}

pub const Call = struct {
    name: []const u8,
    args: []const Expr,

    pub fn init(allocator: Allocator, name: []const u8, args: []const ExprBuild) !Call {
        return .{
            .name = name,
            .args = try utils.consumeExprBuildList(allocator, args),
        };
    }

    pub fn deinit(self: Call, allocator: Allocator) void {
        for (self.args) |t| t.deinit(allocator);
        allocator.free(self.args);
    }

    pub fn write(self: Call, writer: *Writer) !void {
        if (self.args.len == 0) {
            try writer.appendFmt("{s}()", .{self.name});
        } else {
            try writer.appendFmt("{s}(", .{self.name});
            try writer.appendList(Expr, self.args, .{
                .delimiter = ", ",
            });
            try writer.appendChar(')');
        }
    }
};

test "Call" {
    var b = try Call.init(test_alloc, "foo", &.{ _raw("bar"), _raw("baz") });
    defer b.deinit(test_alloc);
    try Writer.expectValue("foo(bar, baz)", b);
}

pub const TokenReflow = struct {
    token: std.zig.Token.Tag,
    label: ?[]const u8,

    pub fn write(self: TokenReflow, writer: *Writer, comptime format: []const u8) !void {
        const keyword = self.token.lexeme().?;
        const suffix: u8 = if (utils.isStatement(format)) ';' else ' ';
        if (self.label) |t| {
            try writer.appendFmt("{s} :{_}{c}", .{ keyword, std.zig.fmtId(t), suffix });
        } else {
            try writer.appendFmt("{s}{c}", .{ keyword, suffix });
        }
    }
};

test "TokenReflow" {
    var expr = TokenReflow{ .token = .keyword_return, .label = null };
    try Writer.expectValue("return ", expr);
    try Writer.expectFmt("return;", "{;}", .{expr});

    expr = TokenReflow{ .token = .keyword_break, .label = "foo" };
    try Writer.expectValue("break :foo ", expr);

    expr = TokenReflow{ .token = .keyword_break, .label = "test" };
    try Writer.expectValue("break :@\"test\" ", expr);
}
