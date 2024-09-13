const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const razdaz = @import("razdaz");
const Writer = razdaz.CodegenWriter;
const md = razdaz.md;
const zig = razdaz.zig;
const Expr = zig.Expr;
const ExprBuild = zig.ExprBuild;
const BlockBuild = zig.BlockBuild;
const ContainerBuild = zig.ContainerBuild;
const mdl = @import("model.zig");
const lib = @import("library.zig");
const Engine = @import("RulesEngine.zig");
const cfg = @import("../../config.zig");
const name_util = @import("../../utils/names.zig");
const JsonValue = @import("../../utils/JsonReader.zig").Value;
const evalDocument = @import("../../render/shape.zig").writeDocument;

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
        const is_direct = !param.type.hasDefault();

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
pub fn generateResolver(self: *Self, bld: *ContainerBuild, rules: []const mdl.Rule) !void {
    if (rules.len == 0) return error.EmptyRuleSet;

    const context = .{ .self = self, .rules = rules };
    try bld.public().function(cfg.endpoint_resolve_fn)
        .arg(cfg.alloc_param, bld.x.id("Allocator"))
        .arg(ARG_CONFIG, bld.x.raw(cfg.endpoint_config_type))
        .returns(bld.x.raw("!" ++ cfg.scope_private ++ ".Endpoint"))
        .bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *BlockBuild) !void {
            try b.variable("local_buffer").typing(b.typeOf([512]u8)).assign(b.x.raw("undefined"));
            try b.variable("local_heap").assign(b.x.call("std.heap.FixedBufferAllocator.init", &.{b.x.addressOf().id("local_buffer")}));
            try b.constant(cfg.stack_alloc).assign(b.x.raw("local_heap.allocator()"));
            try b.discard().id(cfg.stack_alloc).end();

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

    try generateResolver(tst.gen, tst.container(), &[_]mdl.Rule{
        .{ .err = .{ .message = .{ .string = "baz" } } },
    });

    try tst.expect(
        \\pub fn resolve(allocator: Allocator, config: EndpointConfig) !smithy._private_.Endpoint {
        \\    var local_buffer: [512]u8 = undefined;
        \\
        \\    var local_heap = std.heap.FixedBufferAllocator.init(&local_buffer);
        \\
        \\    const scratch_alloc = local_heap.allocator();
        \\
        \\    _ = scratch_alloc;
        \\
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
    var typ: mdl.ParamValue = param.type;
    if (param.built_in) |id| {
        const built_in = try self.engine.getBuiltIn(id);
        typ = built_in.type;
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
    const val_2 = if (default) |t| val_1.orElse().buildExpr(t) else blk: {
        if (param.required) return error.RulesRequiredParamHasNoValue;
        break :blk val_1;
    };

    try bld.constant(field_name).typing(typing).assign(val_2);
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
        .endpoint => |endpoint| ctx.self.generateEndpointRule(bld, endpoint.endpoint),
        .err => |err| ctx.self.generateErrorRule(bld, err.message),
        .tree => |tree| ctx.self.generateResolverRules(bld, tree.rules),
    };
}

fn generateErrorRule(self: *Self, bld: *BlockBuild, message: mdl.StringValue) !void {
    const template = try self.evalTemplateString(bld.x, message);
    const fmt_args = if (template.args) |args| bld.x.fromExpr(args) else bld.x.raw(".{}");

    try bld.@"if"(bld.x.op(.not).id("IS_TEST")).body(
        bld.x.call("std.log.err", &.{ bld.x.fromExpr(template.format), fmt_args }),
    ).end();

    try bld.returns().valueOf(error.ReachedErrorRule).end();
}

test "generateErrorRule" {
    var tst = try Tester.init();
    defer tst.deinit();

    try tst.gen.generateErrorRule(tst.block(), .{ .string = "foo" });
    try tst.expect(
        \\{
        \\    if (!IS_TEST) std.log.err("foo", .{});
        \\
        \\    return error.ReachedErrorRule;
        \\}
    );
}

fn generateEndpointRule(self: *Self, bld: *BlockBuild, endpoint: mdl.Endpoint) !void {
    const fmt_url = try self.evalTemplateString(bld.x, endpoint.url);
    if (fmt_url.args) |args| {
        try bld.constant("url").assign(bld.x.trys().call("std.fmt.allocPrint", &.{
            bld.x.id(cfg.alloc_param),
            bld.x.fromExpr(fmt_url.format),
            bld.x.fromExpr(args),
        }));
    } else {
        try bld.constant("url").assign(
            bld.x.trys().id(cfg.alloc_param).dot().call("dupe", &.{
                bld.x.typeOf(u8),
                bld.x.fromExpr(fmt_url.format),
            }),
        );
    }
    try bld.errorDefers().body(bld.x.id(cfg.alloc_param).dot().call("free", &.{bld.x.id("url")}));

    const headers = if (endpoint.headers) |headers| blk: {
        try bld.constant("headers").assign(
            bld.x.trys().id(cfg.alloc_param).dot().call("alloc", &.{
                bld.x.raw(cfg.scope_private).dot().id("HttpHeader"),
                bld.x.valueOf(headers.len),
            }),
        );
        try bld.errorDefers().body(
            bld.x.id(cfg.alloc_param).dot().call("free", &.{bld.x.id("headers")}),
        );

        for (headers, 0..) |header, i| {
            const prefix = try std.fmt.allocPrint(self.arena, "head_{d}", .{i});
            const values = try self.generateStringsArray(bld, header.value, prefix);
            try bld.id("headers").valIndexer(bld.valueOf(i)).assign().structLiteral(null, &.{
                bld.x.structAssign("key", bld.x.valueOf(header.key)),
                bld.x.structAssign("values", bld.x.fromExpr(values)),
            }).end();
        }

        break :blk bld.x.id("headers");
    } else bld.x.raw("&.{}");

    var auth_schemes: ?[]const JsonValue = null;
    const properties = if (endpoint.properties) |props| blk: {
        for (props) |prop| {
            if (mem.eql(u8, "authSchemes", prop.key)) {
                auth_schemes = prop.value.array;
                break;
            }
        }

        try bld.constant("properties").assign(
            bld.x.trys().id(cfg.alloc_param).dot().call("alloc", &.{
                bld.x.raw(cfg.scope_private).dot().raw("Document.KV"),
                bld.x.valueOf(if (auth_schemes == null) props.len else props.len - 1),
            }),
        );
        try bld.errorDefers().body(
            bld.x.id(cfg.alloc_param).dot().call("free", &.{bld.x.id("properties")}),
        );

        var i: usize = 0;
        for (props) |prop| {
            if (auth_schemes != null and mem.eql(u8, "authSchemes", prop.key)) continue;
            const document = try self.generateEndpointProperty(bld, prop, "prop_{d}", .{i});
            try bld.id("properties").valIndexer(bld.valueOf(i)).assign().fromExpr(document).end();
            i += 1;
        }
        break :blk bld.x.id("properties");
    } else bld.x.raw("&.{}");

    const auth = if (auth_schemes) |schemes| blk: {
        try bld.constant("schemes").assign(
            bld.x.trys().id(cfg.alloc_param).dot().call("alloc", &.{
                bld.x.raw(cfg.scope_private).dot().id("AuthScheme"),
                bld.x.valueOf(schemes.len),
            }),
        );
        try bld.errorDefers().body(
            bld.x.id(cfg.alloc_param).dot().call("free", &.{bld.x.id("schemes")}),
        );

        for (schemes, 0..) |scheme, i| {
            std.debug.assert(mem.eql(u8, "name", scheme.object[0].key));
            const name = scheme.object[0].value.string;
            const props = scheme.object[1..scheme.object.len];

            const id = try std.fmt.allocPrint(self.arena, "scheme_{d}", .{i});
            try bld.constant(id).assign(
                bld.x.trys().id(cfg.alloc_param).dot().call("alloc", &.{
                    bld.x.raw(cfg.scope_private).dot().raw("Document.KV"),
                    bld.x.valueOf(props.len),
                }),
            );
            try bld.errorDefers().body(
                bld.x.id(cfg.alloc_param).dot().call("free", &.{bld.x.id(id)}),
            );

            for (props, 0..) |prop, p| {
                const document = try self.generateEndpointProperty(bld, prop, "scheme_{d}_{d}", .{ i, p });
                try bld.id(id).valIndexer(bld.valueOf(i)).assign().fromExpr(document).end();
            }

            try bld.id("schemes").valIndexer(bld.valueOf(i)).assign().structLiteral(null, &.{
                bld.x.structAssign("id", bld.x.call("smithy.intenral.AuthId.of", &.{bld.x.valueOf(name)})),
                bld.x.structAssign("properties", bld.x.id(id)),
            }).end();
        }

        break :blk bld.x.id("schemes");
    } else bld.x.raw("&.{}");

    try bld.returns().structLiteral(null, &.{
        bld.x.structAssign("url", bld.x.id("url")),
        bld.x.structAssign("headers", headers),
        bld.x.structAssign("properties", properties),
        bld.x.structAssign("auth_schemes", auth),
    }).end();
}

fn generateEndpointProperty(
    self: *Self,
    bld: *BlockBuild,
    prop: JsonValue.KV,
    comptime name_fmt: []const u8,
    name_args: anytype,
) !Expr {
    const document = switch (prop.value) {
        .string => |s| doc: {
            const fmt_prop = try self.evalTemplateString(bld.x, .{ .string = s });
            if (fmt_prop.args) |args| {
                const name = try std.fmt.allocPrint(self.arena, name_fmt, name_args);
                try bld.constant(name).assign(bld.x.trys().call("std.fmt.allocPrint", &.{
                    bld.x.id(cfg.alloc_param),
                    bld.x.fromExpr(fmt_prop.format),
                    bld.x.fromExpr(args),
                }));
                try bld.errorDefers().body(bld.x.id(cfg.alloc_param).dot().call("free", &.{bld.x.id(name)}));
                break :doc bld.x.structLiteral(null, &.{
                    bld.x.structAssign("string_alloc", bld.x.id(name)),
                });
            } else {
                break :doc bld.x.structLiteral(null, &.{
                    bld.x.structAssign("string", bld.x.fromExpr(fmt_prop.format)),
                });
            }
        },
        else => bld.x.fromExpr(try evalDocument(bld.x, prop.value)),
    };
    return bld.x.structLiteral(null, &.{
        bld.x.structAssign("key", bld.x.valueOf(prop.key)),
        bld.x.structAssign("key_alloc", bld.x.valueOf(false)),
        bld.x.structAssign("document", document),
    }).consume();
}

test "generateEndpointRule" {
    var tst = try Tester.init();
    defer tst.deinit();

    try tst.gen.generateEndpointRule(tst.block(), .{
        .url = .{ .string = "https://{Foo}.service.com" },
        .headers = &.{
            .{
                .key = "foo",
                .value = &.{},
            },
            .{
                .key = "bar",
                .value = &.{ .{ .string = "baz" }, .{ .string = "qux" } },
            },
        },
        .properties = &.{
            .{ .key = "qux", .value = .null },
            .{
                .key = "authSchemes",
                .value = .{ .array = &.{.{
                    .object = &.{
                        .{ .key = "name", .value = .{ .string = "auth" } },
                        .{ .key = "value", .value = .{ .integer = 108 } },
                    },
                }} },
            },
        },
    });

    try tst.expect(
        \\{
        \\    const url = try std.fmt.allocPrint(allocator, "https://{s}.service.com", .{config.foo.?});
        \\
        \\    errdefer allocator.free(url);
        \\
        \\    const headers = try allocator.alloc(smithy._private_.HttpHeader, 2);
        \\
        \\    errdefer allocator.free(headers);
        \\
        \\    headers[0] = .{ .key = "foo", .values = &.{} };
        \\
        \\    const head_1 = try allocator.alloc([]const u8, 2);
        \\
        \\    errdefer allocator.free(head_1);
        \\
        \\    head_1[0] = "baz";
        \\
        \\    head_1[1] = "qux";
        \\
        \\    headers[1] = .{ .key = "bar", .values = head_1 };
        \\
        \\    const properties = try allocator.alloc(smithy._private_.Document.KV, 1);
        \\
        \\    errdefer allocator.free(properties);
        \\
        \\    properties[0] = .{
        \\        .key = "qux",
        \\        .key_alloc = false,
        \\        .document = .null,
        \\    };
        \\
        \\    const schemes = try allocator.alloc(smithy._private_.AuthScheme, 1);
        \\
        \\    errdefer allocator.free(schemes);
        \\
        \\    const scheme_0 = try allocator.alloc(smithy._private_.Document.KV, 1);
        \\
        \\    errdefer allocator.free(scheme_0);
        \\
        \\    scheme_0[0] = .{
        \\        .key = "value",
        \\        .key_alloc = false,
        \\        .document = .{.integer = 108},
        \\    };
        \\
        \\    schemes[0] = .{ .id = smithy.intenral.AuthId.of("auth"), .properties = scheme_0 };
        \\
        \\    return .{
        \\        .url = url,
        \\        .headers = headers,
        \\        .properties = properties,
        \\        .auth_schemes = schemes,
        \\    };
        \\}
    );
}

const TemplateString = struct { format: Expr, args: ?Expr };
fn evalTemplateString(self: *Self, x: ExprBuild, template: mdl.StringValue) !TemplateString {
    switch (template) {
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
                .args = null,
            };
        },
        .reference => |ref| return .{
            .format = try self.evalArg(x, .{ .reference = ref }),
            .args = null,
        },
        .function => |func| return .{
            .format = try self.evalFunc(x, func.id, func.args, null),
            .args = null,
        },
    }
}

test "evalTemplateString" {
    var tst = try Tester.init();
    defer tst.deinit();

    var template = try tst.gen.evalTemplateString(tst.x, .{
        .reference = "Foo",
    });
    try template.format.expect(tst.alloc, "config.foo.?");
    try testing.expectEqual(null, template.args);

    template = try tst.gen.evalTemplateString(tst.x, .{
        .function = .{
            .id = lib.Function.Id.get_attr,
            .args = &.{
                .{ .reference = "Foo" },
                .{ .string = "bar" },
            },
        },
    });
    try template.format.expect(tst.alloc, "config.foo.?.bar");
    try testing.expectEqual(null, template.args);

    template = try tst.gen.evalTemplateString(tst.x, .{ .string = "foo" });
    try template.format.expect(tst.alloc, "\"foo\"");
    try testing.expectEqual(null, template.args);

    template = try tst.gen.evalTemplateString(tst.x, .{ .string = "{Foo}bar{baz#qux}" });
    try template.format.expect(tst.alloc, "\"{s}bar{s}\"");
    try template.args.?.expect(tst.alloc, ".{ config.foo.?, baz.qux }");
}

fn generateStringsArray(
    self: *Self,
    bld: *BlockBuild,
    strings: []const mdl.StringValue,
    id_prefix: []const u8,
) !Expr {
    if (strings.len == 0) return bld.x.raw("&.{}").consume();

    try bld.constant(id_prefix).assign(
        bld.x.trys().id(cfg.alloc_param).dot().call("alloc", &.{
            bld.x.raw("[]const u8"),
            bld.x.valueOf(strings.len),
        }),
    );
    try bld.errorDefers().body(
        bld.x.id(cfg.alloc_param).dot().call("free", &.{bld.x.id(id_prefix)}),
    );

    for (strings, 0..) |value, i| {
        const template = try self.evalTemplateString(bld.x, value);
        if (template.args) |args| {
            const id = try std.fmt.allocPrint(self.arena, "{s}_{d}", .{ id_prefix, i });
            try bld.constant(id).assign(bld.x.trys().call("std.fmt.allocPrint", &.{
                bld.x.id(cfg.alloc_param),
                bld.x.fromExpr(template.format),
                bld.x.fromExpr(args),
            }));
            try bld.errorDefers().body(bld.x.id(cfg.alloc_param).dot().call("free", &.{bld.x.id(id)}));
            try bld.id(id_prefix).valIndexer(bld.valueOf(i)).assign().id(id).end();
        } else {
            try bld.id(id_prefix).valIndexer(bld.valueOf(i)).assign().fromExpr(template.format).end();
        }
    }

    return bld.x.id(id_prefix).consume();
}

test "generateStringsArray" {
    var tst = try Tester.init();
    defer tst.deinit();

    var expr = try tst.gen.generateStringsArray(tst.block(), &.{
        .{ .string = "foo" },
        .{ .string = "{Foo}bar{baz#qux}" },
    }, "item");
    try expr.expect(tst.alloc, "item");
    try tst.expect(
        \\{
        \\    const item = try allocator.alloc([]const u8, 2);
        \\
        \\    errdefer allocator.free(item);
        \\
        \\    item[0] = "foo";
        \\
        \\    const item_1 = try std.fmt.allocPrint(allocator, "{s}bar{s}", .{ config.foo.?, baz.qux });
        \\
        \\    errdefer allocator.free(item_1);
        \\
        \\    item[1] = item_1;
        \\}
    );
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
pub fn generateTests(self: *Self, bld: *ContainerBuild, cases: []const mdl.TestCase) !void {
    for (cases) |case| {
        const context = .{ .arena = self.arena, .case = case };
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
                try b.constant("config").assign(b.x.structLiteral(b.x.raw(cfg.endpoint_config_type), params_exprs));

                switch (tc.expect) {
                    .invalid => unreachable,
                    .err => |_| {
                        try b.constant("endpoint").assign(
                            b.x.call(cfg.endpoint_resolve_fn, &.{ b.x.raw("std.testing.allocator"), b.x.id("config") }),
                        );
                        try b.trys().call(
                            "std.testing.expectError",
                            &.{ b.x.raw("error.ReachedErrorRule"), b.x.id("endpoint") },
                        ).end();
                    },
                    .endpoint => |endpoint| {
                        try b.constant("endpoint").assign(
                            b.x.trys().call(cfg.endpoint_resolve_fn, &.{ b.x.raw("std.testing.allocator"), b.x.id("config") }),
                        );
                        try b.defers(b.x.id("endpoint").dot().call("deinit", &.{b.x.raw("std.testing.allocator")}));

                        try b.trys().call(
                            "std.testing.expectEqualStrings",
                            &.{ b.x.valueOf(endpoint.url.string), b.x.raw("endpoint.url") },
                        ).end();

                        if (endpoint.headers) |headers| {
                            var list = try std.ArrayList(ExprBuild).initCapacity(ctx.arena, headers.len);
                            for (headers) |header| {
                                var strs = try std.ArrayList(ExprBuild).initCapacity(ctx.arena, header.value.len);
                                for (header.value) |s| strs.appendAssumeCapacity(b.x.valueOf(s.string));
                                const str_array = b.x.addressOf().structLiteral(null, try strs.toOwnedSlice());
                                list.appendAssumeCapacity(b.x.structLiteral(null, &.{
                                    b.x.structAssign("key", b.x.valueOf(header.key)),
                                    b.x.structAssign("values", str_array),
                                }));
                            }
                            const expected = b.x.fromExpr(try b.x.structLiteral(
                                b.x.raw("&[_]" ++ cfg.scope_private ++ ".HttpHeader"),
                                try list.toOwnedSlice(),
                            ).consume());
                            try b.trys().call(
                                "std.testing.expectEqualDeep",
                                &.{ expected, b.x.raw("endpoint.headers") },
                            ).end();
                        }

                        var auth_schemes: ?[]const JsonValue = null;
                        if (endpoint.properties) |props| {
                            var list = try std.ArrayList(ExprBuild).initCapacity(ctx.arena, props.len);
                            for (props) |prop| {
                                if (mem.eql(u8, "authSchemes", prop.key)) {
                                    auth_schemes = prop.value.array;
                                    continue;
                                }

                                const doc = try evalDocument(b.x, prop.value);
                                list.appendAssumeCapacity(b.x.structLiteral(null, &.{
                                    b.x.structAssign("key", b.x.valueOf(prop.key)),
                                    b.x.structAssign("key_alloc", b.x.valueOf(false)),
                                    b.x.structAssign("document", b.x.fromExpr(doc)),
                                }));
                            }
                            const expected = b.x.fromExpr(try b.x.structLiteral(
                                b.x.raw("&[_]" ++ cfg.scope_private ++ ".Document.KV"),
                                try list.toOwnedSlice(),
                            ).consume());

                            try b.trys().call(
                                "std.testing.expectEqualDeep",
                                &.{ expected, b.x.raw("endpoint.properties") },
                            ).end();
                        }

                        if (auth_schemes) |schemes| {
                            var list = try std.ArrayList(ExprBuild).initCapacity(ctx.arena, schemes.len);
                            for (schemes) |scheme| {
                                std.debug.assert(mem.eql(u8, "name", scheme.object[0].key));
                                const name = scheme.object[0].value.string;
                                const props = scheme.object[1..scheme.object.len];
                                var prop_exprs = try std.ArrayList(ExprBuild).initCapacity(ctx.arena, props.len);
                                for (props) |prop| {
                                    const document = b.x.fromExpr(try evalDocument(b.x, prop.value));
                                    prop_exprs.appendAssumeCapacity(b.x.structLiteral(null, &.{
                                        b.x.structAssign("key", b.x.valueOf(prop.key)),
                                        b.x.structAssign("key_alloc", b.x.valueOf(false)),
                                        b.x.structAssign("document", document),
                                    }));
                                }
                                list.appendAssumeCapacity(b.x.structLiteral(null, &.{
                                    b.x.structAssign("id", b.x.call("smithy.intenral.AuthId.of", &.{b.x.valueOf(name)})),
                                    b.x.structAssign("properties", b.x.addressOf().structLiteral(null, try prop_exprs.toOwnedSlice())),
                                }));
                            }
                            const expected = b.x.fromExpr(try b.x.structLiteral(
                                b.x.raw("&[_]" ++ cfg.scope_private ++ ".AuthScheme"),
                                try list.toOwnedSlice(),
                            ).consume());

                            try b.trys().call(
                                "std.testing.expectEqualDeep",
                                &.{ expected, b.x.raw("endpoint.auth_schemes") },
                            ).end();
                        }
                    },
                }
            }
        }.f);
    }
}

test "generateTests" {
    var tst = try Tester.init();
    defer tst.deinit();

    try generateTests(tst.gen, tst.container(), &[_]mdl.TestCase{
        .{
            .documentation = "Test 1",
            .expect = .{
                .endpoint = .{
                    .url = .{ .string = "https://example.com" },
                    .headers = &.{
                        .{
                            .key = "foo",
                            .value = &.{ .{ .string = "bar" }, .{ .string = "baz" } },
                        },
                    },
                    .properties = &.{
                        .{ .key = "qux", .value = .null },
                        .{
                            .key = "authSchemes",
                            .value = .{ .array = &.{.{
                                .object = &.{
                                    .{ .key = "name", .value = .{ .string = "auth" } },
                                    .{ .key = "value", .value = .{ .integer = 108 } },
                                },
                            }} },
                        },
                    },
                },
            },
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
        \\    const config = EndpointConfig{ .foo = "bar", .bar_baz = true };
        \\
        \\    const endpoint = try resolve(std.testing.allocator, config);
        \\
        \\    defer endpoint.deinit(std.testing.allocator);
        \\
        \\    try std.testing.expectEqualStrings("https://example.com", endpoint.url);
        \\
        \\    try std.testing.expectEqualDeep(&[_]smithy._private_.HttpHeader{.{ .key = "foo", .values = &.{ "bar", "baz" } }}, endpoint.headers);
        \\
        \\    try std.testing.expectEqualDeep(&[_]smithy._private_.Document.KV{.{
        \\        .key = "qux",
        \\        .key_alloc = false,
        \\        .document = .null,
        \\    }}, endpoint.properties);
        \\
        \\    try std.testing.expectEqualDeep(&[_]smithy._private_.AuthScheme{.{ .id = smithy.intenral.AuthId.of("auth"), .properties = &.{.{
        \\        .key = "value",
        \\        .key_alloc = false,
        \\        .document = .{.integer = 108},
        \\    }} }}, endpoint.auth_schemes);
        \\}
        \\
        \\test "Test 2" {
        \\    const config = EndpointConfig{.foo = "bar"};
        \\
        \\    const endpoint = resolve(std.testing.allocator, config);
        \\
        \\    try std.testing.expectError(error.ReachedErrorRule, endpoint);
        \\}
        \\
        \\test "Test 3" {
        \\    const config = EndpointConfig{};
        \\
        \\    const endpoint = resolve(std.testing.allocator, config);
        \\
        \\    try std.testing.expectError(error.ReachedErrorRule, endpoint);
        \\}
    );
}
