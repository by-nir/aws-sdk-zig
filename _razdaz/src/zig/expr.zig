const std = @import("std");
const ZigToken = std.zig.Token.Tag;
const Allocator = std.mem.Allocator;
const test_alloc = std.testing.allocator;
const dcl = @import("../utils/declarative.zig");
const StackChain = dcl.StackChain;
const Closure = dcl.Closure;
const callClosure = dcl.callClosure;
const md = @import("../md.zig");
const Writer = @import("../CodegenWriter.zig");
const flow = @import("flow.zig");
const scope = @import("scope.zig");
const utils = @import("utils.zig");
const declare = @import("declare.zig");

pub const Expr = union(enum) {
    _empty,
    _error: anyerror,
    _chain: []const Expr,
    raw: []const u8,
    id: []const u8,
    type: ExprType,
    value: ExprValue,
    comment: ExprComment,
    flow: ExprFlow,
    declare: ExprDeclare,
    operator: ZigToken,
    keyword_tight: ZigToken,
    keyword_space: ZigToken,

    pub fn deinit(self: Expr, allocator: Allocator) void {
        switch (self) {
            ._chain => |chain| {
                for (chain) |t| t.deinit(allocator);
                allocator.free(chain);
            },
            inline .type, .value, .comment, .flow, .declare => |f| {
                f.deinit(allocator);
            },
            else => {},
        }
    }

    pub fn write(self: Expr, writer: *Writer, comptime format: []const u8) anyerror!void {
        switch (self) {
            ._empty => unreachable,
            ._error => |err| return err,
            ._chain => |chain| {
                std.debug.assert(chain.len > 0);
                if (comptime utils.isStatement(format)) {
                    const last_idx = chain.len - 1;
                    for (chain[0..last_idx]) |x| try x.write(writer, "");
                    const last = chain[last_idx];
                    try last.write(writer, format);
                    if (last == .flow) try last.flow.writeChainEnd(writer);
                } else {
                    for (chain) |t| try t.write(writer, format);
                }
            },
            .raw => |s| {
                try writer.appendMultiLine(s);
                try utils.statementSemicolon(writer, format, null);
            },
            .id => |name| {
                try writer.appendFmt("{}", .{std.zig.fmtId(name)});
                try utils.statementSemicolon(writer, format, null);
            },
            .comment => |t| try t.write(writer),
            inline .flow, .declare => |t| try t.write(writer, format),
            .operator => |t| {
                try writer.appendFmt(" {s} ", .{t.lexeme().?});
            },
            .keyword_tight => |t| try writer.appendString(t.lexeme().?),
            .keyword_space => |t| {
                try writer.appendFmt("{s} ", .{t.lexeme().?});
                try utils.statementSemicolon(writer, format, null);
            },
            inline else => |t| {
                try t.write(writer);
                try utils.statementSemicolon(writer, format, null);
            },
        }
    }

    pub fn expect(self: Expr, allocator: Allocator, expected: []const u8) !void {
        defer self.deinit(allocator);
        try Writer.expectValue(expected, self);
    }

    pub fn typeOf(comptime T: type) Expr {
        return .{ .raw = @typeName(T) };
    }
};

const ExprType = union(enum) {
    This,
    optional: *const Expr,
    array: *const Array,
    slice: struct { mutable: bool, type: *const Expr },
    pointer: struct { mutable: bool, type: *const Expr },
    val_index: *const Expr,
    val_from: *const Expr,
    val_range: *const [2]Expr,

    pub const Array = struct { len: Expr, type: Expr };

    pub fn deinit(self: ExprType, allocator: Allocator) void {
        switch (self) {
            .optional, .val_index, .val_from => |t| {
                t.deinit(allocator);
                allocator.destroy(t);
            },
            inline .slice, .pointer => |t| {
                t.type.deinit(allocator);
                allocator.destroy(t.type);
            },
            .array => |t| {
                t.len.deinit(allocator);
                t.type.deinit(allocator);
                allocator.destroy(t);
            },
            .val_range => |t| {
                t[0].deinit(allocator);
                t[1].deinit(allocator);
                allocator.destroy(t);
            },
            else => {},
        }
    }

    pub fn write(self: ExprType, writer: *Writer) anyerror!void {
        switch (self) {
            .This => try writer.appendString("@This()"),
            .val_index => |d| try writer.appendFmt("[{}]", .{d}),
            .val_from => |d| try writer.appendFmt("{}..", .{d}),
            .val_range => |r| {
                try writer.appendFmt("{}..{}", .{ r[0], r[1] });
            },
            .optional => |t| try writer.appendFmt("?{}", .{t}),
            .array => |t| {
                try writer.appendFmt("[{}]{}", .{ t.len, t.type });
            },
            inline .slice, .pointer => |t, g| {
                if (g == .pointer)
                    try writer.appendChar('*')
                else
                    try writer.appendString("[]");

                if (t.mutable)
                    try writer.appendValue(t.type)
                else
                    try writer.appendFmt("const {}", .{t.type});
            },
        }
    }
};

const ExprValue = union(enum) {
    undefined,
    null,
    void,
    false,
    true,
    int: i64,
    uint: u64,
    float: f64,
    string: []const u8,
    group: *const Expr,
    @"error": []const u8,
    @"enum": []const u8,
    @"union": [2][]const u8,
    struct_assign: struct { field: []const u8, value: *const Expr },
    struct_literal: struct { identifier: ?*const Expr, values: []const Expr },

    pub fn deinit(self: ExprValue, allocator: Allocator) void {
        switch (self) {
            .group => |t| allocator.destroy(t),
            .struct_assign => |t| {
                t.value.deinit(allocator);
                allocator.destroy(t.value);
            },
            .struct_literal => |t| {
                if (t.identifier) |id| {
                    id.deinit(allocator);
                    allocator.destroy(id);
                }
                for (t.values) |v| v.deinit(allocator);
                allocator.free(t.values);
            },
            else => {},
        }
    }

    pub fn write(self: ExprValue, writer: *Writer) anyerror!void {
        switch (self) {
            .void => try writer.appendString("{}"),
            inline .undefined, .null, .false, .true => |_, t| try writer.appendString(@tagName(t)),
            inline .int, .uint, .float => |t| try writer.appendFmt("{d}", .{t}),
            .string => |s| try writer.appendFmt("\"{}\"", .{std.zig.fmtEscapes(s)}),
            .group => |t| try writer.appendFmt("({})", .{t}),
            .@"error" => |s| try writer.appendFmt("error.{s}", .{s}),
            .@"enum" => |s| try writer.appendFmt(".{s}", .{s}),
            .@"union" => |t| switch (t[1].len) {
                0 => try writer.appendFmt(".{s}", .{t[0]}),
                else => try writer.appendFmt(".{{ .{s} = {s} }}", .{ t[0], t[1] }),
            },
            .struct_assign => |t| {
                try writer.appendFmt(".{s} = {s}", .{ t.field, t.value });
            },
            .struct_literal => |t| {
                const len = t.values.len;
                if (t.identifier) |id| {
                    try id.write(writer, "");
                } else {
                    try writer.appendChar('.');
                }
                switch (len) {
                    0 => return writer.appendString("{}"),
                    2 => try writer.appendString("{ "),
                    else => try writer.appendChar('{'),
                }
                switch (len) {
                    1, 2 => try writer.appendList(Expr, t.values, .{
                        .delimiter = ", ",
                        .line = .none,
                    }),
                    else => try writer.breakList(Expr, t.values, .{
                        .delimiter = ",",
                        .line = .{ .indent = utils.INDENT_STR },
                    }),
                }
                switch (len) {
                    1 => try writer.appendChar('}'),
                    2 => try writer.appendString(" }"),
                    else => {
                        try writer.appendChar(',');
                        try writer.breakChar('}');
                    },
                }
            },
        }
    }

    pub fn of(v: anytype) ExprValue {
        const T = @TypeOf(v);
        return switch (@typeInfo(T)) {
            .void => .void,
            .null => .null,
            .bool => if (v) .true else .false,
            .int => |t| switch (t.signedness) {
                .signed => .{ .int = v },
                .unsigned => .{ .uint = v },
            },
            .comptime_int => if (v < 0) .{ .int = v } else .{ .uint = v },
            .float, .comptime_float => .{ .float = v },
            .@"enum", .enum_literal => .{ .@"enum" = @tagName(v) },
            .optional => if (v) |s| return of(s) else .null,
            .error_set => .{ .@"error" = @errorName(v) },
            .error_union => |t| if (v) |s| switch (@typeInfo(t.payload)) {
                .void => .void,
                else => return of(s),
            } else |e| .{ .@"error" = @errorName(e) },
            .pointer => |t| blk: {
                if (t.size == .Slice and t.child == u8) {
                    break :blk .{ .string = v };
                } else if (t.size == .One) {
                    const meta = @typeInfo(t.child);
                    if (meta == .array and meta.array.child == u8) {
                        break :blk .{ .string = v };
                    }
                }
                @compileError("Only string pointers can auto-covert into a value expression.");
            },
            // union, fn, pointer, array, struct
            else => @compileError("Type `" ++ @typeName(T) ++ "` can’t auto-convert into a value expression."),
        };
    }
};

pub const ExprComment = struct {
    kind: Kind,
    source: Source,

    pub const Kind = enum { normal, doc, doc_top };
    pub const Source = union(enum) {
        plain: []const u8,
        markdown: md.Document,
    };

    pub fn deinit(self: ExprComment, allocator: Allocator) void {
        switch (self.source) {
            .plain => {},
            .markdown => |t| t.deinit(allocator),
        }
    }

    pub fn write(self: ExprComment, writer: *Writer) !void {
        const indent = switch (self.kind) {
            .normal => "// ",
            .doc => "/// ",
            .doc_top => "//! ",
        };
        try writer.pushIndent(indent);
        defer writer.popIndent();

        try writer.appendString(indent);
        switch (self.source) {
            .plain => |s| try writer.appendMultiLine(s),
            .markdown => |t| try t.write(writer),
        }
    }
};

const ExprFlow = union(enum) {
    @"if": flow.If,
    @"for": flow.For,
    @"while": *const flow.While,
    @"switch": *const flow.Switch,
    call: flow.Call,
    token_expr: *const TokenExpr,
    token_capture: *const TokenCaptureExpr,
    token_reflow: flow.TokenReflow,
    block: scope.Block,
    block_label: scope.BlockLabel,

    pub fn deinit(self: ExprFlow, allocator: Allocator) void {
        switch (self) {
            .token_reflow, .block_label => {},
            inline .@"if", .@"for", .call, .block => |t| t.deinit(allocator),
            inline else => |t| {
                t.deinit(allocator);
                allocator.destroy(t);
            },
        }
    }

    pub fn write(self: ExprFlow, writer: *Writer, comptime format: []const u8) !void {
        switch (self) {
            .call => |t| {
                try t.write(writer);
                try utils.statementSemicolon(writer, format, null);
            },
            inline .@"switch", .block, .block_label => |t| try t.write(writer),
            inline else => |t| try t.write(writer, format),
        }
    }

    pub fn writeChainEnd(self: ExprFlow, writer: *Writer) !void {
        switch (self) {
            .@"switch", .block, .block_label => try writer.appendChar(';'),
            else => {},
        }
    }
};

const ExprDeclare = union(enum) {
    field: *const declare.Field,
    variable: *const declare.Variable,
    namespace: *const declare.Namespace,
    function: *const declare.Function,
    token_expr: *const TokenExpr,
    token_str: TokenStrExpr,
    token_block: declare.TokenBlock,

    pub fn deinit(self: ExprDeclare, allocator: Allocator) void {
        switch (self) {
            .token_str => {},
            .token_block => |t| t.deinit(allocator),
            inline else => |t| {
                t.deinit(allocator);
                allocator.destroy(t);
            },
        }
    }

    pub fn write(self: ExprDeclare, writer: *Writer, comptime format: []const u8) !void {
        switch (self) {
            .token_expr => |t| try t.write(writer, ""),
            inline else => |t| try t.write(writer),
        }

        if (utils.isStatement(format)) switch (self) {
            .function, .token_block => {},
            .field => try writer.appendChar(','),
            else => try writer.appendChar(';'),
        };
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

    fn dupeExpr(self: ExprBuild, expr: ExprBuild) !*Expr {
        const value = try expr.consume();
        errdefer value.deinit(expr.allocator);
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
        } else if (std.debug.runtime_safety) {
            unreachable;
        } else {
            return error.NonCallbackExprBuilder;
        }
    }

    pub fn raw(self: *const ExprBuild, value: []const u8) ExprBuild {
        return self.append(.{ .raw = value });
    }

    pub fn fromExpr(self: *const ExprBuild, value: Expr) ExprBuild {
        return self.append(value);
    }

    pub fn buildExpr(self: *const ExprBuild, value: ExprBuild) ExprBuild {
        return self.append(value.consume());
    }

    pub fn id(self: *const ExprBuild, name: []const u8) ExprBuild {
        return self.append(.{ .id = name });
    }

    test "id" {
        try ExprBuild.init(test_alloc).id("test").expect("@\"test\"");
    }

    pub fn typeOf(self: *const ExprBuild, comptime T: type) ExprBuild {
        return self.append(.{ .raw = @typeName(T) });
    }

    pub fn typeOptional(self: *const ExprBuild, expr: ExprBuild) ExprBuild {
        const dupe = self.dupeExpr(expr) catch |err| return self.append(err);
        return self.append(.{ .type = .{ .optional = dupe } });
    }

    pub fn typeArray(self: *const ExprBuild, len: ExprBuild, t: ExprBuild) ExprBuild {
        const alloc_len = len.consume() catch |err| {
            t.deinit();
            return self.append(err);
        };
        const alloc_t = t.consume() catch |err| {
            alloc_len.deinit(len.allocator);
            return self.append(err);
        };

        const array = self.allocator.create(ExprType.Array) catch |err| {
            alloc_len.deinit(len.allocator);
            alloc_t.deinit(t.allocator);
            return self.append(err);
        };
        array.* = .{ .len = alloc_len, .type = alloc_t };
        return self.append(.{ .type = .{ .array = array } });
    }

    pub fn typeSlice(self: *const ExprBuild, mutable: bool, expr: ExprBuild) ExprBuild {
        const dupe = self.dupeExpr(expr) catch |err| return self.append(err);
        return self.append(.{ .type = .{ .slice = .{
            .mutable = mutable,
            .type = dupe,
        } } });
    }

    pub fn typePointer(self: *const ExprBuild, mutable: bool, expr: ExprBuild) ExprBuild {
        const dupe = self.dupeExpr(expr) catch |err| return self.append(err);
        return self.append(.{ .type = .{ .pointer = .{
            .mutable = mutable,
            .type = dupe,
        } } });
    }

    pub fn This(self: *const ExprBuild) ExprBuild {
        return self.append(.{ .type = .This });
    }

    test "types" {
        try ExprBuild.init(test_alloc).typeOf(error{Foo}!*const []u8).expect("error{Foo}!*const []u8");
        try ExprBuild.init(test_alloc).typeOptional(_raw("foo")).expect("?foo");
        try ExprBuild.init(test_alloc).typeArray(_raw("108"), _raw("foo")).expect("[108]foo");
        try ExprBuild.init(test_alloc).typeSlice(true, _raw("foo")).expect("[]foo");
        try ExprBuild.init(test_alloc).typeSlice(false, _raw("foo")).expect("[]const foo");
        try ExprBuild.init(test_alloc).typePointer(true, _raw("foo")).expect("*foo");
        try ExprBuild.init(test_alloc).typePointer(false, _raw("foo")).expect("*const foo");
        try ExprBuild.init(test_alloc).This().expect("@This()");
    }

    pub fn valueOf(self: *const ExprBuild, v: anytype) ExprBuild {
        return self.append(.{ .value = ExprValue.of(v) });
    }

    test "valueOf" {
        try ExprBuild.init(test_alloc).valueOf({}).expect("{}");
        try ExprBuild.init(test_alloc).valueOf(null).expect("null");
        try ExprBuild.init(test_alloc).valueOf(true).expect("true");
        try ExprBuild.init(test_alloc).valueOf(false).expect("false");
        try ExprBuild.init(test_alloc).valueOf(@as(i8, -108)).expect("-108");
        try ExprBuild.init(test_alloc).valueOf(@as(u8, 108)).expect("108");
        try ExprBuild.init(test_alloc).valueOf(-108).expect("-108");
        try ExprBuild.init(test_alloc).valueOf(108).expect("108");
        try ExprBuild.init(test_alloc).valueOf(@as(f64, 1.08)).expect("1.08");
        try ExprBuild.init(test_alloc).valueOf(1.08).expect("1.08");
        try ExprBuild.init(test_alloc).valueOf(.foo).expect(".foo");
        try ExprBuild.init(test_alloc).valueOf(ExprValue.void).expect(".void");
        // try ExprBuild.init(test_alloc).val(ExprValue{ .int = 108 }).expect(".{ .int = 108 }");
        try ExprBuild.init(test_alloc).valueOf(@as(error{Foo}!void, error.Foo)).expect("error.Foo");
        try ExprBuild.init(test_alloc).valueOf(@as(error{Foo}!void, {})).expect("{}");
        try ExprBuild.init(test_alloc).valueOf(@as(error{Foo}!u8, 108)).expect("108");
        try ExprBuild.init(test_alloc).valueOf(@as(?u8, 108)).expect("108");
        try ExprBuild.init(test_alloc).valueOf(@as(?u8, null)).expect("null");
        try ExprBuild.init(test_alloc).valueOf("foo").expect("\"foo\"");
    }

    pub fn group(self: *const ExprBuild, expr: ExprBuild) ExprBuild {
        const dupe = self.dupeExpr(expr) catch |err| return self.append(err);
        return self.append(.{ .value = .{ .group = dupe } });
    }

    test "group" {
        try ExprBuild.init(test_alloc).group(_raw("foo")).expect("(foo)");
    }

    pub fn structAssign(self: *const ExprBuild, field: []const u8, value: ExprBuild) ExprBuild {
        const dupe = self.dupeExpr(value) catch |err| return self.append(err);
        return self.append(.{ .value = .{ .struct_assign = .{
            .field = field,
            .value = dupe,
        } } });
    }

    test "structAssign" {
        try ExprBuild.init(test_alloc).structAssign("foo", _raw("bar")).expect(".foo = bar");
    }

    pub fn structLiteral(self: *const ExprBuild, identifier: ?ExprBuild, values: []const ExprBuild) ExprBuild {
        const alloc_vals = utils.consumeExprBuildList(self.allocator, values) catch |err| {
            if (identifier) |t| t.deinit();
            return self.append(err);
        };

        const alloc_id = if (identifier) |t| self.dupeExpr(t) catch |err| {
            for (alloc_vals) |v| v.deinit(self.allocator);
            self.allocator.free(alloc_vals);
            return self.append(err);
        } else null;

        return self.append(.{ .value = .{ .struct_literal = .{
            .identifier = alloc_id,
            .values = alloc_vals,
        } } });
    }

    test "structLiteral" {
        try ExprBuild.init(test_alloc).structLiteral(_raw("Foo"), &.{})
            .expect("Foo{}");

        try ExprBuild.init(test_alloc).structLiteral(null, &.{
            _raw("foo"),
        }).expect(".{foo}");

        try ExprBuild.init(test_alloc).structLiteral(null, &.{
            _raw("foo"),
            _raw("bar"),
        }).expect(".{ foo, bar }");

        try ExprBuild.init(test_alloc).structLiteral(null, &.{
            _raw("foo"),
            _raw("bar"),
            _raw("baz"),
        }).expect(
            \\.{
            \\    foo,
            \\    bar,
            \\    baz,
            \\}
        );
    }

    pub fn dot(self: *const ExprBuild) ExprBuild {
        return self.append(.{ .keyword_tight = .period });
    }

    pub fn comma(self: *const ExprBuild) ExprBuild {
        return self.append(.{ .keyword_space = .comma });
    }

    pub fn addressOf(self: *const ExprBuild) ExprBuild {
        return self.append(.{ .keyword_tight = .ampersand });
    }

    pub fn unwrap(self: *const ExprBuild) ExprBuild {
        return self.append(.{ .raw = ".?" });
    }

    pub fn deref(self: *const ExprBuild) ExprBuild {
        return self.append(.{ .keyword_tight = .period_asterisk });
    }

    /// `[<some_value>]`
    pub fn valIndexer(self: *const ExprBuild, i: ExprBuild) ExprBuild {
        const dupe = self.dupeExpr(i) catch |err| return self.append(err);
        return self.append(.{ .type = .{ .val_index = dupe } });
    }

    /// `<some_value>..`
    pub fn valFrom(self: *const ExprBuild, i: ExprBuild) ExprBuild {
        const dupe = self.dupeExpr(i) catch |err| return self.append(err);
        return self.append(.{ .type = .{ .val_from = dupe } });
    }

    /// `<some_value>..<some_value>`
    pub fn valRange(self: *const ExprBuild, a: ExprBuild, b: ExprBuild) ExprBuild {
        const range = self.allocator.create([2]Expr) catch |err| {
            a.deinit();
            b.deinit();
            return self.append(err);
        };
        range[0] = a.consume() catch |err| {
            b.deinit();
            self.allocator.destroy(range);
            return self.append(err);
        };
        range[1] = b.consume() catch |err| {
            range[0].deinit(a.allocator);
            self.allocator.destroy(range);
            return self.append(err);
        };
        return self.append(.{ .type = .{ .val_range = range } });
    }

    pub fn assign(self: *const ExprBuild) ExprBuild {
        return self.append(.{ .operator = .equal });
    }

    pub fn orElse(self: *const ExprBuild) ExprBuild {
        return self.append(.{ .operator = .keyword_orelse });
    }

    pub fn op(self: *const ExprBuild, o: Operator) ExprBuild {
        switch (o) {
            .not, .@"~" => return self.append(.{ .keyword_tight = o.toToken() }),
            else => return self.append(.{ .operator = o.toToken() }),
        }
    }

    test "separator" {
        try ExprBuild.init(test_alloc).comma().dot().unwrap().deref()
            .addressOf().valIndexer(_raw("8")).valFrom(_raw("8")).valRange(_raw("6"), _raw("8"))
            .orElse().assign().op(.not).op(.@"~").op(.eql)
            .expect(", ..?.*&[8]8..6..8 orelse  = !~ == ");
    }

    pub fn import(self: *const ExprBuild, name: []const u8) ExprBuild {
        const args = self.allocator.alloc(Expr, 1) catch |err| return self.append(err);
        args[0] = .{ .value = ExprValue.of(name) };
        return self.append(.{ .flow = .{ .call = flow.Call{
            .name = "@import",
            .args = args,
        } } });
    }

    test "import" {
        try ExprBuild.init(test_alloc).import("std").expect("@import(\"std\")");
    }

    pub fn compTime(self: *const ExprBuild) ExprBuild {
        return self.append(.{ .keyword_space = .keyword_comptime });
    }

    pub fn @"packed"(self: *const ExprBuild) ExprBuild {
        return self.append(.{ .keyword_space = .keyword_packed });
    }

    pub fn @"noalias"(self: *const ExprBuild) ExprBuild {
        return self.append(.{ .keyword_space = .keyword_noalias });
    }

    pub fn @"if"(self: *const ExprBuild, condition: ExprBuild) flow.If.Build(@TypeOf(endIf)) {
        return flow.If.build(self.allocator, endIf, self, condition);
    }

    fn endIf(self: *const ExprBuild, value: anyerror!flow.If) ExprBuild {
        const data = value catch |err| return self.append(err);
        return self.append(.{ .flow = .{ .@"if" = data } });
    }

    test "if" {
        try ExprBuild.init(test_alloc).@"if"(_raw("foo")).body(_raw("bar")).end()
            .expect("if (foo) bar");
    }

    pub fn @"for"(self: *const ExprBuild) flow.For.Build(@TypeOf(endFor)) {
        return flow.For.build(self.allocator, endFor, self);
    }

    fn endFor(self: *const ExprBuild, value: anyerror!flow.For) ExprBuild {
        const data = value catch |err| return self.append(err);
        return self.append(.{ .flow = .{ .@"for" = data } });
    }

    test "for" {
        try ExprBuild.init(test_alloc)
            .@"for"().iter(_raw("foo"), "_").body(_raw("bar")).end()
            .expect("for (foo) |_| bar");
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
        try ExprBuild.init(test_alloc).@"while"(_raw("foo")).body(_raw("bar")).end()
            .expect("while (foo) bar");
    }

    pub fn @"switch"(self: *const ExprBuild, value: ExprBuild, closure: flow.SwitchClosure) ExprBuild {
        return self.switchWith(value, {}, closure);
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
        var tag: [3]u8 = "bar".*;
        try ExprBuild.init(test_alloc)
            .switchWith(_raw("foo"), @as([]u8, &tag), struct {
            fn f(ctx: []u8, b: *flow.Switch.Build) !void {
                try b.branch().case(b.x.raw(ctx)).body(b.x.raw("baz"));
            }
        }.f).expect(
            \\switch (foo) {
            \\    bar => baz,
            \\}
        );
    }

    pub fn call(self: *const ExprBuild, name: []const u8, args: []const ExprBuild) ExprBuild {
        const data = flow.Call.init(self.allocator, name, args) catch |err| return self.append(err);
        return self.append(.{ .flow = .{ .call = data } });
    }

    test "call" {
        try ExprBuild.init(test_alloc).call("foo", &.{ _raw("bar"), _raw("baz") })
            .expect("foo(bar, baz)");
    }

    pub fn @"catch"(self: *const ExprBuild) TokenCaptureExpr.Build(@TypeOf(endCatch)) {
        return TokenCaptureExpr.build(endCatch, self, .keyword_catch);
    }

    fn endCatch(self: *const ExprBuild, value: anyerror!TokenCaptureExpr) ExprBuild {
        var data = value catch |err| return self.append(err);
        data.padding = true;

        const dupe = self.dupeValue(data) catch |err| {
            data.deinit(self.allocator);
            return self.append(err);
        };
        return self.append(.{ .flow = .{ .token_capture = dupe } });
    }

    test "catch" {
        try ExprBuild.init(test_alloc).@"catch"().capture("foo").body(_raw("bar"))
            .expect(" catch |foo| bar");
    }

    pub fn label(self: *const ExprBuild, name: []const u8) ExprBuild {
        const data = scope.BlockLabel{ .name = name };
        return self.append(.{ .flow = .{ .block_label = data } });
    }

    test "label" {
        try ExprBuild.init(test_alloc).label("foo").expect("foo: ");
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
        var tag: [3]u8 = "bar".*;
        try ExprBuild.init(test_alloc).blockWith(@as([]u8, &tag), struct {
            fn f(ctx: []u8, b: *scope.BlockBuild) !void {
                try b.defers(b.x.raw(ctx));
            }
        }.f).expect(
            \\{
            \\    defer bar;
            \\}
        );
    }

    pub fn trys(self: *const ExprBuild) ExprBuild {
        const data = flow.TokenReflow{
            .token = .keyword_try,
            .label = null,
        };
        return self.append(.{ .flow = .{ .token_reflow = data } });
    }

    pub fn inlines(self: *const ExprBuild) ExprBuild {
        const data = flow.TokenReflow{
            .token = .keyword_inline,
            .label = null,
        };
        return self.append(.{ .flow = .{ .token_reflow = data } });
    }

    pub fn returns(self: *const ExprBuild) ExprBuild {
        const data = flow.TokenReflow{
            .token = .keyword_return,
            .label = null,
        };
        return self.append(.{ .flow = .{ .token_reflow = data } });
    }

    pub fn breaks(self: *const ExprBuild, label_name: ?[]const u8) ExprBuild {
        const data = flow.TokenReflow{
            .token = .keyword_break,
            .label = label_name,
        };
        return self.append(.{ .flow = .{ .token_reflow = data } });
    }

    pub fn continues(self: *const ExprBuild, label_name: ?[]const u8) ExprBuild {
        const data = flow.TokenReflow{
            .token = .keyword_continue,
            .label = label_name,
        };
        return self.append(.{ .flow = .{ .token_reflow = data } });
    }

    test "reflows" {
        const build = ExprBuild.init(test_alloc);
        try build.trys().raw("foo").expect("try foo");
        try build.inlines().raw("foo").expect("inline foo");
        try build.returns().raw("foo").expect("return foo");
        try build.breaks("foo").raw("bar").expect("break :foo bar");
        try build.continues("foo").raw("bar").expect("continue :foo bar");
    }

    //
    // Declare
    //

    pub fn variable(self: *const ExprBuild, name: []const u8) declare.Variable.Build(@TypeOf(endVariable)) {
        return declare.Variable.build(endVariable, self, false, name);
    }

    pub fn constant(self: *const ExprBuild, name: []const u8) declare.Variable.Build(@TypeOf(endVariable)) {
        return declare.Variable.build(endVariable, self, true, name);
    }

    fn endVariable(self: *const ExprBuild, value: anyerror!declare.Variable) ExprBuild {
        const data = value catch |err| return self.append(err);
        const dupe = self.dupeValue(data) catch |err| {
            data.deinit(self.allocator);
            return self.append(err);
        };
        return self.append(.{ .declare = .{ .variable = dupe } });
    }

    test "variables" {
        try ExprBuild.init(test_alloc).variable("foo").comma(
            ExprBuild.init(test_alloc).constant("bar").assign(_raw("baz")),
        ).expect("var foo, const bar = baz");
    }

    pub fn @"struct"(self: *const ExprBuild) declare.Namespace.Build(@TypeOf(endNamespace)) {
        return declare.Namespace.build(self.allocator, endNamespace, self, .keyword_struct);
    }

    pub fn @"enum"(self: *const ExprBuild) declare.Namespace.Build(@TypeOf(endNamespace)) {
        return declare.Namespace.build(self.allocator, endNamespace, self, .keyword_enum);
    }

    pub fn @"union"(self: *const ExprBuild) declare.Namespace.Build(@TypeOf(endNamespace)) {
        return declare.Namespace.build(self.allocator, endNamespace, self, .keyword_union);
    }

    pub fn @"opaque"(self: *const ExprBuild) declare.Namespace.Build(@TypeOf(endNamespace)) {
        return declare.Namespace.build(self.allocator, endNamespace, self, .keyword_opaque);
    }

    fn endNamespace(self: *const ExprBuild, value: anyerror!declare.Namespace) ExprBuild {
        const data = value catch |err| return self.append(err);
        const dupe = self.dupeValue(data) catch |err| {
            data.deinit(self.allocator);
            return self.append(err);
        };
        return self.append(.{ .declare = .{ .namespace = dupe } });
    }

    test "namespaces" {
        const Test = struct {
            fn f(_: *scope.ContainerBuild) !void {}
        };

        const build = ExprBuild.init(test_alloc);
        try build.@"struct"().body(Test.f).expect("struct {}");
        try build.@"enum"().body(Test.f).expect("enum {}");
        try build.@"union"().body(Test.f).expect("union(enum) {}");
        try build.@"opaque"().body(Test.f).expect("opaque {}");
    }

    pub fn expect(self: ExprBuild, expected: []const u8) !void {
        const expr = try self.consume();
        defer expr.deinit(self.allocator);
        try Writer.expectValue(expected, expr);
    }
};

pub const TokenExpr = struct {
    token: ZigToken,
    expr: ?Expr,

    pub fn deinit(self: TokenExpr, allocator: Allocator) void {
        if (self.expr) |t| t.deinit(allocator);
    }

    pub fn write(self: TokenExpr, writer: *Writer, comptime format: []const u8) !void {
        const keyword = self.token.lexeme().?;
        if (self.expr) |t| {
            try writer.appendFmt("{s} {}", .{ keyword, t });
            try utils.statementSemicolon(writer, format, self.expr);
        } else {
            try writer.appendString(keyword);
            try utils.statementSemicolon(writer, format, null);
        }
    }
};

test "TokenExpr" {
    var expr = TokenExpr{ .token = .keyword_return, .expr = null };
    {
        defer expr.deinit(test_alloc);
        try Writer.expectValue("return", expr);
        try Writer.expectFmt("return;", "{;}", .{expr});
    }

    expr = TokenExpr{ .token = .keyword_defer, .expr = .{ .raw = "foo" } };
    {
        defer expr.deinit(test_alloc);
        try Writer.expectValue("defer foo", expr);
        try Writer.expectFmt("defer foo;", "{;}", .{expr});
    }

    expr = TokenExpr{
        .token = .keyword_defer,
        .expr = .{ .flow = .{ .block = .{ .statements = &.{} } } },
    };
    {
        defer expr.deinit(test_alloc);
        try Writer.expectFmt("defer {}", "{;}", .{expr});
    }
}

pub const TokenCaptureExpr = struct {
    token: ZigToken,
    padding: bool = false,
    payload: ?[]const u8 = null,
    body: Expr,

    pub fn deinit(self: TokenCaptureExpr, allocator: Allocator) void {
        self.body.deinit(allocator);
    }

    pub fn write(self: TokenCaptureExpr, writer: *Writer, comptime format: []const u8) !void {
        if (self.padding) try writer.appendChar(' ');
        try writer.appendFmt("{s} ", .{self.token.lexeme().?});
        if (self.payload) |p| {
            try writer.appendFmt("|{_}| ", .{std.zig.fmtId(p)});
        }
        try writer.appendValue(self.body);
        try utils.statementSemicolon(writer, format, self.body);
    }

    pub fn build(callback: anytype, ctx: anytype, token: ZigToken) Build(@TypeOf(callback)) {
        return .{
            .callback = dcl.callback(ctx, callback),
            .token = token,
        };
    }

    pub fn Build(comptime Fn: type) type {
        const Callback = dcl.InferCallback(Fn);
        return struct {
            const Self = @This();

            callback: Callback,
            token: ZigToken,
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
                        .token = self.token,
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

test "TokenCaptureExpr" {
    const Test = utils.TestVal(TokenCaptureExpr);
    var tester = Test{ .expected = "errdefer foo" };
    try TokenCaptureExpr.build(Test.callback, &tester, .keyword_errdefer).body(_raw("foo"));

    tester.expected = "errdefer |foo| bar";
    try TokenCaptureExpr.build(Test.callback, &tester, .keyword_errdefer)
        .capture("foo").body(_raw("bar"));
}

test "TokenCaptureExpr: statement" {
    const Test = utils.TestFmt(TokenCaptureExpr, "{;}");
    var tester = Test{ .expected = "errdefer foo;" };
    try TokenCaptureExpr.build(Test.callback, &tester, .keyword_errdefer).body(_raw("foo"));

    tester.expected = "errdefer {}";
    try TokenCaptureExpr.build(Test.callback, &tester, .keyword_errdefer).body(_blk);
}

pub const TokenStrExpr = struct {
    token: ZigToken,
    string: ?[]const u8,

    pub fn write(self: TokenStrExpr, writer: *Writer) !void {
        const keyword = self.token.lexeme().?;
        if (self.string) |s| {
            try writer.appendFmt("{s} \"{}\" ", .{ keyword, std.zig.fmtEscapes(s) });
        } else {
            try writer.appendFmt("{s} ", .{keyword});
        }
    }
};

test "TokenStrExpr" {
    try Writer.expectValue("extern ", TokenStrExpr{
        .token = .keyword_extern,
        .string = null,
    });
    try Writer.expectValue("extern \"foo\" ", TokenStrExpr{
        .token = .keyword_extern,
        .string = "foo",
    });
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

const TokenInt = @typeInfo(ZigToken).@"enum".tag_type;
pub const Operator = enum(TokenInt) {
    eql = @intFromEnum(ZigToken.equal_equal),
    not_eql = @intFromEnum(ZigToken.bang_equal),
    lt = @intFromEnum(ZigToken.angle_bracket_left),
    lte = @intFromEnum(ZigToken.angle_bracket_left_equal),
    gt = @intFromEnum(ZigToken.angle_bracket_right),
    gte = @intFromEnum(ZigToken.angle_bracket_right_equal),
    not = @intFromEnum(ZigToken.bang),
    @"and" = @intFromEnum(ZigToken.keyword_and),
    @"or" = @intFromEnum(ZigToken.keyword_or),

    @"+" = @intFromEnum(ZigToken.plus),
    @"+=" = @intFromEnum(ZigToken.plus_equal),
    @"+%" = @intFromEnum(ZigToken.plus_percent),
    @"+%=" = @intFromEnum(ZigToken.plus_percent_equal),
    @"+|" = @intFromEnum(ZigToken.plus_pipe),
    @"+|=" = @intFromEnum(ZigToken.plus_pipe_equal),
    @"-" = @intFromEnum(ZigToken.minus),
    @"-=" = @intFromEnum(ZigToken.minus_equal),
    @"-%" = @intFromEnum(ZigToken.minus_percent),
    @"-%=" = @intFromEnum(ZigToken.minus_percent_equal),
    @"-|" = @intFromEnum(ZigToken.minus_pipe),
    @"-|=" = @intFromEnum(ZigToken.minus_pipe_equal),
    @"*" = @intFromEnum(ZigToken.asterisk),
    @"*=" = @intFromEnum(ZigToken.asterisk_equal),
    @"*%" = @intFromEnum(ZigToken.asterisk_percent),
    @"*%=" = @intFromEnum(ZigToken.asterisk_percent_equal),
    @"*|" = @intFromEnum(ZigToken.asterisk_pipe),
    @"*|=" = @intFromEnum(ZigToken.asterisk_pipe_equal),
    @"/" = @intFromEnum(ZigToken.slash),
    @"/=" = @intFromEnum(ZigToken.slash_equal),
    @"%" = @intFromEnum(ZigToken.percent),
    @"%=" = @intFromEnum(ZigToken.percent_equal),

    @"++" = @intFromEnum(ZigToken.plus_plus),
    @"**" = @intFromEnum(ZigToken.asterisk_asterisk),

    @"~" = @intFromEnum(ZigToken.tilde),
    @"|" = @intFromEnum(ZigToken.pipe),
    @"|=" = @intFromEnum(ZigToken.pipe_equal),
    @"^" = @intFromEnum(ZigToken.caret),
    @"^=" = @intFromEnum(ZigToken.caret_equal),
    @"&" = @intFromEnum(ZigToken.ampersand),
    @"&=" = @intFromEnum(ZigToken.ampersand_equal),

    @"<<" = @intFromEnum(ZigToken.angle_bracket_angle_bracket_left),
    @"<<=" = @intFromEnum(ZigToken.angle_bracket_angle_bracket_left_equal),
    @"<<|" = @intFromEnum(ZigToken.angle_bracket_angle_bracket_left_pipe),
    @"<<|=" = @intFromEnum(ZigToken.angle_bracket_angle_bracket_left_pipe_equal),
    @">>" = @intFromEnum(ZigToken.angle_bracket_angle_bracket_right),
    @">>=" = @intFromEnum(ZigToken.angle_bracket_angle_bracket_right_equal),

    pub fn toToken(self: Operator) ZigToken {
        return @enumFromInt(@intFromEnum(self));
    }
};

test {
    _ = ExprBuild;
}
