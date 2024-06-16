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
    returns: FuncType,
    impl: *const fn (args: *const anyopaque, output: *anyopaque) void,
};

const INPUT_PARAM = "input";
const PASS_VAL = "did_pass";
const PASS_LABEL = "pass";

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
}

/// [Reference](https://github.com/smithy-lang/smithy/blob/main/smithy-rules-engine/src/main/java/software/amazon/smithy/rulesengine/language/evaluation/type/Type.java)
pub const FuncType = union(enum) {
    any,
    array: *const FuncType,
    boolean,
    empty,
    endpoint,
    integer,
    optional: *const FuncType,
    record: []const rls.StringKV(FuncType),
    string,
    tuple: []const FuncType,
};
