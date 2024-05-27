const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const StackChain = @import("../../utils/declarative.zig").StackChain;
const Writer = @import("../CodegenWriter.zig");
const Expr = @import("Expr.zig");
const scope = @import("scope.zig");

pub const If = struct {
    branches: StackChain(ElseBranch),

    pub fn __write(self: If, writer: *Writer) !void {
        var branch_buff: [16]ElseBranch = undefined;
        const branches = try self.branches.unwrap(&branch_buff);

        for (branches, 0..) |branch, i| {
            if (i == 0) {
                try writer.appendFmt("if ({}) ", .{branch.condition.?});
                try branch.writeBody(writer);
            } else {
                try writer.appendValue(branch);
            }
        }
    }

    pub const Build = struct {
        delegate: scope.Delegate(If),
        condition: Expr,

        pub fn new(delegate: scope.Delegate(If), condition: Expr) Build {
            return .{
                .delegate = delegate,
                .condition = condition,
            };
        }

        pub fn capture(self: *const Build, payload: []const u8) ElseBranch.Build {
            return ElseBranch.Build.newPartial(self, callback, self.condition, payload, null);
        }

        pub fn body(self: *const Build, expr: Expr) ElseBranch.Build {
            return ElseBranch.Build.newPartial(self, callback, self.condition, null, expr);
        }

        fn callback(ctx: *const anyopaque, branches: StackChain(ElseBranch)) !void {
            const self: *const Build = @alignCast(@ptrCast(ctx));
            try self.delegate.end(&.{ .branches = branches });
        }
    };
};

test "If" {
    var tester = scope.Delegate(If).WriteTester{
        .expected = "if (foo) bar",
    };
    try If.Build.new(tester.dlg(), Expr.raw("foo"))
        .body(Expr.raw("bar"))
        .end();

    tester.expected = "if (foo) |bar| baz else qux";
    try If.Build.new(tester.dlg(), Expr.raw("foo"))
        .capture("bar").body(Expr.raw("baz"))
        .@"else"().body(Expr.raw("qux"))
        .end();

    tester.expected = "if (foo) bar else if (baz) qux else quxx";
    try If.Build.new(tester.dlg(), Expr.raw("foo"))
        .body(Expr.raw("bar"))
        .elseIf(Expr.raw("baz")).body(Expr.raw("qux"))
        .@"else"().body(Expr.raw("quxx"))
        .end();
}

pub const For = struct {
    iterables: StackChain(?Iterable),
    branches: StackChain(ElseBranch),

    const Iterable = struct {
        expr: Expr,
        payload: []const u8,
    };

    pub fn __write(self: For, writer: *Writer) !void {
        var branch_buff: [4]ElseBranch = undefined;
        const branches = try self.branches.unwrap(&branch_buff);

        for (branches, 0..) |branch, i| {
            if (i == 0) {
                var iter_buff: [8]Iterable = undefined;
                const iterables = try self.iterables.unwrap(&iter_buff);

                try writer.appendString("for (");
                try writer.appendList(Iterable, iterables, .{
                    .delimiter = ", ",
                    .field = "expr",
                });
                try writer.appendString(") |");
                try writer.appendList(Iterable, iterables, .{
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

    pub const Build = struct {
        delegate: scope.Delegate(For),
        iterables: StackChain(?Iterable) = .{},

        pub fn new(delegate: scope.Delegate(For)) Build {
            return .{ .delegate = delegate };
        }

        pub fn iter(self: *const Build, expr: Expr, payload: []const u8) Build {
            var dupe = self.*;
            dupe.iterables = self.iterables.append(.{
                .expr = expr,
                .payload = payload,
            });
            return dupe;
        }

        pub fn body(self: *const Build, expr: Expr) ElseBranch.Build {
            return ElseBranch.Build.newAppend(self, callback, null, null, expr);
        }

        fn callback(ctx: *const anyopaque, branches: StackChain(ElseBranch)) !void {
            const self: *const Build = @alignCast(@ptrCast(ctx));
            try self.delegate.end(&.{
                .iterables = self.iterables,
                .branches = branches,
            });
        }
    };
};

test "For" {
    var tester = scope.Delegate(For).WriteTester{
        .expected = "for (foo) |bar| baz",
    };
    try For.Build.new(tester.dlg()).iter(Expr.raw("foo"), "bar")
        .body(Expr.raw("baz"))
        .end();

    tester.expected = "for (foo, bar) |baz, _| qux";
    try For.Build.new(tester.dlg())
        .iter(Expr.raw("foo"), "baz").iter(Expr.raw("bar"), "_")
        .body(Expr.raw("qux"))
        .end();

    tester.expected = "for (foo) |_| bar else baz";
    try For.Build.new(tester.dlg()).iter(Expr.raw("foo"), "_")
        .body(Expr.raw("bar"))
        .@"else"().body(Expr.raw("baz"))
        .end();
}

pub const While = struct {
    branches: StackChain(ElseBranch),
    continue_expr: ?Expr,

    pub fn __write(self: While, writer: *Writer) !void {
        var branch_buff: [4]ElseBranch = undefined;
        const branches = try self.branches.unwrap(&branch_buff);

        for (branches, 0..) |branch, i| {
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

    pub const Build = struct {
        delegate: scope.Delegate(While),
        condition: Expr,
        payload: ?[]const u8 = null,
        continue_expr: ?Expr = null,

        pub fn new(delegate: scope.Delegate(While), condition: Expr) Build {
            return .{
                .delegate = delegate,
                .condition = condition,
            };
        }

        pub fn capture(self: Build, payload: []const u8) Build {
            assert(self.payload == null);
            var dupe = self;
            dupe.payload = payload;
            return dupe;
        }

        pub fn onContinue(self: Build, expr: Expr) Build {
            var dupe = self;
            dupe.continue_expr = expr;
            return dupe;
        }

        pub fn body(self: *const Build, expr: Expr) ElseBranch.Build {
            return ElseBranch.Build.newAppend(self, callback, self.condition, self.payload, expr);
        }

        fn callback(ctx: *const anyopaque, branches: StackChain(ElseBranch)) !void {
            const self: *const Build = @alignCast(@ptrCast(ctx));
            try self.delegate.end(&.{
                .branches = branches,
                .continue_expr = self.continue_expr,
            });
        }
    };
};

test "While" {
    var tester = scope.Delegate(While).WriteTester{
        .expected = "while (foo) bar",
    };
    try While.Build.new(tester.dlg(), Expr.raw("foo"))
        .body(Expr.raw("bar"))
        .end();

    tester.expected = "while (foo) : (bar) baz";
    try While.Build.new(tester.dlg(), Expr.raw("foo"))
        .onContinue(Expr.raw("bar")).body(Expr.raw("baz"))
        .end();

    tester.expected = "while (foo) |_| : (bar) baz else qux";
    try While.Build.new(tester.dlg(), Expr.raw("foo"))
        .capture("_").onContinue(Expr.raw("bar")).body(Expr.raw("baz"))
        .@"else"().body(Expr.raw("qux"))
        .end();
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

    pub const Build = struct {
        ctx: *const anyopaque,
        callback: Callback,
        has_branches: bool,
        branches: StackChain(ElseBranch),
        condition: ?Expr = null,
        payload: ?[]const u8 = null,
        expr: ?Expr = null,

        pub const Callback = *const fn (*const anyopaque, StackChain(ElseBranch)) anyerror!void;

        pub fn newAppend(
            ctx: *const anyopaque,
            callback: Callback,
            condition: ?Expr,
            payload: ?[]const u8,
            expr: Expr,
        ) Build {
            return .{
                .ctx = ctx,
                .callback = callback,
                .branches = StackChain(ElseBranch).start(.{
                    .condition = condition,
                    .payload = payload,
                    .body = expr,
                }),
                .has_branches = true,
            };
        }

        pub fn newPartial(
            ctx: *const anyopaque,
            callback: Callback,
            condition: ?Expr,
            payload: ?[]const u8,
            expr: ?Expr,
        ) Build {
            return .{
                .ctx = ctx,
                .callback = callback,
                .branches = undefined,
                .has_branches = false,
                .condition = condition,
                .payload = payload,
                .expr = expr,
            };
        }

        pub fn capture(self: Build, payload: []const u8) Build {
            assert(self.expr == null);
            assert(self.payload == null);
            var dupe = self;
            dupe.payload = payload;
            return dupe;
        }

        pub fn body(self: Build, expr: Expr) Build {
            assert(self.expr == null);
            var dupe = self;
            dupe.expr = expr;
            return dupe;
        }

        pub fn elseIf(self: *const Build, condition: Expr) Build {
            return self.flushAndReset(condition);
        }

        pub fn @"else"(self: *const Build) Build {
            return self.flushAndReset(null);
        }

        pub fn end(self: *const Build) !void {
            const has_parts = self.hasParts();
            if ((has_parts and self.expr == null) or !(self.has_branches or has_parts)) {
                return error.MissingBody;
            } else {
                try self.callback(self.ctx, self.getChain(has_parts));
            }
        }

        fn hasParts(self: *const Build) bool {
            return self.expr != null or self.condition != null or self.payload != null;
        }

        fn flushAndReset(self: *const Build, conditing: ?Expr) Build {
            var dupe = self.*;

            // Flush
            dupe.branches = self.getChain(!self.has_branches or self.hasParts());
            dupe.has_branches = true;

            // Reset
            dupe.condition = conditing;
            dupe.payload = null;
            dupe.expr = null;

            return dupe;
        }

        fn getChain(self: *const Build, flush: bool) StackChain(ElseBranch) {
            if (flush) {
                const branch = ElseBranch{
                    .condition = self.condition,
                    .payload = self.payload,
                    .body = self.expr.?,
                };
                return if (self.has_branches) self.branches.append(branch) else StackChain(ElseBranch).start(branch);
            } else {
                return self.branches;
            }
        }
    };
};

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
                .line = .{ .indent = scope.ZIG_INDENT },
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
                .cases = StackChain(?Case).start(.{ .single = Expr.raw("else") }),
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
                .cases = StackChain(?Case).start(.{ .single = Expr.raw("_") }),
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
    var build = Switch.Build.init(test_alloc, Expr.raw("foo"));
    errdefer build.deinit();

    try build.branch().case(Expr.raw("bar")).case(Expr.raw("baz"))
        .capture("val").capture("tag")
        .body(Expr.raw("qux"));
    try build.branch()
        .caseRange(Expr.raw("18"), Expr.raw("108"))
        .body(Expr.raw("unreachable"));
    try build.inlined().@"else"().body(Expr.raw("unreachable"));

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

pub const ErrDefer = struct {
    payload: ?[]const u8 = null,
    body: Expr,

    pub fn __write(self: ErrDefer, writer: *Writer) !void {
        try writer.appendString("errdefer ");
        if (self.payload) |p| try writer.appendFmt("|{_}| ", .{std.zig.fmtId(p)});
        try writer.appendValue(self.body);
    }

    pub const Build = struct {
        delegate: scope.Delegate(ErrDefer),
        payload: ?[]const u8 = null,

        pub fn new(delegate: scope.Delegate(ErrDefer)) Build {
            return .{ .delegate = delegate };
        }

        pub fn capture(self: Build, payload: []const u8) Build {
            assert(self.payload == null);
            var dupe = self;
            dupe.payload = payload;
            return dupe;
        }

        pub fn body(self: Build, expr: Expr) !void {
            try self.delegate.end(&.{
                .payload = self.payload,
                .body = expr,
            });
        }
    };
};

test "ErrDefer" {
    var tester = scope.Delegate(ErrDefer).WriteTester{
        .expected = "errdefer |foo| bar",
    };
    try ErrDefer.Build.new(tester.dlg()).capture("foo").body(Expr.raw("bar"));
}
