const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
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
const Writer = @import("../../codegen/CodegenWriter.zig");
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

test "generateInputType" {
    var tst = try Tester.init();
    defer tst.deinit();

    try generateInputType(tst.gen, tst.container(), "Input");

    try tst.expect(
        \\const Input = struct {
        \\    /// Some param...
        \\    param: ?[]const u8,
        \\};
    );
}

pub fn generateResolver(
    self: Self,
    bld: *ContainerBuild,
    func_name: []const u8,
    input_type: []const u8,
    rule_set: *const rls.RuleSet,
) !void {
    if (rule_set.rules.len == 0) return error.EmptyRuleSet;

    // TODO: Somehow, in runtime we need to fallback to built-in if no value is set;
    // generate a function for resolverParams that returns input, if not provided a value fallback to built-in and then default;

    const context = .{ .self = self, .rules = rule_set.rules };
    try bld.function(func_name)
        .arg(INPUT_PARAM, bld.x.raw(input_type))
        .returns(bld.x.typeOf(anyerror![]const u8))
        .bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *BlockBuild) !void {
            try b.variable(CONDIT_VAL).assign(b.x.valueOf(false));
            try ctx.self.generateResolverRules(b, ctx.rules);
        }
    }.f);
}

test "generateResolver" {
    var tst = try Tester.init();
    defer tst.deinit();

    try generateResolver(tst.gen, tst.container(), "resolve", "Input", &.{
        .parameters = &.{},
        .rules = &[_]rls.Rule{
            .{ .err = .{ .message = .{ .string = "baz" } } },
        },
    });

    try tst.expect(
        \\fn resolve(input: Input) anyerror![]const u8 {
        \\    var did_pass = false;
        \\
        \\    std.log.err("baz", .{});
        \\
        \\    return error.ReachedErrorRule;
        \\}
    );
}

// const RulesCtx = struct { self: Self, rules: []const rls.Rule };
fn generateResolverRules(self: Self, bld: *BlockBuild, rules: []const rls.Rule) !void {
    for (rules) |rule| {
        const body_ctx = RuleCtx{
            .self = self,
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
                .self = self,
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

test "generateResolverRules" {
    var tst = try Tester.init();
    defer tst.deinit();

    try generateResolverRules(tst.gen, tst.block(), &[_]rls.Rule{
        .{ .err = .{
            .conditions = &[_]rls.Condition{.{
                .function = lib.Function.Id.not,
                .args = &.{.{ .reference = "foo" }},
            }},
            .message = .{ .string = "bar" },
        } },
        .{ .err = .{ .message = .{ .string = "baz" } } },
    });

    try tst.expect(
        \\{
        \\    did_pass = pass: {
        \\        if (!(!foo.?)) break :pass false;
        \\
        \\        break :pass true;
        \\    };
        \\
        \\    if (did_pass) {
        \\        std.log.err("bar", .{});
        \\
        \\        return error.ReachedErrorRule;
        \\    }
        \\
        \\    std.log.err("baz", .{});
        \\
        \\    return error.ReachedErrorRule;
        \\}
    );
}

const ConditionCtx = struct { self: Self, conditions: []const rls.Condition };
fn generateResolverCondition(ctx: ConditionCtx, bld: *BlockBuild) !void {
    const self = ctx.self;

    // Prepare variables for assignments
    for (ctx.conditions) |cond| {
        const assign = cond.assign orelse continue;
        const var_name = try name_util.snakeCase(self.arena, assign);

        const func = try self.engine.getFunc(cond.function);
        const typing = func.returns orelse return error.RulesFuncReturnsAny;
        const wrap = switch (typing) {
            .raw => |s| s[0] != '?',
            .type => |t| t != .optional,
            else => true,
        };
        const opt_typ = if (wrap) bld.x.typeOptional(bld.x.fromExpr(typing)) else bld.x.fromExpr(typing);

        try bld.variable(var_name).typing(opt_typ).assign(bld.x.valueOf(null));
    }

    // Evaluate conditions
    for (ctx.conditions) |cond| {
        const id = cond.function;
        const expr = try self.evalFunc(bld.x, id, cond.args, cond.assign);
        errdefer expr.deinit(self.arena);

        try bld.@"if"(bld.x.op(.not).group(bld.x.fromExpr(expr)))
            .body(bld.x.breaks(CONDIT_LABEL).valueOf(false))
            .end();
    }

    try bld.breaks(CONDIT_LABEL).valueOf(true).end();
}

test "generateResolverCondition" {
    var tst = try Tester.init();
    defer tst.deinit();

    try generateResolverCondition(.{
        .self = tst.gen,
        .conditions = &[_]rls.Condition{
            .{
                .function = lib.Function.Id.not,
                .args = &.{.{ .reference = "bar" }},
            },
            .{
                .function = lib.Function.Id.not,
                .args = &.{.{ .reference = "baz" }},
                .assign = "foo",
            },
        },
    }, tst.block());

    try tst.expect(
        \\{
        \\    var foo: ?bool = null;
        \\
        \\    if (!(!bar.?)) break :pass false;
        \\
        \\    if (!(asgn: {
        \\        foo = !baz.?;
        \\
        \\        break :asgn foo;
        \\    })) break :pass false;
        \\
        \\    break :pass true;
        \\}
    );
}

const RuleCtx = struct { self: Self, rule: rls.Rule };
fn generateRule(ctx: RuleCtx, bld: *BlockBuild) !void {
    return switch (ctx.rule) {
        .endpoint => |endpoint| ctx.self.generateEndpointRule(bld, endpoint),
        .err => |err| ctx.self.generateErrorRule(bld, err),
        .tree => |tree| ctx.self.generateResolverRules(bld, tree.rules),
    };
}

fn generateErrorRule(self: Self, bld: *BlockBuild, rule: rls.ErrorRule) !void {
    const template = try self.evalTemplateString(bld.x, rule.message);
    try bld.call("std.log.err", &.{
        bld.x.fromExpr(template.format),
        bld.x.fromExpr(template.args),
    }).end();
    try bld.returns().valueOf(error.ReachedErrorRule).end();
}

test "generateErrorRule" {
    var tst = try Tester.init();
    defer tst.deinit();

    try tst.gen.generateErrorRule(tst.block(), .{
        .message = .{ .string = "foo" },
    });

    try tst.expect(
        \\{
        \\    std.log.err("foo", .{});
        \\
        \\    return error.ReachedErrorRule;
        \\}
    );
}

// TODO: Codegen properties, headers, authShemas
fn generateEndpointRule(self: Self, bld: *BlockBuild, rule: rls.EndpointRule) !void {
    const template = try self.evalTemplateString(bld.x, rule.endpoint.url);
    try bld.returns().call("std.fmt.allocPrint", &.{
        bld.x.raw("undefined"), // TODO
        bld.x.fromExpr(template.format),
        bld.x.fromExpr(template.args),
    }).end();
}

test "generateEndpointRule" {
    var tst = try Tester.init();
    defer tst.deinit();

    try tst.gen.generateEndpointRule(tst.block(), .{
        .endpoint = .{ .url = .{ .string = "https://{linkId}.service.com" } },
    });

    try tst.expect(
        \\{
        \\    return std.fmt.allocPrint(undefined, "https://{s}.service.com", .{link_id.?});
        \\}
    );
}

const TemplateString = struct { format: Expr, args: Expr };
fn evalTemplateString(self: Self, x: ExprBuild, template: rls.StringValue) !TemplateString {
    const arg = switch (template) {
        .string => |s| {
            var format = std.ArrayList(u8).init(self.arena);
            errdefer format.deinit();

            var args = std.ArrayList(ExprBuild).init(self.arena);
            errdefer args.deinit();

            var pos: usize = 0;
            while (pos < s.len) {
                const start = mem.indexOfScalarPos(u8, s, pos, '{') orelse {
                    if (args.items.len > 0) try format.appendSlice(s[pos..s.len]);
                    break;
                };

                const end = mem.indexOfAnyPos(u8, s, start + 1, "{}" ++ &std.ascii.whitespace) orelse {
                    try format.append('{');
                    pos += 1;
                    continue;
                };

                if (s[end] != '}') {
                    pos += 1;
                    continue;
                }

                try format.appendSlice(s[pos..start]);
                try format.appendSlice("{s}");

                const ref = s[start + 1 .. end];
                const expr = if (mem.indexOfScalar(u8, ref, '#')) |split|
                    try self.evalFunc(x, lib.Function.Id.get_attr, &.{
                        .{ .reference = ref[0..split] },
                        .{ .string = ref[split + 1 .. ref.len] },
                    }, null)
                else
                    try self.evalArg(x, .{ .reference = ref });

                try args.append(x.fromExpr(expr));
                pos = end + 1;
            }

            return if (args.items.len > 0) .{
                .format = try x.valueOf(try format.toOwnedSlice()).consume(),
                .args = try x.structLiteral(null, try args.toOwnedSlice()).consume(),
            } else .{
                .format = try x.valueOf(s).consume(),
                .args = Expr{ .value = .{ .@"struct" = .{ .identifier = null, .values = &.{} } } },
            };
        },
        .reference => |ref| try self.evalArg(x, .{ .reference = ref }),
        .function => |func| try self.evalFunc(x, func.id, func.args, null),
    };

    return .{
        .format = try x.valueOf("{s}").consume(),
        .args = try x.structLiteral(null, &.{x.fromExpr(arg)}).consume(),
    };
}

test "evalTemplateString" {
    var tst = try Tester.init();
    defer tst.deinit();

    var template = try tst.gen.evalTemplateString(tst.x, .{
        .reference = "foo",
    });
    try template.format.expect(tst.alloc, "\"{s}\"");
    try template.args.expect(tst.alloc, ".{foo.?}");

    template = try tst.gen.evalTemplateString(tst.x, .{
        .function = .{
            .id = lib.Function.Id.get_attr,
            .args = &.{
                .{ .reference = "foo" },
                .{ .string = "bar" },
            },
        },
    });
    try template.format.expect(tst.alloc, "\"{s}\"");
    try template.args.expect(tst.alloc, ".{foo.?.bar}");

    template = try tst.gen.evalTemplateString(tst.x, .{
        .string = "foo",
    });
    try template.format.expect(tst.alloc, "\"foo\"");
    try template.args.expect(tst.alloc, ".{}");

    template = try tst.gen.evalTemplateString(tst.x, .{
        .string = "{Param}foo{bar#baz}",
    });
    try template.format.expect(tst.alloc, "\"{s}foo{s}\"");
    try template.args.expect(tst.alloc, ".{ input.param, bar.?.baz }");
}

pub fn evalFunc(
    self: Self,
    x: ExprBuild,
    id: lib.Function.Id,
    args: []const rls.ArgValue,
    assign: ?[]const u8,
) !Expr {
    const func = try self.engine.getFunc(id);
    const expr = try func.genFn(self, x, args);
    errdefer expr.deinit(self.arena);

    const asgn = assign orelse return expr;
    const var_name = try name_util.snakeCase(self.arena, asgn);

    const context = .{ .expr = expr, .var_name = var_name };
    return x.label(ASSIGN_LABEL).blockWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *BlockBuild) !void {
            try b.id(ctx.var_name).assign().fromExpr(ctx.expr).end();
            try b.breaks(ASSIGN_LABEL).id(ctx.var_name).end();
        }
    }.f).consume();
}

test "evalFunc" {
    var tst = try Tester.init();
    defer tst.deinit();

    var expr = try tst.gen.evalFunc(tst.x, lib.Function.Id.is_set, &.{
        .{ .reference = "foo" },
    }, null);
    try expr.expect(tst.alloc, "foo != null");

    expr = try tst.gen.evalFunc(tst.x, lib.Function.Id.is_set, &.{
        .{ .reference = "bar" },
    }, "foo");
    try expr.expect(tst.alloc,
        \\asgn: {
        \\    foo = bar != null;
        \\
        \\    break :asgn foo;
        \\}
    );
}

pub fn evalArg(self: Self, x: ExprBuild, arg: rls.ArgValue) anyerror!Expr {
    const expr = try self.evalArgRaw(x, arg);
    switch (arg) {
        .reference => |s| {
            if (self.param_names.contains(s)) {
                return expr;
            } else {
                return x.fromExpr(expr).unwrap().consume();
            }
        },
        else => return expr,
    }
}

pub fn evalArgRaw(self: Self, x: ExprBuild, arg: rls.ArgValue) anyerror!Expr {
    switch (arg) {
        .string => |t| return x.valueOf(t).consume(),
        .boolean => |t| return x.valueOf(t).consume(),
        .function => |t| return self.evalFunc(x, t.id, t.args, null),
        .reference => |s| {
            const var_name = try name_util.snakeCase(self.arena, s);
            if (self.param_names.contains(s)) {
                return x.id(INPUT_PARAM).dot().id(var_name).consume();
            } else {
                return x.id(var_name).consume();
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
                exprs[i] = x.fromExpr(try self.evalArg(x, a));
                count += 1;
            }

            return x.addressOf().structLiteral(null, exprs).consume();
        },
    }
}

test "evalArg" {
    var tst = try Tester.init();
    defer tst.deinit();

    var expr = try tst.gen.evalArg(tst.x, .{ .boolean = true });
    try expr.expect(tst.alloc, "true");

    expr = try tst.gen.evalArg(tst.x, .{ .string = "foo" });
    try expr.expect(tst.alloc, "\"foo\"");

    const items: []const rls.ArgValue = &.{ .{ .string = "foo" }, .{ .string = "bar" } };
    expr = try tst.gen.evalArg(tst.x, .{
        .array = items,
    });
    try expr.expect(tst.alloc, "&.{ \"foo\", \"bar\" }");

    expr = try tst.gen.evalArg(tst.x, .{ .reference = "Foo" });
    try expr.expect(tst.alloc, "foo.?");

    expr = try tst.gen.evalArg(tst.x, .{ .reference = "Param" });
    try expr.expect(tst.alloc, "input.param");
}

pub const Tester = struct {
    arena: *std.heap.ArenaAllocator,
    alloc: Allocator,
    engine: Engine,
    gen: Self,
    x: ExprBuild,
    bld: Builder = .none,

    pub const Builder = union(enum) {
        none,
        block: BlockBuild,
        container: ContainerBuild,
    };

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

        var gen = try Self.init(arena_alloc, engine, &.{.{
            .key = "Param",
            .value = rls.Parameter{
                .type = .{ .string = null },
                .documentation = "Some param...",
            },
        }});
        errdefer gen.deinit();

        return .{
            .arena = arena,
            .alloc = arena_alloc,
            .engine = engine,
            .gen = gen,
            .x = ExprBuild{ .allocator = arena_alloc },
        };
    }

    pub fn deinit(self: *Tester) void {
        switch (self.bld) {
            .none => {},
            .block => |*bld| bld.deinit(),
            .container => |*bld| bld.deinit(),
        }

        self.gen.deinit();
        self.engine.deinit(test_alloc);
        self.arena.deinit();
        test_alloc.destroy(self.arena);
    }

    pub fn block(self: *Tester) *BlockBuild {
        std.debug.assert(self.bld == .none);
        self.bld = .{ .block = BlockBuild.init(self.arena.allocator()) };
        return &self.bld.block;
    }

    pub fn container(self: *Tester) *ContainerBuild {
        std.debug.assert(self.bld == .none);
        self.bld = .{ .container = ContainerBuild.init(self.arena.allocator()) };
        return &self.bld.container;
    }

    pub fn expect(self: *Tester, expected: []const u8) !void {
        defer self.bld = .none;
        switch (self.bld) {
            .none => unreachable,
            inline else => |*bld| {
                const data = try bld.consume();
                defer data.deinit(self.arena.allocator());
                try Writer.expectValue(expected, data);
            },
        }
    }
};
