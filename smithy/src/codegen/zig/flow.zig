const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const StackChain = @import("../../utils/declarative.zig").StackChain;
const CodegenWriter = @import("../CodegenWriter.zig");
const Expr = @import("Expr.zig");

const ConditionBranch = struct {
    condition: ?Expr = null,
    payload: ?[]const u8 = null,
    body: ?Expr = null,
};

pub const If = struct {
    branches: StackChain(ConditionBranch),
    did_end: bool = false,

    pub fn new(condition: Expr) If {
        return .{
            .branches = StackChain(ConditionBranch).start(.{
                .condition = condition,
            }),
        };
    }

    pub fn elseIf(self: *const If, condition: Expr) If {
        assert(!self.did_end);
        assert(self.branches.value.body != null);
        return .{ .branches = self.branches.append(.{
            .condition = condition,
        }) };
    }

    pub fn @"else"(self: *const If) If {
        assert(!self.did_end);
        assert(self.branches.value.body != null);
        return .{
            .branches = self.branches.append(.{}),
            .did_end = true,
        };
    }

    pub fn capture(self: *const If, payload: []const u8) If {
        assert(self.branches.value.body == null);
        assert(self.branches.value.payload == null);
        var dupe = self.*;
        dupe.branches.value.payload = payload;
        return dupe;
    }

    pub fn body(self: *const If, expr: Expr) If {
        assert(self.branches.value.body == null);
        var dupe = self.*;
        dupe.branches.value.body = expr;
        return dupe;
    }

    pub fn __write(self: If, writer: *CodegenWriter) !void {
        var branch_buff: [16]ConditionBranch = undefined;
        const branches = try self.branches.unwrap(&branch_buff);

        for (branches, 0..) |branch, i| {
            if (i == 0) {
                try writer.appendFmt("if ({}) ", .{branch.condition.?});
            } else if (branch.condition) |condition| {
                try writer.appendFmt(" else if ({}) ", .{condition});
            } else {
                try writer.appendString(" else ");
            }

            if (branch.payload) |p| try writer.appendFmt("|{s}| ", .{p});
            try writer.appendValue(branch.body.?);
        }
    }
};

test "If" {
    try CodegenWriter.expect(
        "if (foo) bar",
        If.new(Expr.raw("foo")).body(Expr.raw("bar")),
    );

    try CodegenWriter.expect(
        "if (foo) |bar| baz else qux",
        If.new(Expr.raw("foo")).capture("bar").body(Expr.raw("baz"))
            .@"else"().body(Expr.raw("qux")),
    );

    try CodegenWriter.expect(
        "if (foo) bar else if (baz) qux else quxx",
        If.new(Expr.raw("foo")).body(Expr.raw("bar"))
            .elseIf(Expr.raw("baz")).body(Expr.raw("qux"))
            .@"else"().body(Expr.raw("quxx")),
    );
}

pub const For = struct {
    iterables: StackChain(?Iterable) = .{},
    branches: StackChain(ConditionBranch) = StackChain(ConditionBranch).start(.{}),
    did_loop: bool = false,
    did_end: bool = false,

    const Iterable = struct {
        expr: Expr,
        payload: []const u8,
    };

    pub fn iter(self: *const For, expr: Expr, payload: []const u8) For {
        assert(!self.did_loop);
        return .{ .iterables = self.iterables.append(.{
            .expr = expr,
            .payload = payload,
        }) };
    }

    pub fn elseIf(self: *const For, condition: Expr) For {
        assert(!self.did_end and self.did_loop);
        assert(self.branches.value.body != null);
        var dupe = self.*;
        dupe.branches = self.branches.append(.{
            .condition = condition,
        });
        return dupe;
    }

    pub fn @"else"(self: *const For) For {
        assert(!self.did_end and self.did_loop);
        assert(self.branches.value.body != null);
        var dupe = self.*;
        dupe.branches = self.branches.append(.{});
        dupe.did_end = true;
        return dupe;
    }

    pub fn capture(self: *const For, payload: []const u8) For {
        assert(self.did_loop);
        assert(self.branches.value.body == null);
        assert(self.branches.value.payload == null);
        var dupe = self.*;
        dupe.branches.value.payload = payload;
        return dupe;
    }

    pub fn body(self: *const For, expr: Expr) For {
        assert(self.branches.value.body == null);
        var dupe = self.*;
        dupe.branches.value.body = expr;
        dupe.did_loop = true;
        return dupe;
    }

    pub fn __write(self: For, writer: *CodegenWriter) !void {
        var branch_buff: [4]ConditionBranch = undefined;
        const branches = try self.branches.unwrap(&branch_buff);

        {
            var iter_buff: [8]Iterable = undefined;
            const iterables = try self.iterables.unwrap(&iter_buff);

            const branch = branches[0];
            try writer.appendString("for (");
            try writer.appendList(Iterable, iterables, .{
                .delimiter = ", ",
                .field = "expr",
            });
            try writer.appendString(") |");
            try writer.appendList(Iterable, iterables, .{
                .delimiter = ", ",
                .field = "payload",
                .format = "s",
            });
            try writer.appendFmt("| {}", .{branch.body.?});
        }

        for (branches[1..branches.len]) |branch| {
            if (branch.condition) |condition| {
                try writer.appendFmt(" else if ({}) ", .{condition});
            } else {
                try writer.appendString(" else ");
            }

            if (branch.payload) |p| try writer.appendFmt("|{s}| ", .{p});
            try writer.appendValue(branch.body.?);
        }
    }
};

test "For" {
    try CodegenWriter.expect(
        "for (foo) |bar| baz",
        (For{}).iter(Expr.raw("foo"), "bar")
            .body(Expr.raw("baz")),
    );

    try CodegenWriter.expect(
        "for (foo, bar) |baz, _| qux",
        (For{}).iter(Expr.raw("foo"), "baz").iter(Expr.raw("bar"), "_")
            .body(Expr.raw("qux")),
    );

    try CodegenWriter.expect(
        "for (foo) |_| bar else baz",
        (For{}).iter(Expr.raw("foo"), "_")
            .body(Expr.raw("bar"))
            .@"else"().body(Expr.raw("baz")),
    );
}

pub const While = struct {
    branches: StackChain(ConditionBranch),
    continue_expr: ?Expr = null,
    did_loop: bool = false,
    did_end: bool = false,

    pub fn new(condition: Expr) While {
        return .{ .branches = StackChain(ConditionBranch).start(.{
            .condition = condition,
            .body = undefined,
        }) };
    }

    pub fn continueExpr(self: *const While, expr: Expr) While {
        assert(!self.did_loop);
        var dupe = self.*;
        dupe.continue_expr = expr;
        return dupe;
    }

    pub fn elseIf(self: *const While, condition: Expr) While {
        assert(!self.did_end and self.did_loop);
        assert(self.branches.value.body != null);
        var dupe = self.*;
        dupe.branches = self.branches.append(.{ .condition = condition });
        return dupe;
    }

    pub fn @"else"(self: *const While) While {
        assert(!self.did_end and self.did_loop);
        assert(self.branches.value.body != null);
        var dupe = self.*;
        dupe.branches = self.branches.append(.{});
        return dupe;
    }

    pub fn capture(self: *const While, payload: []const u8) While {
        assert(self.branches.value.body == null);
        assert(self.branches.value.payload == null);
        var dupe = self.*;
        dupe.branches.value.payload = payload;
        return dupe;
    }

    pub fn body(self: *const While, expr: Expr) While {
        assert(self.branches.value.body == null);
        var dupe = self.*;
        dupe.branches.value.body = expr;
        dupe.did_loop = true;
        return dupe;
    }

    pub fn __write(self: While, writer: *CodegenWriter) !void {
        var branch_buff: [4]ConditionBranch = undefined;
        const branches = try self.branches.unwrap(&branch_buff);

        for (branches, 0..) |branch, i| {
            if (i == 0) {
                try writer.appendFmt("while ({}) ", .{branch.condition.?});
            } else if (branch.condition) |condition| {
                try writer.appendFmt(" else if ({})", .{condition});
            } else {
                try writer.appendString(" else ");
            }

            if (branch.payload) |p| try writer.appendFmt("|{s}| ", .{p});
            if (i == 0) if (self.continue_expr) |expr| try writer.appendFmt(": ({}) ", .{expr});
            try writer.appendValue(branch.body.?);
        }
    }
};

test "While" {
    try CodegenWriter.expect(
        "while (foo) bar",
        While.new(Expr.raw("foo")).body(Expr.raw("bar")),
    );

    try CodegenWriter.expect(
        "while (foo) : (bar) baz",
        While.new(Expr.raw("foo")).continueExpr(Expr.raw("bar"))
            .body(Expr.raw("baz")),
    );

    try CodegenWriter.expect(
        "while (foo) |_| : (bar) baz else qux",
        While.new(Expr.raw("foo")).capture("_").continueExpr(Expr.raw("bar"))
            .body(Expr.raw("baz"))
            .@"else"().body(Expr.raw("qux")),
    );
}

pub const Switch = struct {
    value: Expr,
    statements: std.ArrayList(Statement),
    state: State = .idle,

    const State = enum { idle, inlined, complete };

    pub fn init(allocator: Allocator, value: Expr) Switch {
        return .{
            .value = value,
            .statements = std.ArrayList(Statement).init(allocator),
        };
    }

    pub fn deinit(self: Switch) void {
        self.statements.deinit();
    }

    pub fn inlined(self: *Switch) *Switch {
        assert(self.state == .idle);
        self.state = .inlined;
        return self;
    }

    pub fn branch(self: *Switch) Prong {
        assert(self.state != .complete);
        return .{ .parent = self };
    }

    pub fn @"else"(self: *Switch) Prong {
        assert(self.state != .complete);
        return .{
            .parent = self,
            .cases = StackChain(?Case).start(.{ .single = Expr.raw("else") }),
            .allow_case = false,
        };
    }

    pub fn nonExhaustive(self: *Switch) Prong {
        assert(self.state != .complete);
        return .{
            .parent = self,
            .cases = StackChain(?Case).start(.{ .single = Expr.raw("_") }),
            .allow_case = false,
        };
    }

    fn completeProng(
        self: *Switch,
        cases: StackChain(?Case),
        capture: StackChain(?[]const u8),
        body: Expr,
    ) !void {
        try self.statements.append(.{
            .prong = .{
                .is_inline = if (self.state == .inlined) blk: {
                    self.state = .idle;
                    break :blk true;
                } else false,
                .cases = cases,
                .capture = capture,
                .body = body,
            },
        });
    }

    pub const Prong = struct {
        parent: *Switch,
        allow_case: bool = true,
        cases: StackChain(?Case) = .{},
        payload: StackChain(?[]const u8) = .{},

        pub fn case(self: *const Prong, expr: Expr) Prong {
            assert(self.allow_case);
            var dupe = self.*;
            dupe.cases = self.cases.append(.{ .single = expr });
            return dupe;
        }

        pub fn caseRange(self: *const Prong, from: Expr, to: Expr) Prong {
            assert(self.allow_case);
            var dupe = self.*;
            dupe.cases = self.cases.append(.{ .range = .{ from, to } });
            return dupe;
        }

        pub fn capture(self: *const Prong, payload: []const u8) Prong {
            var dupe = self.*;
            dupe.payload = self.payload.append(payload);
            dupe.allow_case = false;
            return dupe;
        }

        pub fn body(self: *const Prong, expr: Expr) !void {
            assert(!self.cases.isEmpty());
            try self.parent.completeProng(self.cases, self.payload, expr);
        }
    };

    pub fn __write(self: Switch, writer: *CodegenWriter) !void {
        try writer.appendFmt("switch ({}) {{", .{self.value});
        try writer.breakList(Statement, self.statements.items, .{
            .line = .{ .indent = "    " },
        });
        try writer.breakChar('}');
    }

    const Statement = union(enum) {
        prong: struct {
            is_inline: bool,
            cases: StackChain(?Case),
            capture: StackChain(?[]const u8),
            body: Expr,
        },

        pub fn __write(self: Statement, writer: *CodegenWriter) !void {
            switch (self) {
                .prong => |prong| {
                    var buffer: [32]Case = undefined;
                    const cases = try prong.cases.unwrap(&buffer);

                    if (prong.is_inline) try writer.appendString("inline ");
                    try writer.appendList(Case, cases, .{ .delimiter = ", " });
                    if (prong.capture.isEmpty()) {
                        try writer.appendString(" =>");
                    } else {
                        var buff_capture: [2][]const u8 = undefined;
                        const captures = try prong.capture.unwrap(&buff_capture);

                        try writer.appendString(" => |");
                        try writer.appendList([]const u8, captures, .{
                            .delimiter = ", ",
                            .format = "s",
                        });
                        try writer.appendChar('|');
                    }
                    try writer.appendFmt(" {},", .{prong.body});
                },
            }
        }
    };

    const Case = union(enum) {
        single: Expr,
        range: [2]Expr,

        pub fn __write(self: Case, writer: *CodegenWriter) !void {
            switch (self) {
                .single => |expr| try writer.appendValue(expr),
                .range => |range| try writer.appendFmt("{}...{}", .{ range[0], range[1] }),
            }
        }
    };
};

test "Switch" {
    var builder = Switch.init(test_alloc, Expr.raw("foo"));
    defer builder.deinit();

    try builder.branch().case(Expr.raw("bar")).case(Expr.raw("baz"))
        .capture("val").capture("tag")
        .body(Expr.raw("qux"));
    try builder.branch()
        .caseRange(Expr.raw("18"), Expr.raw("108"))
        .body(Expr.raw("unreachable"));
    try builder.inlined().@"else"().body(Expr.raw("unreachable"));

    try CodegenWriter.expect(
        \\switch (foo) {
        \\    bar, baz => |val, tag| qux,
        \\    18...108 => unreachable,
        \\    inline else => unreachable,
        \\}
    , builder);
}