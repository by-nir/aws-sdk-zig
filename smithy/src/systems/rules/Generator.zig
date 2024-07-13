const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const mdl = @import("model.zig");
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
const config = @import("../../config.zig");

const ARG_CONFIG = "config";
const CONDIT_VAL = "did_pass";
const CONDIT_LABEL = "pass";
const ASSIGN_LABEL = "asgn";

const Self = @This();
pub const ParamsList = []const mdl.StringKV(mdl.Parameter);

const FieldsMap = std.StringHashMapUnmanaged(Field);
const Field = struct {
    name: []const u8,
    is_direct: bool,
    is_optional: bool,

    pub fn deinit(self: Field, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

arena: Allocator,
engine: Engine,
params: ParamsList,
fields: FieldsMap = .{},

pub fn init(arena: Allocator, engine: Engine, params: ParamsList) !Self {
    var fields = FieldsMap{};
    try fields.ensureTotalCapacity(arena, @intCast(params.len));

    for (params) |kv| {
        const param = kv.value;
        const builtin = if (param.built_in) |id| try engine.getBuiltIn(id) else null;
        const is_direct = !param.type.hasDefault() and (builtin == null or builtin.?.genFn == null);

        fields.putAssumeCapacity(kv.key, .{
            .is_direct = is_direct,
            .is_optional = !param.required,
            .name = if (is_direct) blk: {
                const name = try name_util.snakeCase(arena, kv.key);
                defer arena.free(name);
                break :blk try std.fmt.allocPrint(arena, ARG_CONFIG ++ ".{}", .{std.zig.fmtId(name)});
            } else blk: {
                break :blk try std.fmt.allocPrint(arena, "param_{s}", .{name_util.SnakeCase{ .value = kv.key }});
            },
        });
    }

    return .{
        .arena = arena,
        .engine = engine,
        .params = params,
        .fields = fields,
    };
}

pub fn generateParametersFields(self: *Self, bld: *ContainerBuild) !void {
    for (self.params) |kv| {
        const param = kv.value;
        const param_name = kv.key;

        const typing: ExprBuild = switch (param.type) {
            .string => bld.x.typeOf([]const u8),
            .boolean => bld.x.typeOf(bool),
            .string_array => bld.x.typeOf([]const []const u8),
        };

        if (param.documentation.len > 0) {
            try bld.commentMarkdownWith(.doc, md.html.CallbackContext{
                .allocator = self.arena,
                .html = param.documentation,
            }, md.html.callback);
        }

        const field = self.fields.get(kv.key).?;
        const base = bld.field(try name_util.snakeCase(self.arena, param_name));
        if (field.is_optional or !field.is_direct) {
            try base.typing(bld.x.typeOptional(typing)).assign(bld.x.valueOf(null));
        } else {
            try base.typing(typing).end();
        }
    }
}

test "generateParametersFields" {
    var tst = try Tester.init();
    defer tst.deinit();

    try generateParametersFields(tst.gen, tst.container());
    try tst.expect(
        \\/// Optional
        \\foo: ?[]const u8 = null,
        \\/// Required
        \\bar: bool,
        \\/// Required with default
        \\baz: ?bool = null,
    );
}

// https://github.com/awslabs/aws-c-sdkutils/blob/main/source/endpoints_rule_engine.c
pub fn generateResolver(
    self: *Self,
    bld: *ContainerBuild,
    func_name: []const u8,
    config_type: []const u8,
    rules: []const mdl.Rule,
) !void {
    if (rules.len == 0) return error.EmptyRuleSet;

    const context = .{ .self = self, .rules = rules };
    try bld.public().function(func_name)
        .arg(config.allocator_arg, bld.x.id("Allocator"))
        .arg(ARG_CONFIG, bld.x.raw(config_type))
        .returns(bld.x.typeOf(anyerror![]const u8))
        .bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *BlockBuild) !void {
            for (ctx.self.params) |kv| {
                const field = ctx.self.fields.get(kv.key).?;
                if (field.is_direct) continue;
                try ctx.self.generateParamBinding(b, field.name, kv.key, kv.value);
            }

            try b.variable(CONDIT_VAL).assign(b.x.valueOf(false));
            try ctx.self.generateResolverRules(b, ctx.rules);
        }
    }.f);
}

test "generateResolver" {
    var tst = try Tester.init();
    defer tst.deinit();

    try generateResolver(tst.gen, tst.container(), "resolve", "Config", &[_]mdl.Rule{
        .{ .err = .{ .message = .{ .string = "baz" } } },
    });

    try tst.expect(
        \\pub fn resolve(allocator: Allocator, config: Config) anyerror![]const u8 {
        \\    const param_baz: bool = config.baz orelse true;
        \\
        \\    var did_pass = false;
        \\
        \\    if (!IS_TEST) std.log.err("baz", .{});
        \\
        \\    return error.ReachedErrorRule;
        \\}
    );
}

// TODO: Implement traits bindings
fn generateParamBinding(
    self: Self,
    bld: *BlockBuild,
    field_name: []const u8,
    source_name: []const u8,
    param: mdl.Parameter,
) !void {
    var builtin_eval: ?Expr = null;
    var typ: mdl.ParamValue = param.type;
    if (param.built_in) |id| {
        const built_in = try self.engine.getBuiltIn(id);
        typ = built_in.type;
        if (built_in.genFn) |hook| {
            builtin_eval = try hook(self, bld.x);
        }
    }

    var typing: ExprBuild = undefined;
    var default: ?ExprBuild = null;
    switch (typ) {
        .boolean => |dflt| {
            typing = bld.x.typeOf(bool);
            if (dflt) |b| default = bld.x.valueOf(b);
        },
        .string => |dflt| {
            typing = bld.x.typeOf([]const u8);
            if (dflt) |s| default = bld.x.valueOf(s);
        },
        .string_array => |dflt| {
            typing = bld.x.typeOf([]const []const u8);
            if (dflt) |t| {
                const vals = try self.arena.alloc(ExprBuild, t.len);
                for (t, 0..) |v, i| vals[i] = bld.x.valueOf(v);
                default = bld.x.structLiteral(null, vals);
            }
        },
    }
    if (!param.required) typing = bld.x.typeOptional(typing);

    const val_1 = bld.x.raw(ARG_CONFIG).dot().id(try name_util.snakeCase(self.arena, source_name));
    const val_2 = if (builtin_eval) |eval| val_1.orElse().fromExpr(eval) else val_1;
    const val_3 = if (default) |t| val_2.orElse().buildExpr(t) else blk: {
        if (param.required and builtin_eval == null) return error.RulesRequiredParamHasNoValue;
        break :blk val_2;
    };

    try bld.constant(field_name).typing(typing).assign(val_3);
}

test "generateParamBinding" {
    var tst = try Tester.init();
    defer tst.deinit();

    try tst.gen.generateParamBinding(tst.block(), "foo", "Foo", .{
        .type = .{ .boolean = null },
        .documentation = "",
    });

    try tst.gen.generateParamBinding(tst.block(), "bar", "BarBaz", .{
        .type = .{ .boolean = true },
        .required = true,
        .documentation = "",
    });

    try tst.expect(
        \\{
        \\    const foo: ?bool = config.foo;
        \\
        \\    const bar: bool = config.bar_baz orelse true;
        \\}
    );
}

// const RulesCtx = struct { self: Self, rules: []const rls.Rule };
fn generateResolverRules(self: *Self, bld: *BlockBuild, rules: []const mdl.Rule) !void {
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
            // Prepare variables for assignments
            for (conditions) |cond| {
                const assign = cond.assign orelse continue;
                const var_name = try name_util.snakeCase(self.arena, assign);

                const func = try self.engine.getFunc(cond.function);
                const typing = func.returns orelse return error.RulesFuncReturnsAny;
                const wrap = !func.returns_optional or switch (typing) {
                    .raw => |s| s[0] != '?',
                    .type => |t| t != .optional,
                    else => true,
                };
                const opt_typ = if (wrap) bld.x.typeOptional(bld.x.fromExpr(typing)) else bld.x.fromExpr(typing);
                if (func.returns_optional or wrap) {
                    try self.fields.put(self.arena, assign, .{
                        .is_direct = false,
                        .is_optional = true,
                        .name = var_name,
                    });
                }

                try bld.variable(var_name).typing(opt_typ).assign(bld.x.valueOf(null));
            }

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

    try generateResolverRules(tst.gen, tst.block(), &[_]mdl.Rule{
        .{ .err = .{
            .conditions = &[_]mdl.Condition{.{
                .function = lib.Function.Id.not,
                .args = &.{.{ .reference = "Foo" }},
                .assign = "foo",
            }},
            .message = .{ .string = "bar" },
        } },
        .{ .err = .{ .message = .{ .string = "baz" } } },
    });

    try tst.expect(
        \\{
        \\    var foo: ?bool = null;
        \\
        \\    did_pass = pass: {
        \\        if (!(asgn: {
        \\            foo = !config.foo.?;
        \\
        \\            break :asgn foo;
        \\        })) break :pass false;
        \\
        \\        break :pass true;
        \\    };
        \\
        \\    if (did_pass) {
        \\        if (!IS_TEST) std.log.err("bar", .{});
        \\
        \\        return error.ReachedErrorRule;
        \\    }
        \\
        \\    if (!IS_TEST) std.log.err("baz", .{});
        \\
        \\    return error.ReachedErrorRule;
        \\}
    );
}

const ConditionCtx = struct { self: *Self, conditions: []const mdl.Condition };
fn generateResolverCondition(ctx: ConditionCtx, bld: *BlockBuild) !void {
    const self = ctx.self;
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
        .conditions = &[_]mdl.Condition{
            .{
                .function = lib.Function.Id.not,
                .args = &.{.{ .reference = "Bar" }},
            },
            .{
                .function = lib.Function.Id.not,
                .args = &.{.{ .reference = "Baz" }},
                .assign = "foo",
            },
        },
    }, tst.block());

    try tst.expect(
        \\{
        \\    if (!(!config.bar)) break :pass false;
        \\
        \\    if (!(asgn: {
        \\        foo = !param_baz;
        \\
        \\        break :asgn foo;
        \\    })) break :pass false;
        \\
        \\    break :pass true;
        \\}
    );
}

const RuleCtx = struct { self: *Self, rule: mdl.Rule };
fn generateRule(ctx: RuleCtx, bld: *BlockBuild) !void {
    return switch (ctx.rule) {
        .endpoint => |endpoint| ctx.self.generateEndpointRule(bld, endpoint),
        .err => |err| ctx.self.generateErrorRule(bld, err),
        .tree => |tree| ctx.self.generateResolverRules(bld, tree.rules),
    };
}

fn generateErrorRule(self: *Self, bld: *BlockBuild, rule: mdl.ErrorRule) !void {
    const template = try self.evalTemplateString(bld.x, rule.message);

    try bld.@"if"(bld.x.op(.not).id("IS_TEST")).body(
        bld.x.call("std.log.err", &.{ bld.x.fromExpr(template.format), bld.x.fromExpr(template.args) }),
    ).end();

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
        \\    if (!IS_TEST) std.log.err("foo", .{});
        \\
        \\    return error.ReachedErrorRule;
        \\}
    );
}

// TODO: Codegen properties, headers, authSchemas
fn generateEndpointRule(self: *Self, bld: *BlockBuild, rule: mdl.EndpointRule) !void {
    const template = try self.evalTemplateString(bld.x, rule.endpoint.url);
    try bld.returns().call("std.fmt.allocPrint", &.{
        bld.x.id(config.allocator_arg),
        bld.x.fromExpr(template.format),
        bld.x.fromExpr(template.args),
    }).end();
}

test "generateEndpointRule" {
    var tst = try Tester.init();
    defer tst.deinit();

    try tst.gen.generateEndpointRule(tst.block(), .{
        .endpoint = .{ .url = .{ .string = "https://{Foo}.service.com" } },
    });

    try tst.expect(
        \\{
        \\    return std.fmt.allocPrint(allocator, "https://{s}.service.com", .{config.foo.?});
        \\}
    );
}

const TemplateString = struct { format: Expr, args: Expr };
fn evalTemplateString(self: *Self, x: ExprBuild, template: mdl.StringValue) !TemplateString {
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
                .args = Expr{ .value = .{
                    .struct_literal = .{ .identifier = null, .values = &.{} },
                } },
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
        .reference = "Foo",
    });
    try template.format.expect(tst.alloc, "\"{s}\"");
    try template.args.expect(tst.alloc, ".{config.foo.?}");

    template = try tst.gen.evalTemplateString(tst.x, .{
        .function = .{
            .id = lib.Function.Id.get_attr,
            .args = &.{
                .{ .reference = "Foo" },
                .{ .string = "bar" },
            },
        },
    });
    try template.format.expect(tst.alloc, "\"{s}\"");
    try template.args.expect(tst.alloc, ".{config.foo.?.bar}");

    template = try tst.gen.evalTemplateString(tst.x, .{
        .string = "foo",
    });
    try template.format.expect(tst.alloc, "\"foo\"");
    try template.args.expect(tst.alloc, ".{}");

    template = try tst.gen.evalTemplateString(tst.x, .{
        .string = "{Foo}bar{baz#qux}",
    });
    try template.format.expect(tst.alloc, "\"{s}bar{s}\"");
    try template.args.expect(tst.alloc, ".{ config.foo.?, baz.qux }");
}

pub fn evalFunc(
    self: *Self,
    x: ExprBuild,
    id: lib.Function.Id,
    args: []const mdl.ArgValue,
    assign: ?[]const u8,
) !Expr {
    const func = try self.engine.getFunc(id);
    const expr = try func.genFn(self, x, args);
    errdefer expr.deinit(self.arena);

    if (assign) |name| {
        const var_name = try name_util.snakeCase(self.arena, name);

        const context = .{ .expr = expr, .var_name = var_name, .unwrap = func.returns_optional };
        return x.label(ASSIGN_LABEL).blockWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *BlockBuild) !void {
                try b.id(ctx.var_name).assign().fromExpr(ctx.expr).end();
                if (ctx.unwrap) {
                    try b.breaks(ASSIGN_LABEL).id(ctx.var_name).op(.not_eql).valueOf(null).end();
                } else {
                    try b.breaks(ASSIGN_LABEL).id(ctx.var_name).end();
                }
            }
        }.f).consume();
    } else if (func.returns_optional) {
        return x.fromExpr(expr).op(.not_eql).valueOf(null).consume();
    } else {
        return expr;
    }
}

test "evalFunc" {
    var tst = try Tester.init();
    defer tst.deinit();

    var expr = try tst.gen.evalFunc(tst.x, lib.Function.Id.is_set, &.{
        .{ .reference = "Foo" },
    }, null);
    try expr.expect(tst.alloc, "config.foo != null");

    expr = try tst.gen.evalFunc(tst.x, lib.Function.Id.is_set, &.{
        .{ .reference = "Bar" },
    }, "foo");
    try expr.expect(tst.alloc,
        \\asgn: {
        \\    foo = config.bar != null;
        \\
        \\    break :asgn foo;
        \\}
    );
}

pub fn evalArg(self: *Self, x: ExprBuild, arg: mdl.ArgValue) anyerror!Expr {
    const expr = try self.evalArgRaw(x, arg);
    switch (arg) {
        .reference => |ref| {
            if (self.fields.get(ref)) |f| if (f.is_optional) {
                return x.fromExpr(expr).unwrap().consume();
            };

            return expr;
        },
        else => return expr,
    }
}

pub fn evalArgRaw(self: *Self, x: ExprBuild, arg: mdl.ArgValue) anyerror!Expr {
    switch (arg) {
        .boolean => |b| return x.valueOf(b).consume(),
        .integer => |d| return x.valueOf(d).consume(),
        .string => |s| return x.valueOf(s).consume(),
        .function => |t| return self.evalFunc(x, t.id, t.args, null),
        .reference => |s| {
            if (self.fields.get(s)) |field| {
                return x.raw(field.name).consume();
            } else {
                const field_name = try name_util.snakeCase(self.arena, s);
                return x.id(field_name).consume();
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

    const items: []const mdl.ArgValue = &.{ .{ .string = "foo" }, .{ .string = "bar" } };
    expr = try tst.gen.evalArg(tst.x, .{
        .array = items,
    });
    try expr.expect(tst.alloc, "&.{ \"foo\", \"bar\" }");

    expr = try tst.gen.evalArg(tst.x, .{ .reference = "Foo" });
    try expr.expect(tst.alloc, "config.foo.?");

    expr = try tst.gen.evalArg(tst.x, .{ .reference = "Bar" });
    try expr.expect(tst.alloc, "config.bar");

    expr = try tst.gen.evalArg(tst.x, .{ .reference = "Baz" });
    try expr.expect(tst.alloc, "param_baz");
}

pub const Tester = struct {
    arena: *std.heap.ArenaAllocator,
    alloc: Allocator,
    engine: Engine,
    gen: *Self,
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

        const gen = try test_alloc.create(Self);
        errdefer test_alloc.destroy(gen);
        gen.* = try Self.init(arena_alloc, engine, &.{ .{
            .key = "Foo",
            .value = mdl.Parameter{
                .type = .{ .string = null },
                .documentation = "Optional",
            },
        }, .{
            .key = "Bar",
            .value = mdl.Parameter{
                .type = .{ .boolean = null },
                .required = true,
                .documentation = "Required",
            },
        }, .{
            .key = "Baz",
            .value = mdl.Parameter{
                .type = .{ .boolean = true },
                .required = true,
                .documentation = "Required with default",
            },
        } });

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

        self.engine.deinit(test_alloc);
        self.arena.deinit();
        test_alloc.destroy(self.gen);
        test_alloc.destroy(self.arena);
    }

    pub fn block(self: *Tester) *BlockBuild {
        switch (self.bld) {
            .block => {},
            .none => self.bld = .{ .block = BlockBuild.init(self.arena.allocator()) },
            .container => unreachable,
        }
        return &self.bld.block;
    }

    pub fn container(self: *Tester) *ContainerBuild {
        switch (self.bld) {
            .container => {},
            .none => self.bld = .{ .container = ContainerBuild.init(self.arena.allocator()) },
            .block => unreachable,
        }
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

// https://github.com/awslabs/aws-c-sdkutils/blob/main/tests/endpoints_rule_engine_tests.c
pub fn generateTests(
    self: *Self,
    bld: *ContainerBuild,
    func_name: []const u8,
    config_type: []const u8,
    cases: []const mdl.TestCase,
) !void {
    for (cases) |case| {
        const context = .{ .arena = self.arena, .case = case, .func_name = func_name, .config_type = config_type };
        try bld.testBlockWith(case.documentation, context, struct {
            fn f(ctx: @TypeOf(context), b: *BlockBuild) !void {
                const tc: mdl.TestCase = ctx.case;

                var params = std.ArrayList(ExprBuild).init(ctx.arena);
                try params.ensureTotalCapacityPrecise(tc.params.len);
                for (tc.params) |kv| {
                    const field = try name_util.snakeCase(ctx.arena, kv.key);
                    const expr = switch (kv.value) {
                        inline .boolean, .string => |t| try b.x.structAssign(field, b.x.valueOf(t.?)).consume(),
                        .string_array => |values| blk: {
                            var strings = std.ArrayList(ExprBuild).init(ctx.arena);
                            try strings.ensureTotalCapacity(values.?.len);
                            for (values.?) |v| strings.appendAssumeCapacity(b.x.valueOf(v));
                            const array = b.x.addressOf().structLiteral(null, try strings.toOwnedSlice());
                            break :blk try b.x.structAssign(field, array).consume();
                        },
                    };
                    params.appendAssumeCapacity(b.x.fromExpr(expr));
                }

                const params_exprs = try params.toOwnedSlice();
                try b.constant("config").assign(b.x.structLiteral(b.x.raw(ctx.config_type), params_exprs));

                switch (tc.expect) {
                    .err => |_| {
                        try b.constant("endpoint").assign(
                            b.x.call(ctx.func_name, &.{ b.x.raw("std.testing.allocator"), b.x.id("config") }),
                        );
                        try b.trys().call(
                            "std.testing.expectError",
                            &.{ b.x.raw("error.ReachedErrorRule"), b.x.id("endpoint") },
                        ).end();
                    },
                    .endpoint => |s| {
                        try b.constant("endpoint").assign(
                            b.x.trys().call(ctx.func_name, &.{ b.x.raw("std.testing.allocator"), b.x.id("config") }),
                        );
                        try b.defers(b.x.call("std.testing.allocator.free", &.{b.x.id("endpoint")}));
                        try b.trys().call(
                            "std.testing.expectEqualStrings",
                            &.{ b.x.valueOf(s), b.x.id("endpoint") },
                        ).end();
                    },
                    .invalid => unreachable,
                }
            }
        }.f);
    }
}

test "generateTests" {
    var tst = try Tester.init();
    defer tst.deinit();

    try generateTests(tst.gen, tst.container(), "resolve", "Config", &[_]mdl.TestCase{
        .{
            .documentation = "Test 1",
            .expect = .{ .endpoint = "https://example.com" },
            .params = &[_]mdl.StringKV(mdl.ParamValue){
                .{ .key = "Foo", .value = .{ .string = "bar" } },
                .{ .key = "BarBaz", .value = .{ .boolean = true } },
            },
        },
        .{
            .documentation = "Test 2",
            .expect = .{ .err = "Fail..." },
            .params = &[_]mdl.StringKV(mdl.ParamValue){
                .{ .key = "Foo", .value = .{ .string = "bar" } },
            },
        },
        .{
            .documentation = "Test 3",
            .expect = .{ .err = "Boom!" },
            .params = &.{},
        },
    });

    try tst.expect(
        \\test "Test 1" {
        \\    const config = Config{ .foo = "bar", .bar_baz = true };
        \\
        \\    const endpoint = try resolve(std.testing.allocator, config);
        \\
        \\    defer std.testing.allocator.free(endpoint);
        \\
        \\    try std.testing.expectEqualStrings("https://example.com", endpoint);
        \\}
        \\
        \\test "Test 2" {
        \\    const config = Config{.foo = "bar"};
        \\
        \\    const endpoint = resolve(std.testing.allocator, config);
        \\
        \\    try std.testing.expectError(error.ReachedErrorRule, endpoint);
        \\}
        \\
        \\test "Test 3" {
        \\    const config = Config{};
        \\
        \\    const endpoint = resolve(std.testing.allocator, config);
        \\
        \\    try std.testing.expectError(error.ReachedErrorRule, endpoint);
        \\}
    );
}
