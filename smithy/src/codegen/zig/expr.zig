const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const decl = @import("../../utils/declarative.zig");
const StackChain = decl.StackChain;
const Closure = decl.Closure;
const callClosure = decl.callClosure;
const Writer = @import("../CodegenWriter.zig");
const flow = @import("flow.zig");

pub const Expr = union(enum) {
    _empty,
    _error: anyerror,
    _chain: []const Expr,
    raw: []const u8,
    type: ExprType,
    value: ExprValue,
    keyword: ExprKeyword,
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

    pub fn __write(self: Expr, writer: *Writer) anyerror!void {
        switch (self) {
            ._empty => unreachable,
            ._error => |err| return err,
            ._chain => unreachable,
            .raw => |s| try writer.appendString(s),
            .flow => |t| try t.write(writer),
            else => unreachable,
            // .empty => ex,
            // .chain => |t| Expr{ .chain = t.append(ex) },
            // else => Expr{ .chain = StackChain(Expr).start(self.*).append(ex) },
        }
    }
};

const ExprType = union(enum) {
    PLACEHOLDER,
};

const ExprValue = union(enum) {
    PLACEHOLDER,
};

const ExprFlow = union(enum) {
    @"if": flow.If,
    @"for": flow.For,
    @"while": *const flow.While,
    @"switch": *const flow.Switch,
    @"defer": *const flow.Defer,
    @"errdefer": *const flow.Errdefer,

    pub fn deinit(self: ExprFlow, allocator: Allocator) void {
        switch (self) {
            inline .@"if", .@"for" => |t| t.deinit(allocator),
            inline else => |t| {
                t.deinit(allocator);
                allocator.destroy(t);
            },
        }
    }

    pub fn write(self: ExprFlow, writer: *Writer) !void {
        switch (self) {
            inline else => |t| try writer.appendValue(t),
        }
    }
};

const ExprKeyword = union(enum) {
    PLACEHOLDER,
};

pub fn _tst(str: []const u8) ExprBuild {
    return .{
        .allocator = test_alloc,
        .exprs = StackChain(?Expr).start(.{ .raw = str }),
    };
}

pub const ExprBuild = struct {
    allocator: Allocator,
    exprs: StackChain(?Expr) = .{},

    pub fn init(allocator: Allocator) ExprBuild {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: ExprBuild) void {
        if (self.exprs.isEmpty()) return;
        var current: ?*const StackChain(?Expr) = &self.exprs;
        while (current) |t| : (current = t.prev) {
            t.value.?.deinit(self.allocator);
        }
    }

    pub fn consume(self: ExprBuild) !Expr {
        if (self.exprs.isEmpty()) {
            return ._empty;
        } else if (self.exprs.len == 1) {
            return self.exprs.value.?;
        } else {
            return .{ ._chain = try self.exprs.unwrapAlloc(self.allocator) };
        }
    }

    fn append(self: *const ExprBuild, expr: anyerror!Expr) ExprBuild {
        const value = expr catch |err| Expr{ ._error = err };
        return .{
            .allocator = self.allocator,
            .exprs = self.exprs.append(value),
        };
    }

    fn dupeValue(self: ExprBuild, value: anytype) !*@TypeOf(value) {
        const data = try self.allocator.create(@TypeOf(value));
        data.* = value;
        return data;
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
        const expr = try build.@"if"(_tst("foo")).body(_tst("bar")).end().consume();
        defer expr.deinit(test_alloc);
        try Writer.expect("if (foo) bar", expr);
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
        const expr = try build.@"for"().iter(_tst("foo"), "_")
            .body(_tst("bar")).end().consume();
        defer expr.deinit(test_alloc);
        try Writer.expect("for (foo) |_| bar", expr);
    }

    pub fn @"while"(self: *const ExprBuild, condition: ExprBuild) flow.While.Build(@TypeOf(endWhile)) {
        return flow.While.build(self.allocator, endWhile, self, condition);
    }

    fn endWhile(self: *const ExprBuild, value: anyerror!flow.While) ExprBuild {
        if (value) |val| {
            return self.append(.{ .flow = .{
                .@"while" = self.dupeValue(val) catch |err| return self.append(err),
            } });
        } else |err| {
            return self.append(err);
        }
    }

    test "while" {
        var build = ExprBuild.init(test_alloc);
        const expr = try build.@"while"(_tst("foo"))
            .body(_tst("bar")).end().consume();
        defer expr.deinit(test_alloc);
        try Writer.expect("while (foo) bar", expr);
    }

    pub fn @"switch"(self: *const ExprBuild, value: ExprBuild, build: flow.SwitchFn) ExprBuild {
        try self.switchWith(self, value, {}, build);
    }

    pub fn switchWith(
        self: *const ExprBuild,
        value: ExprBuild,
        ctx: anytype,
        build: Closure(@TypeOf(ctx), flow.SwitchFn),
    ) ExprBuild {
        var builder = flow.Switch.build(self.allocator, value);
        callClosure(ctx, build, .{&builder}) catch |err| {
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
        const expr = try builder.switchWith(_tst("foo"), tag, struct {
            fn f(ctx: []const u8, build: *flow.Switch.Build) !void {
                try build.branch().case(_tst(ctx)).body(_tst("baz"));
            }
        }.f).consume();
        defer expr.deinit(test_alloc);

        try Writer.expect(
            \\switch (foo) {
            \\    bar => baz,
            \\}
        , expr);
    }

    pub fn @"defer"(self: *const ExprBuild, condition: ExprBuild) ExprBuild {
        const expr = flow.Defer{
            .body = condition.consume() catch |err| return self.append(err),
        };
        const dupe = self.dupeValue(expr) catch |err| {
            expr.deinit(self.allocator);
            return self.append(err);
        };
        return self.append(.{ .flow = .{ .@"defer" = dupe } });
    }

    test "defer" {
        var build = ExprBuild.init(test_alloc);
        const expr = try build.@"defer"(_tst("foo")).consume();
        defer expr.deinit(test_alloc);
        try Writer.expect("defer foo", expr);
    }

    pub fn @"errdefer"(self: *const ExprBuild) flow.Errdefer.Build(@TypeOf(endErrdefer)) {
        return flow.Errdefer.build(endErrdefer, self);
    }

    fn endErrdefer(self: *const ExprBuild, value: anyerror!flow.Errdefer) ExprBuild {
        if (value) |val| {
            const expr = self.dupeValue(val) catch |err| return self.append(err);
            return self.append(.{ .flow = .{ .@"errdefer" = expr } });
        } else |err| {
            return self.append(err);
        }
    }

    test "errdefer" {
        var build = ExprBuild.init(test_alloc);
        const expr = try build.@"errdefer"().body(_tst("foo")).consume();
        defer expr.deinit(test_alloc);
        try Writer.expect("errdefer foo", expr);
    }
};

test {
    _ = ExprBuild;
}
