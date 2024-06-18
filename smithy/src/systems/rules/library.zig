const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = std.testing.allocator;
const rls = @import("model.zig");
const Generator = @import("Generator.zig");
const symbols = @import("../symbols.zig");
const idHash = symbols.idHash;
const zig = @import("../../codegen/zig.zig");
const Expr = zig.Expr;
const ExprBuild = zig.ExprBuild;
const BlockBuild = zig.BlockBuild;
const ContainerBuild = zig.ContainerBuild;

pub fn Registry(comptime T: type) type {
    return []const struct { T.Id, T };
}

pub const BuiltInsRegistry = Registry(BuiltIn);
pub const FunctionsRegistry = Registry(Function);

pub const BuiltIn = struct {
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
};

pub const Function = struct {
    returns: Type,
    genFn: GenFn,

    pub const GenFn = *const fn (gen: Generator, bld: *BlockBuild, args: []const rls.ArgValue) anyerror!Expr;

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

    /// [Reference](https://github.com/smithy-lang/smithy/blob/main/smithy-rules-engine/src/main/java/software/amazon/smithy/rulesengine/language/evaluation/type/Type.java)
    pub const Type = union(enum) {
        any,
        array: *const Type,
        boolean,
        empty,
        endpoint,
        integer,
        optional: *const Type,
        record: []const rls.StringKV(Type),
        string,
        tuple: []const Type,

        pub fn asExpr(self: Type, x: ExprBuild) !Expr {
            return switch (self) {
                .any => error.RulesAnyTypeNotSupported,
                .array => |t| blk: {
                    const item = x.fromExpr(try t.asExpr(x));
                    break :blk x.typeSlice(false, item).consume();
                },
                .boolean => x.typeOf(bool).consume(),
                .empty => x.typeOf(void).consume(),
                .integer => x.typeOf(i32).consume(),
                .optional => |t| blk: {
                    const item = try t.asExpr(x);
                    break :blk x.typeOptional(x.fromExpr(item)).consume();
                },
                .string => x.typeOf([]const u8).consume(),
                .tuple => |t| blk: {
                    break :blk x.@"struct"().bodyWith(t, struct {
                        fn f(ctx: @TypeOf(t), b: *ContainerBuild) !void {
                            for (ctx) |member| {
                                const item = b.x.fromExpr(try member.asExpr(b.x));
                                try b.field(null).typing(item).end();
                            }
                        }
                    }.f).consume();
                },
                else => error.RulesTypeNotImplemented,
            };
        }
    };

    pub fn expect(impl: GenFn, args: []const rls.ArgValue, expected: []const u8) !void {
        var tst = try Generator.Tester.init();
        defer tst.deinit();

        var expr = try impl(tst.gen, tst.bld, args);
        try expr.expect(tst.alloc(), expected);
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
    .{ Function.Id.get_attr, Function{ .returns = .any, .genFn = fnGetAttr } },
    .{ Function.Id.not, Function{ .returns = .boolean, .genFn = fnNot } },
    .{ Function.Id.is_set, Function{ .returns = .boolean, .genFn = fnIsSet } },
    .{ Function.Id.boolean_equals, Function{ .returns = .boolean, .genFn = fnBooleanEquals } },
    .{ Function.Id.string_equals, Function{ .returns = .boolean, .genFn = fnStringEquals } },
    .{ Function.Id.is_valid_host_label, Function{ .returns = .boolean, .genFn = fnNotImplemented } },
    .{ Function.Id.parse_url, Function{ .returns = .{ .optional = &.any }, .genFn = fnNotImplemented } },
    .{ Function.Id.substring, Function{ .returns = .{ .optional = &.string }, .genFn = fnNotImplemented } },
    .{ Function.Id.uri_encode, Function{ .returns = .string, .genFn = fnNotImplemented } },
};

fn fnBooleanEquals(gen: Generator, bld: *BlockBuild, args: []const rls.ArgValue) !Expr {
    const lhs = try gen.evalArg(bld, args[0]);
    const rhs = try gen.evalArg(bld, args[1]);
    return bld.x.fromExpr(lhs).op(.eql).fromExpr(rhs).consume();
}

test "fnBooleanEquals" {
    try Function.expect(fnBooleanEquals, &.{
        .{ .boolean = true },
        .{ .boolean = false },
    }, "true == false");
}

fn fnIsSet(gen: Generator, bld: *BlockBuild, args: []const rls.ArgValue) !Expr {
    const arg = try gen.evalArgRaw(bld, args[0]);
    return bld.x.fromExpr(arg).op(.not_eql).valueOf(null).consume();
}

test "fnIsSet" {
    try Function.expect(fnIsSet, &.{.{ .reference = "foo" }}, "foo != null");
}

fn fnNot(gen: Generator, bld: *BlockBuild, args: []const rls.ArgValue) !Expr {
    const arg = try gen.evalArg(bld, args[0]);
    return bld.x.op(.not).fromExpr(arg).consume();
}

test "fnNot" {
    try Function.expect(fnNot, &.{.{ .boolean = true }}, "!true");
}

fn fnGetAttr(gen: Generator, bld: *BlockBuild, args: []const rls.ArgValue) !Expr {
    const val = try gen.evalArg(bld, args[0]);
    const path = args[1].string;
    const base = if (path[0] == '[') bld.x.fromExpr(val) else bld.x.fromExpr(val).dot();
    return base.raw(path).consume();
}

test "fnGetAttr" {
    try Function.expect(fnGetAttr, &.{
        .{ .reference = "foo" },
        .{ .string = "[8]" },
    }, "foo.?[8]");

    try Function.expect(fnGetAttr, &.{
        .{ .reference = "foo" },
        .{ .string = "bar.baz[8]" },
    }, "foo.?.bar.baz[8]");
}

fn fnStringEquals(gen: Generator, bld: *BlockBuild, args: []const rls.ArgValue) !Expr {
    const lhs = bld.x.fromExpr(try gen.evalArg(bld, args[0]));
    const rhs = bld.x.fromExpr(try gen.evalArg(bld, args[1]));
    return bld.x.call("std.mem.eql", &.{ lhs, rhs }).consume();
}

test "fnStringEquals" {
    try Function.expect(fnStringEquals, &.{
        .{ .reference = "foo" },
        .{ .string = "bar" },
    }, "std.mem.eql(foo.?, \"bar\")");
}

fn fnNotImplemented(_: Generator, _: *BlockBuild, _: []const rls.ArgValue) !Expr {
    // TODO
    return error.RulesFuncNotImplemented;
}

// fn fnSubstring
// const str = try self.evalArg(arena, bld, args[0], params);
// const from = try self.evalArg(arena, bld, args[1], params);
// const to = try self.evalArg(arena, bld, args[2], params);
// // const reverse = try self.evalArg(arena, bld, args[3], params);
// return bld.x.buildExpr(str).valRange(from, to).consume();
