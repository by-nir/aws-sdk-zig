const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const rls = @import("model.zig");
const lib = @import("library.zig");
const Engine = @import("RulesEngine.zig");
const md = @import("../../codegen/md.zig");
const zig = @import("../../codegen/zig.zig");
const Expr = zig.Expr;
const ExprBuild = zig.ExprBuild;
const BlockBuild = zig.BlockBuild;
const ContainerBuild = zig.ContainerBuild;
const name_util = @import("../../utils/names.zig");

const Self = @This();
const ParamFields = std.StringHashMapUnmanaged(void);
pub const ParamsList = []const rls.StringKV(rls.Parameter);

const INPUT_PARAM = "input";
const CONDIT_VAL = "did_pass";
const CONDIT_LABEL = "pass";
const ASSIGN_LABEL = "asgn";

arena: Allocator,
engine: Engine,
params: ParamsList,
param_names: ParamFields = .{},

pub fn init(arena: Allocator, engine: Engine, params: ParamsList) !Self {
    var names = ParamFields{};
    try names.ensureTotalCapacity(arena, @intCast(params.len));
    for (params) |kv| names.putAssumeCapacity(kv.key, {});

    return .{
        .arena = arena,
        .engine = engine,
        .params = params,
        .param_names = names,
    };
}

pub fn deinit(self: *Self) void {
    self.param_names.deinit(self.arena);
}

pub fn generateInputType(self: Self, bld: *ContainerBuild, name: []const u8) !void {
    try bld.constant(name).assign(bld.x.@"struct"().bodyWith(self, struct {
        fn f(ctx: Self, b: *ContainerBuild) !void {
            for (ctx.params) |kv| {
                const param = kv.value;
                const field_name = try name_util.snakeCase(ctx.arena, kv.key);

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

pub fn generateResolver(
    self: Self,
    bld: *ContainerBuild,
    func_name: []const u8,
    input_type: []const u8,
    rule_set: *const rls.RuleSet,
) !void {
    if (rule_set.rules.len == 0) return error.EmptyRuleSet;

    const context = ResolverCtx{
        .self = self,
        .rules = rule_set.rules,
    };
    try bld.function(func_name)
        .arg(INPUT_PARAM, bld.x.raw(input_type))
        .returns(bld.x.typeOf(anyerror![]const u8))
        .bodyWith(context, generateResolverBody);
}

const ResolverCtx = struct { self: Self, rules: []const rls.Rule };
fn generateResolverBody(ctx: ResolverCtx, bld: *BlockBuild) !void {
    // Track if all conditions passed
    try bld.variable(CONDIT_VAL).assign(bld.x.valueOf(false));

    for (ctx.rules) |rule| {
        const body_ctx = RuleCtx{
            .self = ctx.self,
            .rule = rule,
        };

        const conditions = switch (rule) {
            inline else => |t| t.conditions,
        };

        if (conditions.len == 0) {
            // No conditions, run the rule.
            try generateRule(body_ctx, bld);
        } else {
            // Evaluate conditions
            const cond_ctx = ConditionCtx{
                .self = ctx.self,
                .conditions = conditions,
            };
            try bld.id(CONDIT_VAL).assign().label(CONDIT_LABEL)
                .blockWith(cond_ctx, generateResolverCondition)
                .end();

            // Run the rule
            try bld.@"if"(bld.x.id(CONDIT_VAL))
                .body(bld.x.blockWith(body_ctx, generateRule))
                .end();
        }
    }
}

const ConditionCtx = struct { self: Self, conditions: []const rls.Condition };
fn generateResolverCondition(ctx: ConditionCtx, bld: *BlockBuild) !void {
    const self = ctx.self;

    // Prepare variables for assignments
    for (ctx.conditions) |cond| {
        const assign = cond.assign orelse continue;
        const var_name = try name_util.snakeCase(self.arena, assign);

        const func = try self.engine.getFunc(cond.function);
        const typing = try func.returns.asExpr(bld.x);
        const opt_typ = bld.x.typeOptional(bld.x.fromExpr(typing));

        try bld.variable(var_name).typing(opt_typ).assign(bld.x.valueOf(null));
    }

    // Evaluate conditions
    for (ctx.conditions) |cond| {
        const id = cond.function;
        const expr = try self.evalFunc(bld, id, cond.args, cond.assign);
        errdefer expr.deinit(self.arena);

        try bld.@"if"(bld.x.op(.not).group(bld.x.fromExpr(expr)))
            .body(bld.x.breaks(CONDIT_LABEL).valueOf(false))
            .end();
    }

    try bld.breaks(CONDIT_LABEL).valueOf(true).end();
}

const RuleCtx = struct { self: Self, rule: rls.Rule };
fn generateRule(ctx: RuleCtx, bld: *BlockBuild) !void {
    return switch (ctx.rule) {
        .endpoint => |t| ctx.self.generateRuleEndpoint(bld, t),
        .err => |t| ctx.self.generateRuleError(bld, t),
        .tree => |t| ctx.self.generateRuleTree(bld, t),
    };
}

fn generateRuleError(_: Self, bld: *BlockBuild, rule: rls.ErrorRule) !void {
    const message = switch (rule.message) {
        .string => |s| blk: {
            if (std.mem.indexOfScalar(u8, s, '{')) |i| {
                if (std.mem.indexOfScalarPos(u8, s, i + 1, '}')) |_| {
                    return error.ErrorRuleTemplateNotImplemented;
                }
            }
            break :blk s;
        },
        else => return error.NonStringErrorRuleMessage,
    };

    try bld.call("std.log.err", &.{
        bld.x.valueOf(message), bld.x.structLiteral(null, &.{
        }),
    }).end();
    try bld.returns().valueOf(error.ReachedErrorRule).end();
}

fn generateRuleEndpoint(self: Self, bld: *BlockBuild, rule: rls.EndpointRule) !void {
    _ = bld; // autofix
    _ = self; // autofix
    _ = rule; // autofix
}

fn generateRuleTree(self: Self, bld: *BlockBuild, rule: rls.TreeRule) !void {
    _ = bld; // autofix
    _ = self; // autofix
    _ = rule; // autofix
}

pub fn evalFunc(
    self: Self,
    bld: *BlockBuild,
    id: lib.Function.Id,
    args: []const rls.ArgValue,
    assign: ?[]const u8,
) !Expr {
    const func = try self.engine.getFunc(id);
    const expr = try func.genFn(self, bld, args);
    errdefer expr.deinit(self.arena);

    const asgn = assign orelse return expr;
    const var_name = try name_util.snakeCase(self.arena, asgn);

    const context = .{ .expr = expr, .var_name = var_name };
    return bld.laebl(ASSIGN_LABEL).blockWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *BlockBuild) !void {
            try b.id(ctx.var_name).assign().fromExpr(ctx.expr).end();
            try b.breaks(ASSIGN_LABEL).id(ctx.var_name).end();
        }
    }.f).consume();
}

test "evalFunc" {
    var tst = try Tester.init();
    defer tst.deinit();

    var expr = try tst.gen.evalFunc(tst.bld, lib.Function.Id.is_set, &.{
        .{ .reference = "foo" },
    }, null);
    try expr.expect(tst.alloc(), "foo != null");

    expr = try tst.gen.evalFunc(tst.bld, lib.Function.Id.is_set, &.{
        .{ .reference = "bar" },
    }, "foo");
    try expr.expect(tst.alloc(),
        \\asgn: {
        \\    foo = bar != null;
        \\
        \\    break :asgn foo;
        \\}
    );
}

pub fn evalArg(self: Self, bld: *BlockBuild, arg: rls.ArgValue) anyerror!Expr {
    const expr = try self.evalArgRaw(bld, arg);
    switch (arg) {
        .reference => |s| {
            if (self.param_names.contains(s)) {
                return expr;
            } else {
                return bld.x.fromExpr(expr).unwrap().consume();
            }
        },
        else => return expr,
    }
}

pub fn evalArgRaw(self: Self, bld: *BlockBuild, arg: rls.ArgValue) anyerror!Expr {
    switch (arg) {
        .string => |t| return bld.x.valueOf(t).consume(),
        .boolean => |t| return bld.x.valueOf(t).consume(),
        .function => |t| return self.evalFunc(bld, t.name, t.args, null),
        .reference => |s| {
            const var_name = try name_util.snakeCase(self.arena, s);
            if (self.param_names.contains(s)) {
                return bld.x.id(INPUT_PARAM).dot().id(var_name).consume();
            } else {
                return bld.x.id(var_name).consume();
            }
        },
        .array => |t| {
            var count: usize = 0;
            const exprs = try self.arena.alloc(ExprBuild, t.len);
            errdefer {
                for (exprs[0..count]) |p| p.deinit();
                self.arena.free(exprs);
            }

            for (t, 0..) |a, i| {
                exprs[i] = bld.x.fromExpr(try self.evalArg(bld, a));
                count += 1;
            }

            return bld.x.addressOf().structLiteral(null, exprs).consume();
        },
    }
}

test "evalArg" {
    var tst = try Tester.init();
    defer tst.deinit();

    var expr = try tst.gen.evalArg(tst.bld, .{ .boolean = true });
    try expr.expect(tst.alloc(), "true");

    expr = try tst.gen.evalArg(tst.bld, .{ .string = "foo" });
    try expr.expect(tst.alloc(), "\"foo\"");

    const items: []const rls.ArgValue = &.{ .{ .string = "foo" }, .{ .string = "bar" } };
    expr = try tst.gen.evalArg(tst.bld, .{
        .array = items,
    });
    try expr.expect(tst.alloc(), "&.{ \"foo\", \"bar\" }");

    expr = try tst.gen.evalArg(tst.bld, .{ .reference = "Foo" });
    try expr.expect(tst.alloc(), "foo.?");

    expr = try tst.gen.evalArg(tst.bld, .{ .reference = "Param" });
    try expr.expect(tst.alloc(), "input.param");
}

pub const Tester = struct {
    arena: *std.heap.ArenaAllocator,
    engine: Engine,
    gen: Self,
    bld: *BlockBuild,

    pub fn init() !Tester {
        const arena = try test_alloc.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(test_alloc);
        const arena_alloc = arena.allocator();
        errdefer {
            arena.deinit();
            test_alloc.destroy(arena);
        }

        var engine = try Engine.init(test_alloc, &.{}, &.{});
        errdefer engine.deinit(test_alloc);

        var gen = try Self.init(arena_alloc, engine, &.{
            .{ .key = "Param", .value = undefined },
        });
        errdefer gen.deinit();

        const bld = try test_alloc.create(BlockBuild);
        bld.* = BlockBuild.init(arena_alloc);

        return .{
            .arena = arena,
            .engine = engine,
            .gen = gen,
            .bld = bld,
        };
    }

    pub fn deinit(self: *Tester) void {
        self.bld.deinit();
        self.gen.deinit();
        self.engine.deinit(test_alloc);
        self.arena.deinit();

        test_alloc.destroy(self.bld);
        test_alloc.destroy(self.arena);
    }

    pub fn alloc(self: Tester) Allocator {
        return self.arena.allocator();
    }
};
