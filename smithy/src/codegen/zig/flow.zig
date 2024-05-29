const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const decl = @import("../../utils/declarative.zig");
const StackChain = decl.StackChain;
const Writer = @import("../CodegenWriter.zig");
const Block = @import("Block.zig");
const Expr = @import("expr.zig").Expr;
const x = Expr.new;

pub const If = struct {
    branches: []const ElseBranch,

    pub fn deinit(self: If, allocator: Allocator) void {
        allocator.free(self.branches);
    }

    pub fn __write(self: If, writer: *Writer) !void {
        for (self.branches, 0..) |branch, i| {
            if (i == 0) {
                try writer.appendFmt("if ({}) ", .{branch.condition.?});
                try branch.writeBody(writer);
            } else {
                try writer.appendValue(branch);
            }
        }
    }

    pub fn build(allocator: Allocator, callback: anytype, ctx: anytype, condition: Expr) Build(@TypeOf(callback)) {
        return .{
            .allocator = allocator,
            .callback = decl.callback(ctx, callback),
            .condition = condition,
        };
    }

    pub fn Build(comptime Fn: type) type {
        const Callback = decl.InferCallback(Fn);
        return struct {
            const Self = @This();
            const BranchBuild = ElseBranch.Build(*const Self, Callback.Return);

            allocator: Allocator,
            callback: Callback,
            condition: Expr,

            pub fn capture(self: *const Self, payload: []const u8) BranchBuild {
                const cb = decl.callback(self, end);
                return BranchBuild.newPartial(cb, self.condition, payload, null);
            }

            pub fn body(self: *const Self, expr: Expr) BranchBuild {
                const cb = decl.callback(self, end);
                return BranchBuild.newPartial(cb, self.condition, null, expr);
            }

            fn end(self: *const Self, branches: StackChain(?ElseBranch)) Callback.Return {
                return self.callback.invoke(.{
                    .branches = branches.unwrapAlloc(self.allocator) catch |err| {
                        return self.callback.fail(err);
                    },
                });
            }
        };
    }
};

test "If" {
    const Test = Tester(If, true);
    var tester = Test{ .expected = "if (foo) bar" };
    try If.build(test_alloc, Test.callback, &tester, x._raw("foo"))
        .body(x._raw("bar")).end();

    tester.expected = "if (foo) |bar| baz else qux";
    try If.build(test_alloc, Test.callback, &tester, x._raw("foo"))
        .capture("bar").body(x._raw("baz"))
        .@"else"().body(x._raw("qux")).end();

    tester.expected = "if (foo) bar else if (baz) qux else quxx";
    try If.build(test_alloc, Test.callback, &tester, x._raw("foo"))
        .body(x._raw("bar"))
        .elseIf(x._raw("baz")).body(x._raw("qux"))
        .@"else"().body(x._raw("quxx")).end();
}

pub const For = struct {
    iterables: []const Iterable,
    branches: []const ElseBranch,

    const Iterable = struct {
        expr: Expr,
        payload: []const u8,
    };

    pub fn deinit(self: For, allocator: Allocator) void {
        allocator.free(self.iterables);
        allocator.free(self.branches);
    }

    pub fn __write(self: For, writer: *Writer) !void {
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
    }

    pub fn build(allocator: Allocator, callback: anytype, ctx: anytype) Build(@TypeOf(callback)) {
        return .{
            .allocator = allocator,
            .callback = decl.callback(ctx, callback),
        };
    }

    pub fn Build(comptime Fn: type) type {
        const Callback = decl.InferCallback(Fn);
        return struct {
            const Self = @This();
            const BranchBuild = ElseBranch.Build(*const Self, Callback.Return);

            allocator: Allocator,
            callback: Callback,
            iterables: StackChain(?Iterable) = .{},

            pub fn iter(self: *const Self, expr: Expr, payload: []const u8) Self {
                var dupe = self.*;
                dupe.iterables = self.iterables.append(.{
                    .expr = expr,
                    .payload = payload,
                });
                return dupe;
            }

            pub fn body(self: *const Self, expr: Expr) BranchBuild {
                const cb = decl.callback(self, end);
                return BranchBuild.newAppend(cb, null, null, expr);
            }

            fn end(self: *const Self, branches: StackChain(?ElseBranch)) Callback.Return {
                const iterables = self.iterables.unwrapAlloc(self.allocator) catch |err| {
                    return self.callback.fail(err);
                };
                return self.callback.invoke(.{
                    .iterables = iterables,
                    .branches = branches.unwrapAlloc(self.allocator) catch |err| {
                        self.allocator.free(iterables);
                        return self.callback.fail(err);
                    },
                });
            }
        };
    }
};

test "For" {
    const Test = Tester(For, true);
    var tester = Test{ .expected = "for (foo) |bar| baz" };
    try For.build(test_alloc, Test.callback, &tester).iter(x._raw("foo"), "bar")
        .body(x._raw("baz")).end();

    tester.expected = "for (foo, bar) |baz, _| qux";
    try For.build(test_alloc, Test.callback, &tester)
        .iter(x._raw("foo"), "baz").iter(x._raw("bar"), "_")
        .body(x._raw("qux")).end();

    tester.expected = "for (foo) |_| bar else baz";
    try For.build(test_alloc, Test.callback, &tester).iter(x._raw("foo"), "_")
        .body(x._raw("bar"))
        .@"else"().body(x._raw("baz")).end();
}

pub const While = struct {
    branches: []const ElseBranch,
    continue_expr: ?Expr,

    pub fn deinit(self: While, allocator: Allocator) void {
        allocator.free(self.branches);
    }

    pub fn __write(self: While, writer: *Writer) !void {
        for (self.branches, 0..) |branch, i| {
            if (i == 0) {
                try writer.appendFmt("while ({}) ", .{branch.condition.?});
                if (branch.payload) |p| try writer.appendFmt("|{_}| ", .{std.zig.fmtId(p)});
                if (i == 0) if (self.continue_expr) |expr| try writer.appendFmt(": ({}) ", .{expr});
                try writer.appendValue(branch.body);
            } else {
                try writer.appendValue(branch);
            }
        }
    }

    pub fn build(allocator: Allocator, callback: anytype, ctx: anytype, condition: Expr) Build(@TypeOf(callback)) {
        return .{
            .allocator = allocator,
            .callback = decl.callback(ctx, callback),
            .condition = condition,
        };
    }

    pub fn Build(comptime Fn: type) type {
        const Callback = decl.InferCallback(Fn);
        return struct {
            const Self = @This();
            const BranchBuild = ElseBranch.Build(*const Self, Callback.Return);

            allocator: Allocator,
            callback: Callback,
            condition: Expr,
            payload: ?[]const u8 = null,
            continue_expr: ?Expr = null,

            pub fn capture(self: Self, payload: []const u8) Self {
                assert(self.payload == null);
                var dupe = self;
                dupe.payload = payload;
                return dupe;
            }

            pub fn onContinue(self: Self, expr: Expr) Self {
                var dupe = self;
                dupe.continue_expr = expr;
                return dupe;
            }

            pub fn body(self: *const Self, expr: Expr) BranchBuild {
                const cb = decl.callback(self, end);
                return BranchBuild.newPartial(cb, self.condition, self.payload, expr);
            }

            fn end(self: *const Self, branches: StackChain(?ElseBranch)) Callback.Return {
                return self.callback.invoke(.{
                    .continue_expr = self.continue_expr,
                    .branches = branches.unwrapAlloc(self.allocator) catch |err| {
                        return self.callback.fail(err);
                    },
                });
            }
        };
    }
};

test "While" {
    const Test = Tester(While, true);
    var tester = Test{ .expected = "while (foo) bar" };
    try While.build(test_alloc, Test.callback, &tester, x._raw("foo"))
        .body(x._raw("bar")).end();

    tester.expected = "while (foo) : (bar) baz";
    try While.build(test_alloc, Test.callback, &tester, x._raw("foo"))
        .onContinue(x._raw("bar"))
        .body(x._raw("baz")).end();

    tester.expected = "while (foo) |_| : (bar) baz else qux";
    try While.build(test_alloc, Test.callback, &tester, x._raw("foo"))
        .capture("_").onContinue(x._raw("bar")).body(x._raw("baz"))
        .@"else"().body(x._raw("qux")).end();
}

pub const ElseBranch = struct {
    condition: ?Expr = null,
    payload: ?[]const u8 = null,
    body: Expr,

    pub fn __write(self: ElseBranch, writer: *Writer) !void {
        if (self.condition) |condition| {
            try writer.appendFmt(" else if ({}) ", .{condition});
        } else {
            try writer.appendString(" else ");
        }
        try self.writeBody(writer);
    }

    fn writeBody(self: ElseBranch, writer: *Writer) !void {
        if (self.payload) |p| try writer.appendFmt("|{_}| ", .{std.zig.fmtId(p)});
        try writer.appendValue(self.body);
    }

    pub fn Build(comptime Context: type, comptime Return: type) type {
        const Callback = decl.Callback(Context, StackChain(?ElseBranch), Return);
        return struct {
            const Self = @This();

            callback: Callback,
            branches: StackChain(?ElseBranch) = .{},
            condition: ?Expr = null,
            payload: ?[]const u8 = null,
            expr: ?Expr = null,

            pub fn newAppend(callback: Callback, condition: ?Expr, payload: ?[]const u8, expr: Expr) Self {
                return .{
                    .callback = callback,
                    .branches = StackChain(?ElseBranch).start(.{
                        .condition = condition,
                        .payload = payload,
                        .body = expr,
                    }),
                };
            }

            pub fn newPartial(callback: Callback, condition: ?Expr, payload: ?[]const u8, expr: ?Expr) Self {
                return .{
                    .callback = callback,
                    .condition = condition,
                    .payload = payload,
                    .expr = expr,
                };
            }

            pub fn capture(self: Self, payload: []const u8) Self {
                assert(self.expr == null);
                assert(self.payload == null);
                var dupe = self;
                dupe.payload = payload;
                return dupe;
            }

            pub fn body(self: Self, expr: Expr) Self {
                assert(self.expr == null);
                var dupe = self;
                dupe.expr = expr;
                return dupe;
            }

            pub fn elseIf(self: *const Self, condition: Expr) Self {
                return self.flushAndReset(condition);
            }

            pub fn @"else"(self: *const Self) Self {
                return self.flushAndReset(null);
            }

            pub fn end(self: *const Self) Return {
                return self.callback.invoke(self.flushChain());
            }

            fn flushAndReset(self: *const Self, conditing: ?Expr) Self {
                var dupe = self.*;
                dupe.branches = self.flushChain();
                dupe.condition = conditing;
                dupe.payload = null;
                dupe.expr = null;
                return dupe;
            }

            fn flushChain(self: *const Self) StackChain(?ElseBranch) {
                const has_parts = self.hasParts();
                if (self.branches.isEmpty() or has_parts) {
                    const branch = ElseBranch{
                        .condition = self.condition,
                        .payload = self.payload,
                        .body = self.expr.?,
                    };
                    return self.branches.append(branch);
                } else {
                    return self.branches;
                }
            }

            fn hasParts(self: *const Self) bool {
                return self.expr != null or self.condition != null or self.payload != null;
            }
        };
    }
};

pub const SwitchFn = *const fn (*Switch.Build) anyerror!void;

pub const Switch = struct {
    value: Expr,
    statements: []const Statement,

    pub fn deinit(self: Switch, allocator: Allocator) void {
        allocator.free(self.statements);
    }

    pub fn __write(self: Switch, writer: *Writer) !void {
        if (self.statements.len == 0) {
            try writer.appendFmt("switch ({}) {{}}", .{self.value});
        } else {
            try writer.appendFmt("switch ({}) {{", .{self.value});
            try writer.breakList(Statement, self.statements, .{
                .line = .{ .indent = Block.ZIG_INDENT },
            });
            try writer.breakChar('}');
        }
    }

    const Case = union(enum) {
        single: Expr,
        range: [2]Expr,

        pub fn __write(self: Case, writer: *Writer) !void {
            switch (self) {
                .single => |expr| try writer.appendValue(expr),
                .range => |range| try writer.appendFmt("{}...{}", .{ range[0], range[1] }),
            }
        }
    };

    const Statement = union(enum) {
        prong: struct {
            is_inline: bool,
            cases: StackChain(?Case),
            payload: StackChain(?[]const u8),
            body: Expr,
        },

        pub fn __write(self: Statement, writer: *Writer) !void {
            switch (self) {
                .prong => |prong| {
                    var buffer: [32]Case = undefined;
                    const cases = try prong.cases.unwrap(&buffer);

                    if (prong.is_inline) try writer.appendString("inline ");
                    try writer.appendList(Case, cases, .{ .delimiter = ", " });
                    try writer.appendString(" =>");
                    if (!prong.payload.isEmpty()) {
                        var buff_capture: [2][]const u8 = undefined;
                        const captures = try prong.payload.unwrap(&buff_capture);

                        try writer.appendString(" |");
                        try writer.appendList([]const u8, captures, .{
                            .delimiter = ", ",
                            .format = "_",
                            .process = Writer.Processor.from(std.zig.fmtId),
                        });
                        try writer.appendChar('|');
                    }
                    try writer.appendFmt(" {},", .{prong.body});
                },
            }
        }
    };

    pub const Build = struct {
        value: Expr,
        statements: std.ArrayList(Statement),
        state: State = .idle,

        const State = enum { idle, inlined, end_inlined, end };

        pub fn init(allocator: Allocator, value: Expr) Build {
            return .{
                .value = value,
                .statements = std.ArrayList(Statement).init(allocator),
            };
        }

        pub fn deinit(self: Build) void {
            self.statements.deinit();
        }

        pub fn consume(self: *Build) !Switch {
            if (self.state == .inlined) {
                return error.IncompleteProng;
            } else {
                return .{
                    .value = self.value,
                    .statements = try self.statements.toOwnedSlice(),
                };
            }
        }

        pub fn inlined(self: *Build) *Build {
            assert(self.state == .idle);
            self.state = .inlined;
            return self;
        }

        pub fn branch(self: *Build) BuildProng {
            assert(self.state == .idle or self.state == .inlined);
            return .{ .parent = self };
        }

        pub fn @"else"(self: *Build) BuildProng {
            self.state = switch (self.state) {
                .idle => .end,
                .inlined => .end_inlined,
                else => unreachable,
            };
            return .{
                .parent = self,
                .cases = StackChain(?Case).start(.{ .single = x._raw("else") }),
                .allow_case = false,
            };
        }

        pub fn nonExhaustive(self: *Build) BuildProng {
            self.state = switch (self.state) {
                .idle => .end,
                .inlined => .end_inlined,
                else => unreachable,
            };
            return .{
                .parent = self,
                .cases = StackChain(?Case).start(.{ .single = x._raw("_") }),
                .allow_case = false,
            };
        }

        fn prongCallback(
            self: *Build,
            cases: StackChain(?Case),
            payload: StackChain(?[]const u8),
            body: Expr,
        ) !void {
            try self.statements.append(.{
                .prong = .{
                    .is_inline = switch (self.state) {
                        .idle => false,
                        .inlined => blk: {
                            self.state = .idle;
                            break :blk true;
                        },
                        .end_inlined => true,
                        else => unreachable,
                    },
                    .cases = cases,
                    .payload = payload,
                    .body = body,
                },
            });
        }
    };

    pub const BuildProng = struct {
        parent: *Build,
        allow_case: bool = true,
        cases: StackChain(?Case) = .{},
        payload: StackChain(?[]const u8) = .{},

        pub fn case(self: *const BuildProng, expr: Expr) BuildProng {
            assert(self.allow_case);
            var dupe = self.*;
            dupe.cases = self.cases.append(.{ .single = expr });
            return dupe;
        }

        pub fn caseRange(self: *const BuildProng, from: Expr, to: Expr) BuildProng {
            assert(self.allow_case);
            var dupe = self.*;
            dupe.cases = self.cases.append(.{ .range = .{ from, to } });
            return dupe;
        }

        pub fn capture(self: *const BuildProng, payload: []const u8) BuildProng {
            var dupe = self.*;
            dupe.payload = self.payload.append(payload);
            dupe.allow_case = false;
            return dupe;
        }

        pub fn body(self: BuildProng, expr: Expr) !void {
            if (self.cases.isEmpty()) {
                return error.MissingCase;
            } else {
                try self.parent.prongCallback(self.cases, self.payload, expr);
            }
        }
    };
};

test "Switch" {
    var build = Switch.Build.init(test_alloc, x._raw("foo"));
    errdefer build.deinit();

    try build.branch().case(x._raw("bar")).case(x._raw("baz"))
        .capture("val").capture("tag").body(x._raw("qux"));
    try build.branch().caseRange(x._raw("18"), x._raw("108"))
        .body(x._raw("unreachable"));
    try build.inlined().@"else"().body(x._raw("unreachable"));

    const data = try build.consume();
    defer data.deinit(test_alloc);
    try Writer.expect(
        \\switch (foo) {
        \\    bar, baz => |val, tag| qux,
        \\    18...108 => unreachable,
        \\    inline else => unreachable,
        \\}
    , data);
}

pub const Defer = struct {
    body: Expr,

    pub fn __write(self: Defer, writer: *Writer) !void {
        try writer.appendFmt("defer {}", .{self.body});
    }
};

test "Defer" {
    try Writer.expect("defer foo", Defer{ .body = x._raw("foo") });
}

pub const ErrorDefer = struct {
    payload: ?[]const u8 = null,
    body: Expr,

    pub fn __write(self: ErrorDefer, writer: *Writer) !void {
        try writer.appendString("errdefer ");
        if (self.payload) |p| try writer.appendFmt("|{_}| ", .{std.zig.fmtId(p)});
        try writer.appendValue(self.body);
    }

    pub fn build(callback: anytype, ctx: anytype) Build(@TypeOf(callback)) {
        return .{ .callback = decl.callback(ctx, callback) };
    }

    pub fn Build(comptime Fn: type) type {
        const Callback = decl.InferCallback(Fn);
        return struct {
            const Self = @This();

            callback: Callback,
            payload: ?[]const u8 = null,

            pub fn capture(self: Self, payload: []const u8) Self {
                assert(self.payload == null);
                var dupe = self;
                dupe.payload = payload;
                return dupe;
            }

            pub fn body(self: Self, expr: Expr) Callback.Return {
                return self.callback.invoke(.{
                    .payload = self.payload,
                    .body = expr,
                });
            }
        };
    }
};

test "ErrorDefer" {
    const Test = Tester(ErrorDefer, false);
    var tester = Test{
        .expected = "errdefer |foo| bar",
    };
    try ErrorDefer.build(Test.callback, &tester).capture("foo").body(x._raw("bar"));
}

pub fn Tester(comptime T: type, deinit: bool) type {
    return struct {
        expected: []const u8 = "",

        pub fn callback(self: *@This(), value: T) !void {
            defer if (deinit) value.deinit(test_alloc);
            try Writer.expect(self.expected, value);
        }
    };
}
