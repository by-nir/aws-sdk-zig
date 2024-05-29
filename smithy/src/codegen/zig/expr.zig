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
    const Chain = StackChain(*const Expr);
    pub const new: Expr = Expr._empty;

    _empty,
    _error: anyerror,
    _chain: Chain,
    raw: []const u8,
    type: ExprType,
    value: ExprValue,
    flow: ExprFlow,
    operation: ExprOp,
    keyword: ExprKeyword,

    pub fn deinit(self: Expr, allocator: Allocator) void {
        switch (self) {
            .flow => |t| t.deinit(allocator),
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

    fn append(self: *const Expr, expr: anyerror!Expr) Expr {
        const expr_or_err = expr catch |err| Expr{ ._error = err };
        return switch (self.*) {
            ._empty => expr_or_err,
            ._chain => |t| Expr{ ._chain = t.append(&expr_or_err) },
            else => Expr{ ._chain = Chain.start(self).append(&expr_or_err) },
        };
    }

    pub fn _raw(self: *const Expr, value: []const u8) Expr {
        return self.append(.{ .raw = value });
    }

    //
    // Control Flow
    //

    pub fn @"if"(self: *const Expr, TEMP_allocator: Allocator, condition: Expr) flow.If.Build(@TypeOf(endIf)) {
        return flow.If.build(TEMP_allocator, endIf, self, condition);
    }

    fn endIf(self: *const Expr, value: anyerror!flow.If) Expr {
        const data = value catch |err| return self.append(err);
        return self.append(.{ .flow = .{ .@"if" = data } });
    }

    test "if" {
        const expr = new.@"if"(test_alloc, new._raw("foo")).body(new._raw("bar")).end();
        defer expr.deinit(test_alloc);
        try Writer.expect("if (foo) bar", expr);
    }

    pub fn @"for"(self: *const Expr, TEMP_allocator: Allocator) flow.For.Build(@TypeOf(endFor)) {
        return flow.For.build(TEMP_allocator, endFor, self);
    }

    fn endFor(self: *const Expr, value: anyerror!flow.For) Expr {
        const data = value catch |err| return self.append(err);
        return self.append(.{ .flow = .{ .@"for" = data } });
    }

    test "for" {
        const expr = new.@"for"(test_alloc).iter(new._raw("foo"), "_")
            .body(new._raw("bar")).end();
        defer expr.deinit(test_alloc);
        try Writer.expect("for (foo) |_| bar", expr);
    }
    pub fn @"switch"(self: *const Expr, TEMP_allocator: Allocator, value: Expr, build: flow.SwitchFn) Expr {
        try self.switchWith(TEMP_allocator, value, {}, build);
    }

    pub fn switchWith(
        self: *const Expr,
        TEMP_allocator: Allocator,
        value: Expr,
        ctx: anytype,
        build: Closure(@TypeOf(ctx), flow.SwitchFn),
    ) Expr {
        var builder = flow.Switch.Build.init(TEMP_allocator, value);
        callClosure(ctx, build, .{&builder}) catch |err| {
            builder.deinit();
            return self.append(err);
        };

        const data = TEMP_allocator.create(flow.Switch) catch |err| return self.append(err);
        errdefer TEMP_allocator.destroy(data);
        data.* = builder.consume() catch |err| return self.append(err);

        return self.append(.{ .flow = .{ .@"switch" = data } });
    }

    test "switch" {
        var tag: []const u8 = "bar";
        _ = &tag;

        const expr = new.switchWith(test_alloc, new._raw("foo"), tag, struct {
            fn f(ctx: []const u8, build: *flow.Switch.Build) !void {
                try build.branch().case(new._raw(ctx)).body(new._raw("baz"));
            }
        }.f);
        defer expr.deinit(test_alloc);

        try Writer.expect(
            \\switch (foo) {
            \\    bar => baz,
            \\}
        , expr);
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
    @"switch": *const flow.Switch,

    pub fn deinit(self: ExprFlow, allocator: Allocator) void {
        switch (self) {
            inline .@"if", .@"for" => |t| t.deinit(allocator),
            .@"switch" => |t| {
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

const ExprOp = union(enum) {
    PLACEHOLDER,
};
