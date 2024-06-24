//! Produces Zig source code from a Smithy model.
const std = @import("std");
const fs = std.fs;
const log = std.log;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const syb = @import("../systems/symbols.zig");
const SmithyId = syb.SmithyId;
const SmithyType = syb.SmithyType;
const SymbolsProvider = syb.SymbolsProvider;
const test_symbols = @import("../testing/symbols.zig");
const RulesEngine = @import("../systems/rules.zig").RulesEngine;
const md = @import("md.zig");
const zig = @import("zig.zig");
const ExprBuild = zig.ExprBuild;
const BlockBuild = zig.BlockBuild;
const ContainerBuild = zig.ContainerBuild;
const Writer = @import("CodegenWriter.zig");
const Script = @import("script.zig").Script;
const name_util = @import("../utils/names.zig");
const IssuesBag = @import("../utils/IssuesBag.zig");
const trt_http = @import("../traits/http.zig");
const trt_docs = @import("../traits/docs.zig");
const trt_refine = @import("../traits/refine.zig");
const trt_behave = @import("../traits/behavior.zig");
const trt_constr = @import("../traits/constraint.zig");

const Self = @This();

pub const Policy = struct {
    unknown_shape: IssuesBag.PolicyResolution,
    invalid_root: IssuesBag.PolicyResolution,
    shape_codegen_fail: IssuesBag.PolicyResolution,
};

pub const Hooks = struct {
    writeReadme: ?*const fn (Script(.md), *SymbolsProvider, ReadmeMeta) anyerror!void = null,
    writeScriptHead: ?*const fn (Allocator, *ContainerBuild, *SymbolsProvider) anyerror!void = null,
    uniqueListType: ?*const fn (Allocator, []const u8) anyerror![]const u8 = null,
    writeErrorShape: *const fn (Allocator, *ContainerBuild, *SymbolsProvider, ErrorShape) anyerror!void,
    writeServiceHead: ?*const fn (Allocator, *ContainerBuild, *SymbolsProvider, *const RulesEngine, *const syb.SmithyService) anyerror!void = null,
    writeResourceHead: ?*const fn (Allocator, *ContainerBuild, *SymbolsProvider, SmithyId, *const syb.SmithyResource) anyerror!void = null,
    operationReturnType: ?*const fn (Allocator, *SymbolsProvider, OperationShape) anyerror!?[]const u8 = null,
    writeOperationBody: *const fn (Allocator, *BlockBuild, *SymbolsProvider, OperationShape) anyerror!void,

    pub const ErrorShape = struct {
        id: SmithyId,
        source: trt_refine.Error.Source,
        code: u10,
        retryable: bool,
    };

    pub const OperationShape = struct {
        id: SmithyId,
        input: ?Input,
        output_type: ?[]const u8,
        errors_type: ?[]const u8,

        pub const Input = struct {
            identifier: []const u8,
            type: []const u8,
        };
    };

    pub const ReadmeMeta = struct {
        /// `{[title]s}` service title
        title: []const u8,
        /// `{[slug]s}` service SDK ID
        slug: []const u8,
        /// `{[intro]s}` introduction description
        intro: ?[]const u8,
    };
};

hooks: Hooks,
policy: Policy,
rules: RulesEngine,

pub fn writeReadme(self: Self, document: Script(.md), symbols: *SymbolsProvider, slug: []const u8) !void {
    const hook = self.hooks.writeReadme orelse {
        return error.MissingReadmeHook;
    };

    const arena = document.arena;
    const title =
        trt_docs.Title.get(symbols, symbols.service_id) orelse
        try name_util.titleCase(arena, slug);
    const intro: ?[]const u8 = if (trt_docs.Documentation.get(symbols, symbols.service_id)) |docs| blk: {
        var build = md.Document.Build{ .allocator = arena };
        try md.html.convert(arena, &build, docs);
        const markdown = try build.consume();
        defer markdown.deinit(arena);

        var str = std.ArrayList(u8).init(arena);
        errdefer str.deinit();

        var writer = Writer.init(arena, str.writer().any());
        defer writer.deinit();

        try markdown.write(&writer);
        break :blk try str.toOwnedSlice();
    } else null;

    try hook(document, symbols, .{ .slug = slug, .title = title, .intro = intro });
}

pub fn writeScript(self: Self, script: Script(.zig), symbols: *SymbolsProvider, issues: *IssuesBag) !void {
    const gen = ScriptGen{
        .arena = script.arena,
        .hooks = self.hooks,
        .policy = self.policy,
        .issues = issues,
        .symbols = symbols,
        .rules = &self.rules,
    };
    try script.writeBody(gen, ScriptGen.run);
}

test "writeScript" {
    const script = try Script(.zig).initEphemeral(.{ .gpa = test_alloc });
    defer script.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();

    var symbols = try test_symbols.setup(script.arena, &.{.root_child});
    try symbols.enqueue(SmithyId.of("test#Root"));

    const generator = Self{
        .hooks = TEST_HOOKS,
        .policy = TEST_POLICY,
        .rules = undefined,
    };

    try generator.writeScript(script, &symbols, &issues);
    try script.expect(
        \\const smithy = @import("smithy");
        \\
        \\const std = @import("std");
        \\
        \\const Allocator = std.mem.Allocator;
        \\
        \\pub const Root = []const Child;
        \\
        \\pub const Child = []const i32;
    );
}

const ScriptGen = struct {
    arena: Allocator,
    hooks: Hooks,
    policy: Policy,
    issues: *IssuesBag,
    symbols: *SymbolsProvider,
    rules: *const RulesEngine,

    pub fn run(self: ScriptGen, bld: *ContainerBuild) !void {
        if (self.hooks.writeScriptHead) |hook| {
            try hook(self.arena, bld, self.symbols);
        }

        try bld.constant("smithy").assign(bld.x.import("smithy"));
        try bld.constant("std").assign(bld.x.import("std"));
        try bld.constant("Allocator").assign(bld.x.raw("std.mem.Allocator"));

        while (self.symbols.next()) |id| {
            try self.writeShape(bld, id);
        }
    }

    fn writeShape(self: ScriptGen, bld: *ContainerBuild, id: SmithyId) !void {
        const shape = self.symbols.getShape(id) catch switch (self.policy.unknown_shape) {
            .skip => return self.issues.add(.{ .codegen_unknown_shape = @intFromEnum(id) }),
            .abort => {
                log.err("Unknown shape: `{}`.", .{id});
                return IssuesBag.PolicyAbortError;
            },
        };

        (switch (shape) {
            .list => |m| self.writeListShape(bld, id, m),
            .map => |m| self.writeMapShape(bld, id, m),
            .str_enum => |m| self.writeStrEnumShape(bld, id, m),
            .int_enum => |m| self.writeIntEnumShape(bld, id, m),
            .tagged_uinon => |m| self.writeUnionShape(bld, id, m),
            .structure => |m| self.writeStructShape(bld, id, m),
            .resource => |t| self.writeResourceShape(bld, id, t),
            .service => |t| self.writeServiceShape(bld, id, t),
            .string => if (trt_constr.Enum.get(self.symbols, id)) |members|
                self.writeTraitEnumShape(bld, id, members)
            else
                error.InvalidRootShape,
            else => error.InvalidRootShape,
        }) catch |e| {
            const shape_name = self.symbols.getShapeName(id, .type);
            const name_id: IssuesBag.Issue.NameOrId = if (shape_name) |n|
                .{ .name = n }
            else |_|
                .{ .id = @intFromEnum(id) };
            switch (e) {
                error.InvalidRootShape => switch (self.policy.invalid_root) {
                    .skip => {
                        try self.issues.add(.{ .codegen_invalid_root = name_id });
                        return;
                    },
                    .abort => {
                        if (shape_name) |n|
                            log.err("Invalid root shape: `{s}`.", .{n})
                        else |_|
                            log.err("Invalid root shape: `{}`.", .{id});
                        return IssuesBag.PolicyAbortError;
                    },
                },
                else => switch (self.policy.shape_codegen_fail) {
                    .skip => {
                        try self.issues.add(.{ .codegen_shape_fail = .{
                            .err = e,
                            .item = name_id,
                        } });
                        return;
                    },
                    .abort => {
                        if (shape_name) |n|
                            log.err("Shape `{s}` codegen failed: `{s}`.", .{ n, @errorName(e) })
                        else |_|
                            log.err("Shape `{}` codegen failed: `{s}`.", .{ id, @errorName(e) });
                        return IssuesBag.PolicyAbortError;
                    },
                },
            }
        };
    }

    test "writeShape" {
        var tester = try ScriptTester.init();
        defer tester.deinit();

        var symbols = try test_symbols.setup(
            tester.allocator(),
            &.{.unit},
        );
        defer symbols.deinit();

        var self = tester.initCodegen(&symbols);
        try self.writeShape(tester.build, SmithyId.of("test#Unit"));
        try testing.expectEqualDeep(&.{
            IssuesBag.Issue{ .codegen_invalid_root = .{ .id = @intFromEnum(SmithyId.of("test#Unit")) } },
        }, tester.issues.all());
        try tester.expect("");
    }

    fn writeListShape(self: ScriptGen, bld: *ContainerBuild, id: SmithyId, memeber: SmithyId) !void {
        const shape_name = try self.symbols.getShapeName(id, .type);
        const type_name = try self.symbols.getTypeName(memeber);
        try self.writeDocComment(bld, id, false);

        const target_exp = if (self.symbols.hasTrait(id, trt_constr.unique_items_id)) blk: {
            if (self.hooks.uniqueListType) |hook| {
                break :blk bld.x.raw(try hook(self.arena, type_name));
            } else {
                break :blk bld.x.call(
                    "*const std.AutoArrayHashMapUnmanaged",
                    &.{ bld.x.raw(type_name), bld.x.raw("void") },
                );
            }
        } else if (self.symbols.hasTrait(id, trt_refine.sparse_id))
            bld.x.typeSlice(false, bld.x.typeOptional(bld.x.raw(type_name)))
        else
            bld.x.typeSlice(false, bld.x.raw(type_name));

        try bld.public().constant(shape_name).assign(target_exp);
    }

    test "writeListShape" {
        var tester = try ScriptTester.init();
        defer tester.deinit();

        var symbols = try test_symbols.setup(
            tester.allocator(),
            &.{.list},
        );
        defer symbols.deinit();

        var self = tester.initCodegen(&symbols);
        try self.writeShape(tester.build, SmithyId.of("test#List"));
        try self.writeShape(tester.build, SmithyId.of("test#Set"));
        try tester.expect(
            \\pub const List = []const ?i32;
            \\
            \\pub const Set = *const std.AutoArrayHashMapUnmanaged(i32, void);
        );
    }

    fn writeMapShape(self: ScriptGen, bld: *ContainerBuild, id: SmithyId, memeber: [2]SmithyId) !void {
        const shape_name = try self.symbols.getShapeName(id, .type);
        const key_type = try self.symbols.getTypeName(memeber[0]);
        const val_type = try self.symbols.getTypeName(memeber[1]);
        try self.writeDocComment(bld, id, false);

        var value: ExprBuild = bld.x.raw(val_type);
        if (self.symbols.hasTrait(id, trt_refine.sparse_id))
            value = bld.x.typeOptional(value);

        var fn_name: []const u8 = undefined;
        var args: []const ExprBuild = undefined;
        if (std.mem.eql(u8, key_type, "[]const u8")) {
            fn_name = "*const std.StringArrayHashMapUnmanaged";
            args = &.{value};
        } else {
            fn_name = "*const std.AutoArrayHashMapUnmanaged";
            args = &.{ bld.x.raw(key_type), value };
        }

        try bld.public().constant(shape_name).assign(bld.x.call(fn_name, args));
    }

    test "writeMapShape" {
        var tester = try ScriptTester.init();
        defer tester.deinit();

        var symbols = try test_symbols.setup(
            tester.allocator(),
            &.{.map},
        );
        defer symbols.deinit();

        var self = tester.initCodegen(&symbols);
        try self.writeShape(tester.build, SmithyId.of("test#Map"));
        try tester.expect("pub const Map = *const std.AutoArrayHashMapUnmanaged(i32, ?i32);");
    }

    fn writeStrEnumShape(self: ScriptGen, bld: *ContainerBuild, id: SmithyId, members: []const SmithyId) !void {
        var list = try EnumList.initCapacity(self.arena, members.len);
        defer list.deinit();
        for (members) |m| {
            const value = trt_refine.EnumValue.get(self.symbols, m);
            const value_str = if (value) |v| v.string else try self.symbols.getShapeName(m, .constant);
            const field_name = try self.symbols.getShapeName(m, .field);
            list.appendAssumeCapacity(.{
                .value = value_str,
                .field = field_name,
            });
        }
        try self.writeEnumShape(bld, id, list.items);
    }

    fn writeTraitEnumShape(
        self: ScriptGen,
        bld: *ContainerBuild,
        id: SmithyId,
        members: []const trt_constr.Enum.Member,
    ) !void {
        var list = try EnumList.initCapacity(self.arena, members.len);
        defer list.deinit();
        for (members) |m| {
            list.appendAssumeCapacity(.{
                .value = m.value,
                .field = try name_util.snakeCase(self.arena, m.name orelse m.value),
            });
        }
        try self.writeEnumShape(bld, id, list.items);
    }

    const EnumList = std.ArrayList(StrEnumMember);
    const StrEnumMember = struct {
        value: []const u8,
        field: []const u8,

        pub fn format(self: StrEnumMember, writer: *Writer) !void {
            try writer.appendFmt(".{{ \"{s}\", .{s} }}", .{ self.value, self.field });
        }

        pub fn asLiteralExpr(self: StrEnumMember, bld: *ContainerBuild) ExprBuild {
            return bld.x.structLiteral(
                null,
                &.{ bld.x.valueOf(self.value), bld.x.dot().raw(self.field) },
            );
        }
    };

    fn writeEnumShape(self: ScriptGen, bld: *ContainerBuild, id: SmithyId, members: []const StrEnumMember) !void {
        const context = .{ .self = self, .members = members };
        const Closures = struct {
            fn shape(ctx: @TypeOf(context), b: *ContainerBuild) !void {
                var literals = std.ArrayList(ExprBuild).init(ctx.self.arena);
                defer literals.deinit();

                try b.comment(.doc, "Used for backwards compatibility when adding new values.");
                try b.field("UNKNOWN").typing(b.x.typeOf([]const u8)).end();
                for (ctx.members) |m| {
                    try b.field(m.field).end();
                    try literals.append(m.asLiteralExpr(b));
                }

                try b.constant("ParseMap").assign(b.x.raw("std.StaticStringMap(@This())"));
                try b.constant("parse_map").assign(
                    b.x.call("ParseMap.initComptime", &.{
                        b.x.structLiteral(null, literals.items),
                    }),
                );

                try b.public().function("parse").arg("value", b.x.typeOf([]const u8))
                    .returns(b.x.This()).body(parse);

                try b.public().function("serialize").arg("self", b.x.This())
                    .returns(b.x.typeOf([]const u8)).bodyWith(ctx, serialize);
            }

            fn parse(b: *BlockBuild) !void {
                try b.returns().raw("parse_map.get(value) orelse .{ .UNKNOWN = value }").end();
            }

            fn serialize(ctx: @TypeOf(context), b: *BlockBuild) !void {
                try b.returns().switchWith(b.x.raw("self"), ctx, serializeSwitch).end();
            }

            fn serializeSwitch(ctx: @TypeOf(context), b: *zig.SwitchBuild) !void {
                try b.branch().case(b.x.valueOf(.UNKNOWN)).capture("s").body(b.x.raw("s"));
                for (ctx.members) |m| {
                    try b.branch().case(b.x.dot().raw(m.field)).body(b.x.valueOf(m.value));
                }
            }
        };

        const shape_name = try self.symbols.getShapeName(id, .type);
        try self.writeDocComment(bld, id, false);
        try bld.public().constant(shape_name).assign(
            bld.x.@"union"().bodyWith(context, Closures.shape),
        );
    }

    test "writeEnumShape" {
        var tester = try ScriptTester.init();
        defer tester.deinit();

        var symbols = try test_symbols.setup(
            tester.allocator(),
            &.{.enums_str},
        );
        defer symbols.deinit();

        var self = tester.initCodegen(&symbols);
        try self.writeShape(tester.build, SmithyId.of("test#Enum"));
        try self.writeShape(tester.build, SmithyId.of("test#EnumTrt"));

        const BODY =
            \\    /// Used for backwards compatibility when adding new values.
            \\    UNKNOWN: []const u8,
            \\    foo_bar,
            \\    baz_qux,
            \\
            \\    const ParseMap = std.StaticStringMap(@This());
            \\
            \\    const parse_map = ParseMap.initComptime(.{ .{ "FOO_BAR", .foo_bar }, .{ "baz$qux", .baz_qux } });
            \\
            \\    pub fn parse(value: []const u8) @This() {
            \\        return parse_map.get(value) orelse .{ .UNKNOWN = value };
            \\    }
            \\
            \\    pub fn serialize(self: @This()) []const u8 {
            \\        return switch (self) {
            \\            .UNKNOWN => |s| s,
            \\            .foo_bar => "FOO_BAR",
            \\            .baz_qux => "baz$qux",
            \\        };
            \\    }
            \\};
        ;
        try tester.expect("pub const Enum = union(enum) {\n" ++ BODY ++
            "\n\n" ++ "pub const EnumTrt = union(enum) {\n" ++ BODY);
    }

    fn writeIntEnumShape(self: ScriptGen, bld: *ContainerBuild, id: SmithyId, members: []const SmithyId) !void {
        const context = .{ .symbols = self.symbols, .members = members };
        const Closures = struct {
            fn shape(ctx: @TypeOf(context), b: *ContainerBuild) !void {
                for (ctx.members) |m| {
                    const shape_name = try ctx.symbols.getShapeName(m, .field);
                    const shape_value = trt_refine.EnumValue.get(ctx.symbols, m).?.integer;
                    try b.field(shape_name).assign(b.x.valueOf(shape_value));
                }
                try b.comment(.doc, "Used for backwards compatibility when adding new values.");
                try b.field("_").end();

                try b.public().function("parse").arg("value", b.x.typeOf(i32))
                    .returns(b.x.This()).body(parse);

                try b.public().function("serialize").arg("self", b.x.This())
                    .returns(b.x.typeOf(i32)).body(serialize);
            }

            fn parse(b: *BlockBuild) !void {
                try b.returns().raw("@enumFromInt(value)").end();
            }

            fn serialize(b: *BlockBuild) !void {
                try b.returns().raw("@intFromEnum(self)").end();
            }
        };

        const shape_name = try self.symbols.getShapeName(id, .type);
        try self.writeDocComment(bld, id, false);
        try bld.public().constant(shape_name).assign(
            bld.x.@"enum"().backedBy(bld.x.typeOf(i32)).bodyWith(context, Closures.shape),
        );
    }

    test "writeIntEnumShape" {
        var tester = try ScriptTester.init();
        defer tester.deinit();

        var symbols = try test_symbols.setup(
            tester.allocator(),
            &.{.enum_int},
        );
        defer symbols.deinit();

        var self = tester.initCodegen(&symbols);
        try self.writeShape(tester.build, SmithyId.of("test#IntEnum"));
        try tester.expect(
            \\/// An **integer-based** enumeration.
            \\pub const IntEnum = enum(i32) {
            \\    foo_bar = 8,
            \\    baz_qux = 9,
            \\    /// Used for backwards compatibility when adding new values.
            \\    _,
            \\
            \\    pub fn parse(value: i32) @This() {
            \\        return @enumFromInt(value);
            \\    }
            \\
            \\    pub fn serialize(self: @This()) i32 {
            \\        return @intFromEnum(self);
            \\    }
            \\};
        );
    }

    fn writeUnionShape(self: ScriptGen, bld: *ContainerBuild, id: SmithyId, members: []const SmithyId) !void {
        const shape_name = try self.symbols.getShapeName(id, .type);
        try self.writeDocComment(bld, id, false);

        const context = .{ .symbols = self.symbols, .members = members };
        try bld.public().constant(shape_name).assign(
            bld.x.@"union"().bodyWith(context, struct {
                fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
                    for (ctx.members) |m| {
                        const type_name = try ctx.symbols.getTypeName(m);
                        const member_name = try ctx.symbols.getShapeName(m, .field);
                        if (type_name.len > 0) {
                            try b.field(member_name).typing(b.x.raw(type_name)).end();
                        } else {
                            try b.field(member_name).end();
                        }
                    }
                }
            }.f),
        );
    }

    test "writeUnionShape" {
        var tester = try ScriptTester.init();
        defer tester.deinit();

        var symbols = try test_symbols.setup(
            tester.allocator(),
            &.{.union_str},
        );
        defer symbols.deinit();

        var self = tester.initCodegen(&symbols);
        try self.writeShape(tester.build, SmithyId.of("test#Union"));
        try tester.expect(
            \\pub const Union = union(enum) {
            \\    foo,
            \\    bar: i32,
            \\    baz: []const u8,
            \\};
        );
    }

    fn writeStructShape(self: ScriptGen, bld: *ContainerBuild, id: SmithyId, members: []const SmithyId) !void {
        const shape_name = try self.symbols.getShapeName(id, .type);
        try self.writeDocComment(bld, id, false);

        const context = .{ .self = self, .id = id, .members = members };
        try bld.public().constant(shape_name).assign(
            bld.x.@"struct"().bodyWith(context, struct {
                fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
                    const is_input = ctx.self.symbols.hasTrait(ctx.id, trt_refine.input_id);
                    try ctx.self.writeStructShapeError(b, ctx.id);
                    try ctx.self.writeStructShapeMixin(b, is_input, ctx.id);
                    for (ctx.members) |m| try ctx.self.writeStructShapeMember(b, is_input, m);
                }
            }.f),
        );
    }

    fn writeStructShapeError(self: ScriptGen, bld: *ContainerBuild, id: SmithyId) !void {
        const source = trt_refine.Error.get(self.symbols, id) orelse return;
        try self.hooks.writeErrorShape(self.arena, bld, self.symbols, .{
            .id = id,
            .source = source,
            .retryable = self.symbols.hasTrait(id, trt_behave.retryable_id),
            .code = trt_http.HttpError.get(self.symbols, id) orelse if (source == .client) 400 else 500,
        });
    }

    fn writeStructShapeMixin(self: ScriptGen, bld: *ContainerBuild, is_input: bool, id: SmithyId) !void {
        const mixins = self.symbols.getMixins(id) orelse return;
        for (mixins) |mix_id| {
            try self.writeStructShapeMixin(bld, is_input, mix_id);
            const mixin = (try self.symbols.getShape(mix_id)).structure;
            for (mixin) |m| {
                try self.writeStructShapeMember(bld, is_input, m);
            }
        }
    }

    fn writeStructShapeMember(self: ScriptGen, bld: *ContainerBuild, is_input: bool, id: SmithyId) !void {
        // https://smithy.io/2.0/spec/aggregate-types.html#structure-member-optionality
        const optional: bool = if (is_input) true else if (self.symbols.getTraits(id)) |bag| blk: {
            break :blk bag.has(trt_refine.client_optional_id) or
                !(bag.has(trt_refine.required_id) or bag.has(trt_refine.Default.id));
        } else true;

        const shape_name = try self.symbols.getShapeName(id, .field);
        var type_expr = bld.x.raw(try self.symbols.getTypeName(id));
        if (optional) type_expr = bld.x.typeOptional(type_expr);

        try self.writeDocComment(bld, id, true);
        const field = bld.field(shape_name).typing(type_expr);
        const assign: ?ExprBuild = blk: {
            if (optional) break :blk bld.x.valueOf(null);
            if (trt_refine.Default.get(self.symbols, id)) |json| {
                break :blk switch (try self.symbols.getShapeUnwrap(id)) {
                    .str_enum => bld.x.dot().raw(json.string),
                    .int_enum => bld.x.call("@enumFromInt", &.{bld.x.valueOf(json.integer)}),
                    else => unreachable,
                };
            }
            break :blk null;
        };
        if (assign) |a| try field.assign(a) else try field.end();
    }

    test "writeStructShape" {
        var tester = try ScriptTester.init();
        defer tester.deinit();

        var symbols = try test_symbols.setup(
            tester.allocator(),
            &.{ .structure, .err },
        );
        defer symbols.deinit();

        var self = tester.initCodegen(&symbols);
        try self.writeShape(tester.build, SmithyId.of("test#Struct"));
        try self.writeShape(tester.build, SmithyId.of("test#Error"));
        try tester.expect(
            \\pub const Struct = struct {
            \\    mixed: ?bool = null,
            \\    /// A **struct** member.
            \\    foo_bar: i32,
            \\    /// An **integer-based** enumeration.
            \\    baz_qux: IntEnum = @enumFromInt(8),
            \\};
            \\
            \\pub const Error = struct {
            \\    pub const source: ErrorSource = .client;
            \\
            \\    pub const code: u10 = 429;
            \\
            \\    pub const retryable = true;
            \\};
        );
    }

    fn writeOperationShapes(self: ScriptGen, bld: *ContainerBuild, id: SmithyId) !void {
        const operation = (try self.symbols.getShape(id)).operation;

        if (operation.input) |in_id| {
            const members = (try self.symbols.getShape(in_id)).structure;
            try self.writeStructShape(bld, in_id, members);
        }

        if (operation.output) |out_id| {
            const members = (try self.symbols.getShape(out_id)).structure;
            try self.writeStructShape(bld, out_id, members);
        }

        for (operation.errors) |err_id| {
            // We don't write directly since an error may be used by multiple operations.
            try self.symbols.enqueue(err_id);
        }
    }

    test "writeOperationShapes" {
        var tester = try ScriptTester.init();
        defer tester.deinit();

        var symbols = try test_symbols.setup(
            tester.allocator(),
            &.{.service},
        );
        defer symbols.deinit();

        var self = tester.initCodegen(&symbols);
        try self.writeOperationShapes(tester.build, SmithyId.of("test.serve#Operation"));
        try tester.expect(
            \\pub const OperationInput = struct {};
            \\
            \\pub const OperationOutput = struct {};
        );
        try testing.expectEqual(SmithyId.of("test.error#NotFound"), self.symbols.next());
    }

    fn writeOperationFunc(self: ScriptGen, bld: *ContainerBuild, id: SmithyId) !void {
        const service_errors = try self.symbols.getServiceErrors();
        const operation = (try self.symbols.getShape(id)).operation;
        const op_name = try self.symbols.getShapeName(id, .function);

        const errors_type = if (operation.errors.len + service_errors.len > 0)
            try self.writeOperationFuncError(bld, op_name, operation.errors, service_errors)
        else
            null;

        const shape_input: ?Hooks.OperationShape.Input = if (operation.input) |d| blk: {
            try self.symbols.markVisited(d);
            break :blk .{
                .identifier = "input",
                .type = try self.symbols.getTypeName(d),
            };
        } else null;

        const shape_output: ?[]const u8 = if (operation.output) |d| blk: {
            try self.symbols.markVisited(d);
            break :blk try self.symbols.getTypeName(d);
        } else null;

        const shape = Hooks.OperationShape{
            .id = id,
            .input = shape_input,
            .output_type = shape_output,
            .errors_type = errors_type,
        };
        const return_type = if (self.hooks.operationReturnType) |hook| blk: {
            const result = try hook(self.arena, self.symbols, shape);
            break :blk if (result) |s| bld.x.raw(s) else bld.x.typeOf(void);
        } else if (shape_output) |s|
            bld.x.raw(s)
        else
            bld.x.typeOf(void);

        const context = .{ .self = self, .shape = shape };
        const func1 = bld.public().function(op_name).arg("self", bld.x.This());
        const func2 = if (shape_input) |input| func1.arg(input.identifier, bld.x.raw(input.type)) else func1;
        try func2.returns(return_type).bodyWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *BlockBuild) !void {
                try ctx.self.hooks.writeOperationBody(ctx.self.arena, b, ctx.self.symbols, ctx.shape);
            }
        }.f);
    }

    fn writeOperationFuncError(
        self: ScriptGen,
        bld: *ContainerBuild,
        op_name: []const u8,
        op_errors: []const SmithyId,
        service_errors: []const SmithyId,
    ) ![]const u8 {
        const type_name = try std.fmt.allocPrint(self.arena, "{c}{s}Errors", .{
            std.ascii.toUpper(op_name[0]),
            op_name[1..op_name.len],
        });

        const context = .{ .self = self, .service_errors = service_errors, .op_errors = op_errors };
        try bld.public().constant(type_name).assign(bld.x.@"union"().bodyWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
                for (ctx.service_errors) |m| try ctx.self.writeOperationFuncErrorMember(b, m);
                for (ctx.op_errors) |m| try ctx.self.writeOperationFuncErrorMember(b, m);
            }
        }.f));

        return type_name;
    }

    fn writeOperationFuncErrorMember(self: ScriptGen, bld: *ContainerBuild, member: SmithyId) !void {
        const type_name = try self.symbols.getTypeName(member);
        var shape_name = try self.symbols.getShapeName(member, .field);
        inline for (.{ "_error", "_exception" }) |suffix| {
            if (std.ascii.endsWithIgnoreCase(shape_name, suffix)) {
                shape_name = shape_name[0 .. shape_name.len - suffix.len];
                break;
            }
        }

        try self.writeDocComment(bld, member, true);
        if (type_name.len > 0) {
            try bld.field(shape_name).typing(bld.x.raw(type_name)).end();
        } else {
            try bld.field(shape_name).end();
        }
    }

    test "writeOperationFunc" {
        var tester = try ScriptTester.init();
        defer tester.deinit();

        var symbols = try test_symbols.setup(
            tester.allocator(),
            &.{.service},
        );
        defer symbols.deinit();

        var self = tester.initCodegen(&symbols);
        try self.writeOperationFunc(tester.build, SmithyId.of("test.serve#Operation"));
        try tester.expect(
            \\pub const OperationErrors = union(enum) {
            \\    service: ServiceError,
            \\    not_found: NotFound,
            \\};
            \\
            \\pub fn operation(self: @This(), input: OperationInput) OperationOutput {
            \\    return undefined;
            \\}
        );
    }

    fn writeResourceShape(
        self: ScriptGen,
        bld: *ContainerBuild,
        id: SmithyId,
        resource: *const syb.SmithyResource,
    ) !void {
        const LIFECYCLE_OPS = &.{ "create", "put", "read", "update", "delete", "list" };
        const resource_name = try self.symbols.getShapeName(id, .type);
        const context = .{ .self = self, .id = id, .resource = resource };
        try bld.public().constant(resource_name).assign(bld.x.@"struct"().bodyWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
                if (ctx.self.hooks.writeResourceHead) |hook| {
                    try hook(ctx.self.arena, b, ctx.self.symbols, ctx.id, ctx.resource);
                }
                for (ctx.resource.identifiers) |d| {
                    try ctx.self.writeDocComment(b, d.shape, true);
                    const type_name = try ctx.self.symbols.getTypeName(d.shape);
                    const shape_name = try name_util.snakeCase(ctx.self.arena, d.name);
                    try b.field(shape_name).typing(b.x.raw(type_name)).end();
                }

                inline for (LIFECYCLE_OPS) |field| {
                    if (@field(ctx.resource, field)) |op_id| {
                        try ctx.self.writeOperationFunc(b, op_id);
                    }
                }
                for (ctx.resource.operations) |op_id| try ctx.self.writeOperationFunc(b, op_id);
                for (ctx.resource.collection_ops) |op_id| try ctx.self.writeOperationFunc(b, op_id);
            }
        }.f));

        inline for (LIFECYCLE_OPS) |field| {
            if (@field(resource, field)) |op_id| {
                try self.writeOperationShapes(bld, op_id);
            }
        }
        for (resource.operations) |op_id| try self.writeOperationShapes(bld, op_id);
        for (resource.collection_ops) |op_id| try self.writeOperationShapes(bld, op_id);
        for (resource.resources) |rsc_id| try self.symbols.enqueue(rsc_id);
    }

    test "writeResourceShape" {
        var tester = try ScriptTester.init();
        defer tester.deinit();

        var symbols = try test_symbols.setup(
            tester.allocator(),
            &.{.service},
        );
        defer symbols.deinit();

        var self = tester.initCodegen(&symbols);
        try self.writeShape(tester.build, SmithyId.of("test.serve#Resource"));
        try tester.expect(
            \\pub const Resource = struct {
            \\    forecast_id: []const u8,
            \\
            \\    pub const OperationErrors = union(enum) {
            \\        service: ServiceError,
            \\        not_found: NotFound,
            \\    };
            \\
            \\    pub fn operation(self: @This(), input: OperationInput) OperationOutput {
            \\        return undefined;
            \\    }
            \\};
            \\
            \\pub const OperationInput = struct {};
            \\
            \\pub const OperationOutput = struct {};
        );
    }

    fn writeServiceShape(
        self: ScriptGen,
        bld: *ContainerBuild,
        id: SmithyId,
        service: *const syb.SmithyService,
    ) !void {
        const service_name = try self.symbols.getShapeName(id, .type);
        try self.writeDocComment(bld, id, false);
        const context = .{ .self = self, .service = service };
        try bld.public().constant(service_name).assign(
            bld.x.@"struct"().bodyWith(context, struct {
                fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
                    if (ctx.self.hooks.writeServiceHead) |hook| {
                        try hook(ctx.self.arena, b, ctx.self.symbols, ctx.self.rules, ctx.service);
                    }
                    for (ctx.service.operations) |op_id| {
                        try ctx.self.writeOperationFunc(b, op_id);
                    }
                }
            }.f),
        );

        for (service.operations) |op_id| {
            try self.writeOperationShapes(bld, op_id);
        }

        for (service.resources) |rsc_id| try self.symbols.enqueue(rsc_id);
        for (service.errors) |err_id| try self.symbols.enqueue(err_id);
    }

    test "writeServiceShape" {
        var tester = try ScriptTester.init();
        defer tester.deinit();

        var symbols = try test_symbols.setup(
            tester.allocator(),
            &.{.service},
        );
        defer symbols.deinit();

        var self = tester.initCodegen(&symbols);
        try self.writeShape(tester.build, SmithyId.of("test.serve#Service"));
        try tester.expect(
            \\/// Some _service_...
            \\pub const Service = struct {
            \\    pub const OperationErrors = union(enum) {
            \\        service: ServiceError,
            \\        not_found: NotFound,
            \\    };
            \\
            \\    pub fn operation(self: @This(), input: OperationInput) OperationOutput {
            \\        return undefined;
            \\    }
            \\};
            \\
            \\pub const OperationInput = struct {};
            \\
            \\pub const OperationOutput = struct {};
        );

        try testing.expect(self.symbols.didVisit(SmithyId.of("test.serve#Resource")));
        try testing.expect(self.symbols.didVisit(SmithyId.of("test.error#NotFound")));
        try testing.expect(self.symbols.didVisit(SmithyId.of("test.error#ServiceError")));
    }

    fn writeDocComment(self: ScriptGen, bld: *ContainerBuild, id: SmithyId, target_fallback: bool) !void {
        const docs = trt_docs.Documentation.get(self.symbols, id) orelse blk: {
            if (!target_fallback) break :blk null;
            const shape = self.symbols.getShape(id) catch break :blk null;
            break :blk switch (shape) {
                .target => |t| trt_docs.Documentation.get(self.symbols, t),
                else => null,
            };
        } orelse return;

        try bld.commentMarkdownWith(.doc, md.html.CallbackContext{
            .allocator = self.arena,
            .html = docs,
        }, md.html.callback);
    }
};

const TEST_POLICY = Policy{
    .unknown_shape = .skip,
    .invalid_root = .skip,
    .shape_codegen_fail = .skip,
};

const TEST_HOOKS = Hooks{
    .writeErrorShape = hookErrorShape,
    .writeOperationBody = hookOperationBody,
};

fn hookErrorShape(_: Allocator, bld: *ContainerBuild, _: *const SymbolsProvider, shape: Hooks.ErrorShape) !void {
    try bld.public().constant("source").typing(bld.x.raw("ErrorSource"))
        .assign(bld.x.valueOf(shape.source));

    try bld.public().constant("code").typing(bld.x.typeOf(u10))
        .assign(bld.x.valueOf(shape.code));

    try bld.public().constant("retryable").assign(bld.x.valueOf(shape.retryable));
}

fn hookOperationBody(_: Allocator, bld: *BlockBuild, _: *const SymbolsProvider, _: Hooks.OperationShape) !void {
    try bld.returns().raw("undefined").end();
}

const ScriptTester = struct {
    did_end: bool = false,
    arena: *std.heap.ArenaAllocator,
    build: *ContainerBuild,
    issues: *IssuesBag,

    pub fn init() !ScriptTester {
        const arena = try test_alloc.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(test_alloc);
        errdefer {
            arena.deinit();
            test_alloc.destroy(arena);
        }

        const build = try test_alloc.create(ContainerBuild);
        errdefer test_alloc.destroy(build);
        build.* = ContainerBuild.init(test_alloc);
        errdefer build.deinit();

        const issues = try test_alloc.create(IssuesBag);
        errdefer test_alloc.destroy(build);
        issues.* = IssuesBag.init(test_alloc);

        return .{
            .arena = arena,
            .build = build,
            .issues = issues,
        };
    }

    pub fn deinit(self: *ScriptTester) void {
        if (!self.did_end) self.build.deinit();
        test_alloc.destroy(self.build);

        self.arena.deinit();
        test_alloc.destroy(self.arena);

        self.issues.deinit();
        test_alloc.destroy(self.issues);
    }

    pub fn allocator(self: *ScriptTester) Allocator {
        return self.arena.allocator();
    }

    pub fn initCodegen(self: *ScriptTester, symbols: *SymbolsProvider) ScriptGen {
        const alloc = self.arena.allocator();
        return ScriptGen{
            .arena = alloc,
            .hooks = TEST_HOOKS,
            .policy = TEST_POLICY,
            .issues = self.issues,
            .symbols = symbols,
            .rules = undefined,
        };
    }

    pub fn expect(self: *ScriptTester, comptime expected: []const u8) !void {
        const script = try self.build.consume();
        self.did_end = true;
        defer script.deinit(test_alloc);

        try Writer.expectValue(expected, script);
    }
};
