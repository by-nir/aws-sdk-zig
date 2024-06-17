const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const rls = @import("model.zig");
const symbols = @import("../symbols.zig");
const SmithyId = symbols.SmithyId;
const idHash = symbols.idHash;
const md = @import("../../codegen/md.zig");
const zig = @import("../../codegen/zig.zig");
const Expr = zig.Expr;
const ExprBuild = zig.ExprBuild;
const BlockBuild = zig.BlockBuild;
const ContainerBuild = zig.ContainerBuild;
const name_util = @import("../../utils/names.zig");
const JsonReader = @import("../../utils/JsonReader.zig");

const Self = @This();

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
};

pub const Function = struct {
    args: []const Type,
    returns: Type,
    impl: *const fn (arena: Allocator, bld: *BlockBuild, args: []const rls.ArgValue) anyerror!Expr,

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

        // TODO: Missing types
        pub fn asExpr(self: Type, x: ExprBuild) !Expr {
            return switch (self) {
                .any => error.RulesAnyTypeNotSupported,
                .array => |t| blk: {
                    const item = x.fromExpr(try t.asExpr(x));
                    break :blk x.typeSlice(false, item).consume();
                },
                .boolean => x.typeOf(bool).consume(),
                .empty => x.typeOf(void).consume(),
                .endpoint => return error.RulesTypeNotImplemented,
                .integer => x.typeOf(i32).consume(),
                .optional => |t| blk: {
                    const item = x.fromExpr(try t.asExpr(x));
                    break :blk x.typeOptional(item).consume();
                },
                .record => return error.RulesTypeNotImplemented,
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
            };
        }
    };
};

const INPUT_PARAM = "input";
const PASS_VAL = "did_pass";
const PASS_LABEL = "pass";
const ASSIGN_LABEL = "asgn";

built_ins: std.AutoHashMapUnmanaged(rls.RulesBuiltInId, BuiltIn) = .{},
functions: std.AutoHashMapUnmanaged(rls.RulesFunctionId, Function) = .{},

pub fn init() Self {
    return .{};
}

pub fn generateInputType(
    _: Self,
    arena: Allocator,
    bld: *ContainerBuild,
    name: []const u8,
    params: []const rls.StringKV(rls.Parameter),
) !void {
    const context = .{ .arena = arena, .params = params };
    try bld.constant(name).assign(bld.x.@"struct"().bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
            for (ctx.params) |pair| {
                const param = pair.value;
                const field_name = try name_util.snakeCase(ctx.arena, pair.key);

                var typing: ExprBuild = undefined;
                var default: ?ExprBuild = null;
                switch (param.type) {
                    .string => |d| {
                        typing = b.x.typeOf([]const u8);
                        if (d) |t| default = b.x.valueOf(t);
                    },
                    .boolean => |d| {
                        typing = b.x.typeOf(bool);
                        if (d) |t| default = b.x.valueOf(t);
                    },
                    .string_array => |d| {
                        typing = b.x.typeOf([]const []const u8);
                        if (d) |t| {
                            const vals = try ctx.arena.alloc(ExprBuild, t.len);
                            for (t, 0..) |v, i| vals[i] = b.x.valueOf(v);
                            default = b.x.structLiteral(null, vals);
                        }
                    },
                }
                const is_required = param.required orelse false;
                if (!is_required and default == null) typing = b.x.typeOptional(typing);

                if (param.documentation.len > 0) {
                    try b.commentMarkdownWith(.doc, md.html.CallbackContext{
                        .allocator = ctx.arena,
                        .html = param.documentation,
                    }, md.html.callback);
                }

                const field = b.field(field_name).typing(typing);
                try if (default) |t| field.assign(t) else field.end();
            }
        }
    }.f));
}

pub fn generateResolveFunc(
    self: Self,
    arena: Allocator,
    bld: *ContainerBuild,
    func_name: []const u8,
    input_type: []const u8,
    rule_set: *const rls.RuleSet,
) !void {
    if (rule_set.rules.len == 0) {
        return error.EmptyRuleSet;
    }

    const context = ResolverCtx{
        .self = self,
        .arena = arena,
        .rules = rule_set.rules,
    };
    try bld.function(func_name)
        .arg(INPUT_PARAM, bld.x.raw(input_type))
        .returns(bld.x.typeOf(anyerror![]const u8))
        .bodyWith(context, resolverBody);
}

const ResolverCtx = struct { self: Self, arena: Allocator, rules: []const rls.Rule };
fn resolverBody(ctx: ResolverCtx, bld: *BlockBuild) !void {
    try bld.variable(PASS_VAL).assign(bld.x.valueOf(false));

    for (ctx.rules) |rule| {
        const condition_ctx = switch (rule) {
            inline else => |t| ConditionCtx{
                .self = ctx.self,
                .arena = ctx.arena,
                .conditions = t.conditions,
            },
        };
        try bld.id(PASS_VAL).assign().label(PASS_LABEL)
            .blockWith(condition_ctx, resolveCondition)
            .end();

        try bld.@"if"(bld.x.id(PASS_VAL)).body(bld.x.blockWith(RuleCtx{
            .self = ctx.self,
            .rule = rule,
        }, generateRule)).end();
    }
}

const ConditionCtx = struct { self: Self, arena: Allocator, conditions: []const rls.Condition };
fn resolveCondition(ctx: ConditionCtx, bld: *BlockBuild) !void {
    // Prepare variables for assignments
    for (ctx.conditions) |cond| {
        const assign = cond.assign orelse continue;
        const var_name = try name_util.snakeCase(ctx.arena, assign);
        const typing = try ctx.self.resolveFuncReturns(bld.x, cond.function);
        try bld.variable(var_name).typing(bld.x.fromExpr(typing)).assign(bld.x.valueOf(null));
    }

    // Evaluate conditions
    for (ctx.conditions) |cond| {
        const fn_id = cond.function;
        const resolved = try ctx.self.resolveFunc(ctx.arena, bld, fn_id, cond.args, cond.assign);
        errdefer resolved.deinit(ctx.arena);

        try bld.@"if"(bld.x.op(.not).group(bld.x.fromExpr(resolved)))
            .body(bld.x.breaks(PASS_LABEL).valueOf(false))
            .end();
    }

    try bld.breaks(PASS_LABEL).valueOf(true).end();
}

const RuleCtx = struct { self: Self, rule: rls.Rule };
fn generateRule(ctx: RuleCtx, bld: *BlockBuild) !void {
    return switch (ctx.rule) {
        .endpoint => |t| ctx.self.generateRuleEndpoint(bld, t),
        .err => |t| ctx.self.generateRuleError(bld, t),
        .tree => |t| ctx.self.generateRuleTree(bld, t),
    };
}

fn generateRuleEndpoint(self: Self, bld: *BlockBuild, rule: rls.EndpointRule) !void {
}

fn generateRuleError(self: Self, bld: *BlockBuild, rule: rls.ErrorRule) !void {
}

fn generateRuleTree(self: Self, bld: *BlockBuild, rule: rls.TreeRule) !void {
}

fn resolveFunc(
    self: Self,
    arena: Allocator,
    bld: *BlockBuild,
    id: rls.RulesFunctionId,
    args: []const rls.ArgValue,
    assign: ?[]const u8,
) !Expr {
    const expr = switch (id) {
        .boolean_equals => blk: {
            const lhs = try self.resolveArg(arena, bld, args[0]);
            const rhs = try self.resolveArg(arena, bld, args[1]);
            break :blk try bld.x.buildExpr(lhs).op(.eql).buildExpr(rhs).consume();
        },
        .is_set => blk: {
            const arg = try self.resolveArg(arena, bld, args[0]);
            break :blk try bld.x.buildExpr(arg).op(.not_eql).valueOf(null).consume();
        },
        .not => try bld.x.op(.not).buildExpr(try self.resolveArg(arena, bld, args[0])).consume(),
        .get_attr => blk: {
            const value = try self.resolveArg(arena, bld, args[0]);
            const path = args[1].string;
            if (path[0] == '[')
                break :blk try bld.x.buildExpr(value).raw(path).consume()
            else
                break :blk try bld.x.buildExpr(value).dot().raw(path).consume();
        },
        .parse_url => {
            // TODO: Used by `cloudfront-keyvaluestore`
            return error.RulesFuncNotImplemented;
        },
        .string_equals => blk: {
            const lhs = try self.resolveArg(arena, bld, args[0]);
            const rhs = try self.resolveArg(arena, bld, args[1]);
            break :blk try bld.x.call("std.mem.eql", &.{ lhs, rhs }).consume();
        },
        .substring, .is_valid_host_label, .uri_encode => {
            // TODO: Missing functions (currently not used by AWS)
            return error.RulesFuncNotImplemented;
        },
        // .substring => blk: {
        //     const str = try self.resolveArg(arena, bld, args[0]);
        //     const from = try self.resolveArg(arena, bld, args[1]);
        //     const to = try self.resolveArg(arena, bld, args[2]);
        //     // const reverse = try self.resolveArg(arena, bld, args[3]);
        //     break :blk try bld.x.buildExpr(str).valRange(from, to).consume();
        // },
        else => {
            const func: Function = self.functions.get(id) orelse return error.RulesFuncUnknown;
            return func.impl(arena, bld, args);
        },
    };
    errdefer expr.deinit(arena);

    if (assign) |s| {
        const var_name = try name_util.snakeCase(arena, s);
        const context = .{ .expr = expr, .var_name = var_name };
        return bld.laebl(ASSIGN_LABEL).blockWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *BlockBuild) !void {
                try b.id(ctx.var_name).assign().fromExpr(ctx.expr).end();
                try b.breaks(ASSIGN_LABEL).id(ctx.var_name).end();
            }
        }.f).consume();
    } else {
        return expr;
    }
}

test "resolveFunc" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const alloc = arena.allocator();
    defer arena.deinit();

    const self = Self{};

    var bld = BlockBuild.init(alloc);
    defer bld.deinit();

    var expr = try self.resolveFunc(alloc, &bld, rls.RulesFunctionId.boolean_equals, &.{
        .{ .boolean = true },
        .{ .boolean = false },
    }, null);
    try expr.expect(alloc, "true == false");

    expr = try self.resolveFunc(alloc, &bld, rls.RulesFunctionId.is_set, &.{
        .{ .reference = "foo" },
    }, null);
    try expr.expect(alloc, "foo != null");

    expr = try self.resolveFunc(alloc, &bld, rls.RulesFunctionId.not, &.{
        .{ .boolean = true },
    }, null);
    try expr.expect(alloc, "!true");

    expr = try self.resolveFunc(alloc, &bld, rls.RulesFunctionId.string_equals, &.{
        .{ .reference = "foo" },
        .{ .string = "bar" },
    }, null);
    try expr.expect(alloc, "std.mem.eql(foo, \"bar\")");

    expr = try self.resolveFunc(alloc, &bld, rls.RulesFunctionId.get_attr, &.{
        .{ .reference = "foo" },
        .{ .string = "[8]" },
    }, null);
    try expr.expect(alloc, "foo[8]");

    expr = try self.resolveFunc(alloc, &bld, rls.RulesFunctionId.get_attr, &.{
        .{ .reference = "foo" },
        .{ .string = "bar.baz[8]" },
    }, null);
    try expr.expect(alloc, "foo.bar.baz[8]");

    // expr = try self.resolveFunc(alloc, &bld, rls.RulesFunctionId.substring, &.{
    //     .{ .reference = "foo" },
    //     .{ .integer = 3 },
    //     .{ .integer = 6 },
    //     .{ .boolean = false },
    // }, null);
    // try expr.expect(alloc, "foo[3..6]");

    expr = try self.resolveFunc(alloc, &bld, rls.RulesFunctionId.is_set, &.{
        .{ .reference = "bar" },
    }, "foo");
    try expr.expect(alloc,
        \\asgn: {
        \\    foo = bar != null;
        \\
        \\    break :asgn foo;
        \\}
    );
}

fn resolveFuncReturns(self: Self, x: ExprBuild, id: rls.RulesFunctionId) !Expr {
    switch (id) {
        .not, .is_set, .boolean_equals, .string_equals, .is_valid_host_label => return x.typeOf(bool).consume(),
        .substring => return x.typeOf([]const u8).consume(),
        .get_attr => return error.RulesCantInferFuncType,
        .parse_url, .uri_encode => {
            // TODO
            return error.RulesFuncNotImplemented;
        },
        else => {
            const func: Function = self.functions.get(id) orelse return error.RulesFuncUnknown;
            return func.returns.asExpr(x);
        },
    }
}

fn resolveArg(self: Self, arena: Allocator, bld: *BlockBuild, arg: rls.ArgValue) anyerror!ExprBuild {
    switch (arg) {
        .string => |t| return bld.x.valueOf(t),
        .boolean => |t| return bld.x.valueOf(t),
        .function => |t| {
            const expr = try self.resolveFunc(arena, bld, t.name, t.args, null);
            return bld.x.fromExpr(expr);
        },
        .reference => |t| {
            const var_name = try name_util.snakeCase(arena, t);
            return bld.x.id(var_name);
        },
        .array => |t| {
            var count: usize = 0;
            const exprs = try arena.alloc(ExprBuild, t.len);
            errdefer {
                for (exprs[0..count]) |p| p.deinit();
                arena.free(exprs);
            }

            for (t, 0..) |p, i| {
                exprs[i] = try self.resolveArg(arena, bld, p);
                count += 1;
            }

            return bld.x.structLiteral(bld.x.raw("&."), exprs);
        },
    }
}

test "resolveArg" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const alloc = arena.allocator();
    defer arena.deinit();

    const self = Self{};
    var bld = BlockBuild.init(test_alloc);
    defer bld.deinit();

    var expr = try self.resolveArg(alloc, &bld, .{ .boolean = true });
    try expr.expect("true");

    expr = try self.resolveArg(alloc, &bld, .{ .string = "foo" });
    try expr.expect("\"foo\"");

    const items: []const rls.ArgValue = &.{ .{ .string = "foo" }, .{ .string = "bar" } };
    expr = try self.resolveArg(alloc, &bld, .{ .array = items });
    try expr.expect("&.{ \"foo\", \"bar\" }");
}
