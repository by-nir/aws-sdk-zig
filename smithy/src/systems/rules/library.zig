const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = std.testing.allocator;
const rls = @import("model.zig");
const Generator = @import("Generator.zig");
const symbols = @import("../symbols.zig");
const idHash = symbols.idHash;
const zig = @import("../../codegen/zig.zig");
const Expr = zig.Expr;
const ExprBuild = zig.ExprBuild;
const ContainerBuild = zig.ContainerBuild;
const name_util = @import("../../utils/names.zig");
const config = @import("../../config.zig");

pub fn Registry(comptime T: type) type {
    return []const struct { T.Id, T };
}

pub const BuiltInsRegistry = Registry(BuiltIn);
pub const FunctionsRegistry = Registry(Function);

pub const BuiltIn = struct {
    genFn: ?GenFn = null,
    /// Optionally specifies the default value for the parameter if not set.
    type: rls.ParamValue,
    /// Specifies that the parameter is required to be provided to the
    /// endpoint provider.
    required: ?bool = null,
    /// Specifies a string that will be used to generate API reference
    /// documentation for the endpoint parameter.
    documentation: []const u8 = "",
    /// Specifies whether an endpoint parameter has been deprecated.
    deprecated: ?rls.Deprecated = null,

    pub const GenFn = *const fn (gen: Generator, x: ExprBuild) anyerror!Expr;

    pub const Id = enum(symbols.IdHashInt) {
        pub const NULL: Id = @enumFromInt(0);

        endpoint = idHash("SDK::Endpoint"),
        _,

        pub fn of(name: []const u8) Id {
            return @enumFromInt(idHash(name));
        }
    };
};

test "BuiltIn.Id" {
    try testing.expectEqual(.endpoint, BuiltIn.Id.of("SDK::Endpoint"));
    try testing.expectEqual(
        @as(BuiltIn.Id, @enumFromInt(0x472ff9ea)),
        BuiltIn.Id.of("FOO::Example"),
    );
}

pub const std_builtins: BuiltInsRegistry = &.{
    .{ BuiltIn.Id.endpoint, BuiltIn{
        .type = .{ .string = null },
        .documentation = "A custom endpoint for a rule set.",
    } },
};

pub const Function = struct {
    genFn: GenFn,
    returns: ?Expr,
    returns_optional: bool = false,

    pub const GenFn = *const fn (gen: *Generator, x: ExprBuild, args: []const rls.ArgValue) anyerror!Expr;

    pub const Id = enum(symbols.IdHashInt) {
        pub const NULL: Id = @enumFromInt(0);

        boolean_equals = idHash("booleanEquals"),
        get_attr = idHash("getAttr"),
        is_set = idHash("isSet"),
        is_valid_host_label = idHash("isValidHostLabel"),
        not = idHash("not"),
        parse_url = idHash("parseURL"),
        string_equals = idHash("stringEquals"),
        substring = idHash("substring"),
        uri_encode = idHash("uriEncode"),
        _,

        pub fn of(name: []const u8) Id {
            return @enumFromInt(idHash(name));
        }
    };

    pub fn expect(impl: GenFn, args: []const rls.ArgValue, expected: []const u8) !void {
        var tst = try Generator.Tester.init();
        defer tst.deinit();

        var expr = try impl(tst.gen, tst.x, args);
        try expr.expect(tst.alloc, expected);
    }
};

test "Function.Id" {
    try testing.expectEqual(.boolean_equals, Function.Id.of("booleanEquals"));
    try testing.expectEqual(
        @as(Function.Id, @enumFromInt(0xdcf4a50d)),
        Function.Id.of("foo.example"),
    );
}

pub const std_functions: FunctionsRegistry = &.{
    .{ Function.Id.get_attr, Function{
        .returns = null,
        .genFn = fnGetAttr,
    } },
    .{ Function.Id.not, Function{
        .returns = Expr.typeOf(bool),
        .genFn = fnNot,
    } },
    .{ Function.Id.is_set, Function{
        .returns = Expr.typeOf(bool),
        .genFn = fnIsSet,
    } },
    .{ Function.Id.boolean_equals, Function{
        .returns = Expr.typeOf(bool),
        .genFn = fnBooleanEquals,
    } },
    .{ Function.Id.string_equals, Function{
        .returns = Expr.typeOf(bool),
        .genFn = fnStringEquals,
    } },
    .{ Function.Id.is_valid_host_label, Function{
        .returns = Expr.typeOf(bool),
        .genFn = fnIsValidHostLabel,
    } },
    .{ Function.Id.parse_url, Function{
        .returns = Expr.typeOf(?std.Uri),
        .returns_optional = true,
        .genFn = fnParseUrl,
    } },
    .{ Function.Id.uri_encode, Function{
        .returns = Expr.typeOf([]const u8),
        .genFn = fnUriEncode,
    } },
    .{ Function.Id.substring, Function{
        .returns = Expr.typeOf(?[]const u8),
        .returns_optional = true,
        .genFn = fnSubstring,
    } },
};

fn fnBooleanEquals(gen: *Generator, x: ExprBuild, args: []const rls.ArgValue) !Expr {
    const lhs = try gen.evalArg(x, args[0]);
    const rhs = try gen.evalArg(x, args[1]);

    if (unwrapBool(lhs)) |val| {
        lhs.deinit(x.allocator);
        return if (val) x.fromExpr(rhs).consume() else x.op(.not).fromExpr(rhs).consume();
    } else if (unwrapBool(rhs)) |val| {
        rhs.deinit(x.allocator);
        return if (val) x.fromExpr(lhs).consume() else x.op(.not).fromExpr(lhs).consume();
    } else {
        return x.fromExpr(lhs).op(.eql).fromExpr(rhs).consume();
    }
}

fn unwrapBool(expr: Expr) ?bool {
    if (expr != .value) return null;
    return switch (expr.value) {
        .true => true,
        .false => false,
        else => null,
    };
}

test "fnBooleanEquals" {
    try Function.expect(fnBooleanEquals, &.{
        .{ .boolean = true },
        .{ .reference = "Foo" },
    }, "config.foo.?");

    try Function.expect(fnBooleanEquals, &.{
        .{ .boolean = false },
        .{ .reference = "Foo" },
    }, "!config.foo.?");

    try Function.expect(fnBooleanEquals, &.{
        .{ .reference = "Foo" },
        .{ .reference = "Bar" },
    }, "config.foo.? == config.bar");
}

fn fnIsSet(gen: *Generator, x: ExprBuild, args: []const rls.ArgValue) !Expr {
    const arg = try gen.evalArgRaw(x, args[0]);
    return x.fromExpr(arg).op(.not_eql).valueOf(null).consume();
}

test "fnIsSet" {
    try Function.expect(fnIsSet, &.{.{ .reference = "foo" }}, "foo != null");
}

fn fnNot(gen: *Generator, x: ExprBuild, args: []const rls.ArgValue) !Expr {
    const arg = try gen.evalArg(x, args[0]);
    return x.op(.not).fromExpr(arg).consume();
}

test "fnNot" {
    try Function.expect(fnNot, &.{.{ .boolean = true }}, "!true");
}

fn fnGetAttr(gen: *Generator, x: ExprBuild, args: []const rls.ArgValue) !Expr {
    const val = try gen.evalArg(x, args[0]);
    const path = args[1].string;

    if (path[0] == '[') {
        // Spec only allows indexer as the last part of the path.
        return x.fromExpr(val).raw(path).consume();
    }

    const alloc = x.allocator;
    var buffer = std.ArrayList(u8).init(alloc);
    errdefer buffer.deinit();

    var pos: usize = 0;
    while (pos < path.len) {
        const i = mem.indexOfAnyPos(u8, path, pos, ".[") orelse path.len;

        {
            const field = try name_util.snakeCase(alloc, path[pos..i]);
            defer if (!mem.eql(u8, field, path[pos..i])) alloc.free(field);
            try buffer.appendSlice(field);
        }

        if (i == path.len) break;

        switch (path[i]) {
            '.' => {
                try buffer.append('.');
                pos = i + 1;
            },
            '[' => {
                const end = mem.indexOfScalarPos(u8, path, i + 2, ']').?;
                try buffer.appendSlice(path[i .. end + 1]);
                break;
            },
            else => unreachable,
        }
    }

    return x.fromExpr(val).dot().raw(try buffer.toOwnedSlice()).consume();
}

test "fnGetAttr" {
    try Function.expect(fnGetAttr, &.{
        .{ .reference = "Foo" },
        .{ .string = "[8]" },
    }, "config.foo.?[8]");

    try Function.expect(fnGetAttr, &.{
        .{ .reference = "Foo" },
        .{ .string = "bar.bazQux[8]" },
    }, "config.foo.?.bar.baz_qux[8]");
}

fn fnStringEquals(gen: *Generator, x: ExprBuild, args: []const rls.ArgValue) !Expr {
    const lhs = x.fromExpr(try gen.evalArg(x, args[0]));
    const rhs = x.fromExpr(try gen.evalArg(x, args[1]));
    return x.call("std.mem.eql", &.{ lhs, rhs }).consume();
}

test "fnStringEquals" {
    try Function.expect(fnStringEquals, &.{
        .{ .reference = "Foo" },
        .{ .string = "bar" },
    }, "std.mem.eql(config.foo.?, \"bar\")");
}

fn fnIsValidHostLabel(gen: *Generator, x: ExprBuild, args: []const rls.ArgValue) !Expr {
    const value = try gen.evalArg(x, args[0]);
    const subdomains = try gen.evalArg(x, args[1]);
    return x.call("smithy.url.isValidHostLabel", &.{
        x.fromExpr(value),
        x.fromExpr(subdomains),
    }).consume();
}

test "fnIsValidHostLabel" {
    try Function.expect(fnIsValidHostLabel, &.{
        .{ .string = "foo" },
        .{ .boolean = false },
    }, "smithy.url.isValidHostLabel(\"foo\", false)");
}

fn fnParseUrl(gen: *Generator, x: ExprBuild, args: []const rls.ArgValue) !Expr {
    const value = try gen.evalArg(x, args[0]);
    return x.call("smithy.url.Url.init", &.{ x.id(config.allocator_arg), x.fromExpr(value) })
        .@"catch"().body(x.valueOf(null)).consume();
}

test "fnParseUrl" {
    try Function.expect(fnParseUrl, &.{
        .{ .string = "http://example.com" },
    }, "smithy.url.Url.init(allocator, \"http://example.com\") catch null");
}

fn fnUriEncode(gen: *Generator, x: ExprBuild, args: []const rls.ArgValue) !Expr {
    const value = try gen.evalArg(x, args[0]);
    return x.trys()
        .call("smithy.url.uriEncode", &.{ x.id(config.allocator_arg), x.fromExpr(value) })
        .consume();
}

test "fnUriEncode" {
    try Function.expect(fnUriEncode, &.{
        .{ .string = "foo" },
    }, "try smithy.url.uriEncode(allocator, \"foo\")");
}

fn fnSubstring(gen: *Generator, x: ExprBuild, args: []const rls.ArgValue) !Expr {
    return x.call("smithy.string.substring", &.{
        x.fromExpr(try gen.evalArg(x, args[0])),
        x.fromExpr(try gen.evalArg(x, args[1])),
        x.fromExpr(try gen.evalArg(x, args[2])),
        x.fromExpr(try gen.evalArg(x, args[3])),
    }).@"catch"().body(x.valueOf(null)).consume();
}

test "fnSubstring" {
    try Function.expect(fnSubstring, &.{
        .{ .string = "foo" },
        .{ .integer = 0 },
        .{ .integer = 2 },
        .{ .boolean = false },
    }, "smithy.string.substring(\"foo\", 0, 2, false) catch null");
}
