const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zig = @import("codmod").zig;
const Writer = @import("codmod").CodegenWriter;
const shape = @import("shape.zig");
const cfg = @import("../config.zig");
const SmithyId = @import("../model.zig").SmithyId;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const trt_http = @import("../traits/http.zig");
const trt_refine = @import("../traits/refine.zig");
const trt_proto = @import("../traits/protocol.zig");

pub fn operationErrorSchema(
    arena: Allocator,
    exp: zig.ExprBuild,
    members: []const SymbolsProvider.Error,
) !zig.ExprBuild {
    var schema = std.ArrayList(zig.ExprBuild).init(arena);
    for (members) |member| {
        const name_api = exp.valueOf(member.name_api);
        const name_zig = exp.valueOf(member.name_zig);
        try schema.append(exp.structLiteral(null, &.{ name_api, name_zig, exp.structLiteral(null, &.{}) }));
    }

    return exp.structLiteral(null, &.{
        exp.id("SerialType").valueOf(.tagged_union),
        exp.structLiteral(null, try schema.toOwnedSlice()),
    });
}

pub fn operationTransportSchema(
    arena: Allocator,
    symbols: *SymbolsProvider,
    exp: zig.ExprBuild,
    id: SmithyId,
) !zig.ExprBuild {
    const is_input = symbols.hasTrait(id, trt_refine.input_id);
    const base_param = exp.id(cfg.runtime_scope).dot().id("MetaParam");
    const members = try shape.listStructMembersAndMixins(symbols, id);

    var fields = std.ArrayList(zig.ExprBuild).init(arena);
    var meta = std.ArrayList(zig.ExprBuild).init(arena);
    var labels = std.ArrayList(zig.ExprBuild).init(arena);
    var params = std.ArrayList(zig.ExprBuild).init(arena);
    var body = std.ArrayList(zig.ExprBuild).init(arena);
    var attrs = std.ArrayList(zig.ExprBuild).init(arena);
    var schema = std.ArrayList(zig.ExprBuild).init(arena);

    for (members) |mid| {
        var options = SchemaOptions{
            .at_schemas_file = false,
            .timestamp_fmt = symbols.service_timestamp_fmt,
        };

        const did_consume = if (symbols.getTraits(mid)) |traits| blk: {
            if (traits.has(trt_http.http_payload_id)) {
                const media_type = trt_proto.MediaType.get(symbols, mid) orelse switch (try symbols.getShape(mid)) {
                    .target => |d| trt_proto.MediaType.get(symbols, d),
                    else => null,
                };

                const base_kind = exp.id(cfg.runtime_scope).dot().id("MetaPayload");
                const kind, const value = if (media_type) |media|
                    .{ base_kind.valueOf(.media), exp.valueOf(media) }
                else
                    .{ base_kind.valueOf(.shape), null };

                try meta.append(exp.structAssign("payload", buildMeta(exp, schema, kind, value)));
            } else if (traits.has(trt_http.http_response_code_id)) {
                const kind = exp.id(cfg.runtime_scope).dot().id("MetaTransport").valueOf(.status_code);
                try meta.append(exp.structAssign("transport", buildMeta(exp, schema, kind, null)));
            } else if (traits.has(trt_http.http_label_id)) {
                const kind = exp.id(cfg.runtime_scope).dot().id("MetaLabel").valueOf(.path_shape);
                try labels.append(buildMeta(exp, schema, kind, null));
                if ((try symbols.getShapeUnwrap(mid)) == .timestamp) options.timestamp_fmt = .date_time;
            } else if (traits.has(trt_http.http_query_params_id)) {
                const kind = base_param.valueOf(.query_map);
                try params.append(buildMeta(exp, schema, kind, null));
            } else if (trt_http.HttpQuery.get(symbols, mid)) |query| {
                const kind = base_param.valueOf(.query_shape);
                try params.append(buildMeta(exp, schema, kind, exp.valueOf(query)));
                if ((try symbols.getShapeUnwrap(mid)) == .timestamp) options.timestamp_fmt = .date_time;
            } else if (trt_http.HttpHeader.get(symbols, mid)) |header| {
                const has_media = symbols.hasTrait(mid, trt_proto.MediaType.id) or switch (try symbols.getShape(mid)) {
                    .target => |d| symbols.hasTrait(d, trt_proto.MediaType.id),
                    else => false,
                };
                const kind = if (has_media)
                    base_param.valueOf(.header_base64)
                else
                    base_param.valueOf(.header_shape);

                if ((try symbols.getShapeUnwrap(mid)) == .timestamp) options.timestamp_fmt = .http_date;
                try params.append(buildMeta(exp, schema, kind, exp.valueOf(header)));
            } else if (trt_http.HttpPrefixHeaders.get(symbols, mid)) |prefix| {
                const kind = base_param.valueOf(.header_map);
                try params.append(buildMeta(exp, schema, kind, exp.valueOf(prefix)));
            } else {
                break :blk false;
            }

            break :blk true;
        } else false;

        if (!did_consume) {
            if (symbols.service_xml_traits and symbols.hasTrait(mid, trt_proto.xml_attribute_id)) {
                try attrs.append(exp.valueOf(schema.items.len));
            } else {
                try body.append(exp.valueOf(schema.items.len));
            }
        }

        try schema.append(try structMemberSchema(arena, symbols, exp, is_input, mid, options));
    }

    if (labels.items.len > 0) {
        try meta.append(exp.structAssign("labels", exp.structLiteral(null, try labels.toOwnedSlice())));
    }

    if (params.items.len > 0) {
        try meta.append(exp.structAssign("params", exp.structLiteral(null, try params.toOwnedSlice())));
    }

    const name_api = blk: {
        if (symbols.service_xml_traits) if (trt_proto.XmlName.get(symbols, id)) |name| break :blk name;
        break :blk try symbols.getShapeName(id, .pascal, .{});
    };
    try fields.append(exp.structAssign("name_api", exp.valueOf(name_api)));

    if (symbols.service_xml_traits) if (trt_proto.XmlNamespace.get(symbols, id)) |ns| {
        try fields.append(exp.structAssign("ns_url", exp.valueOf(ns.uri)));
        if (ns.prefix) |pre| try fields.append(exp.structAssign("ns_prefix", exp.valueOf(pre)));
    };

    try fields.append(exp.structAssign("meta", exp.structLiteral(null, try meta.toOwnedSlice())));

    if (attrs.items.len > 0) {
        try fields.append(exp.structAssign("attr_ids", exp.structLiteral(null, try attrs.toOwnedSlice())));
    }

    try fields.appendSlice(&.{
        exp.structAssign("body_ids", exp.structLiteral(null, try body.toOwnedSlice())),
        exp.structAssign("members", exp.structLiteral(null, try schema.toOwnedSlice())),
    });

    return exp.structLiteral(null, try fields.toOwnedSlice());
}

fn buildMeta(
    exp: zig.ExprBuild,
    indexer: std.ArrayList(zig.ExprBuild),
    kind: zig.ExprBuild,
    value: ?zig.ExprBuild,
) zig.ExprBuild {
    const idx_exp = exp.valueOf(indexer.items.len);
    if (value) |val| {
        return exp.structLiteral(null, &.{ kind, idx_exp, val });
    } else {
        return exp.structLiteral(null, &.{ kind, idx_exp });
    }
}

pub const SchemaOptions = struct {
    /// Whether the current active write target is the dedicated schemas file.
    at_schemas_file: bool,
    timestamp_fmt: trt_proto.TimestampFormat.Value = .epoch_seconds,
};

fn structMemberSchema(
    arena: Allocator,
    symbols: *SymbolsProvider,
    exp: zig.ExprBuild,
    is_input: bool,
    id: SmithyId,
    options: SchemaOptions,
) anyerror!zig.ExprBuild {
    var fields = std.ArrayList(zig.ExprBuild).init(arena);

    const name_api = blk: {
        if (symbols.service_xml_traits) {
            if (trt_proto.XmlName.get(symbols, id)) |name| break :blk name;
        } else {
            if (trt_proto.JsonName.get(symbols, id)) |name| break :blk name;
        }
        break :blk try symbols.getShapeName(id, .pascal, .{});
    };
    try fields.append(exp.structAssign("name_api", exp.valueOf(name_api)));

    const name_zig = exp.valueOf(try symbols.getShapeName(id, .snake, .{}));
    try fields.append(exp.structAssign("name_zig", name_zig));

    if (symbols.service_xml_traits) if (trt_proto.XmlNamespace.get(symbols, id)) |ns| {
        try fields.append(exp.structAssign("ns_url", exp.valueOf(ns.uri)));
        if (ns.prefix) |pre| try fields.append(exp.structAssign("ns_prefix", exp.valueOf(pre)));
    };

    const is_required = !shape.isStructMemberOptional(symbols, id, is_input);
    if (is_required) try fields.append(exp.structAssign("required", exp.valueOf(true)));

    try fields.append(exp.structAssign("schema", try describeShapeSchema(arena, symbols, exp, id, options)));

    return exp.structLiteral(null, try fields.toOwnedSlice());
}

fn describeShapeSchema(
    arena: Allocator,
    symbols: *SymbolsProvider,
    exp: zig.ExprBuild,
    id: SmithyId,
    options: SchemaOptions,
) !zig.ExprBuild {
    var fields = std.ArrayList(zig.ExprBuild).init(arena);

    const exp_type = exp.id("SerialType");
    switch (try symbols.getShapeUnwrap(id)) {
        inline .boolean,
        .byte,
        .short,
        .integer,
        .long,
        .float,
        .double,
        .blob,
        .string,
        .int_enum,
        .str_enum,
        .trt_enum,
        .big_integer,
        .big_decimal,
        => |_, g| try fields.append(exp.structAssign("shape", exp_type.valueOf(g))),
        .unit => try fields.append(exp.structAssign("shape", exp_type.valueOf(.none))),
        .timestamp => {
            const format = trt_proto.TimestampFormat.get(symbols, id) orelse switch (try symbols.getShape(id)) {
                .target => |d| trt_proto.TimestampFormat.get(symbols, d) orelse options.timestamp_fmt,
                else => options.timestamp_fmt,
            };
            const kind = switch (format) {
                .date_time => exp_type.valueOf(.timestamp_date_time),
                .http_date => exp_type.valueOf(.timestamp_http_date),
                .epoch_seconds => exp_type.valueOf(.timestamp_epoch_seconds),
            };
            try fields.append(exp.structAssign("shape", kind));
        },
        .list => |member| {
            const kind = switch (shape.listType(symbols, id)) {
                .dense => exp_type.valueOf(.list_dense),
                .sparse => exp_type.valueOf(.list_sparse),
                .set => exp_type.valueOf(.set),
            };
            try fields.append(exp.structAssign("shape", kind));

            if (symbols.service_xml_traits) {
                if (symbols.hasTrait(id, trt_proto.xml_flattened_id)) {
                    try fields.append(exp.structAssign("flatten", exp.valueOf(true)));
                } else if (trt_proto.XmlName.get(symbols, member)) |name| {
                    try fields.append(exp.structAssign("name_member", exp.valueOf(name)));
                }
            }

            const z = try describeShapeSchema(arena, symbols, exp, member, options);
            try fields.append(exp.structAssign("member", z));
        },
        .map => |members| {
            const key_id, const val_id = members;
            try fields.append(exp.structAssign("shape", exp_type.valueOf(.map)));

            if (symbols.hasTrait(id, trt_refine.sparse_id)) {
                try fields.append(exp.structAssign("sparse", exp.valueOf(true)));
            }

            if (symbols.service_xml_traits) {
                if (symbols.hasTrait(id, trt_proto.xml_flattened_id)) {
                    try fields.append(exp.structAssign("flatten", exp.valueOf(true)));
                }

                if (trt_proto.XmlName.get(symbols, key_id)) |name| {
                    try fields.append(exp.structAssign("name_key", exp.valueOf(name)));
                }

                if (trt_proto.XmlName.get(symbols, val_id)) |name| {
                    try fields.append(exp.structAssign("name_value", exp.valueOf(name)));
                }
            }

            try fields.append(exp.structAssign("key", try describeShapeSchema(arena, symbols, exp, key_id, options)));
            try fields.append(exp.structAssign("val", try describeShapeSchema(arena, symbols, exp, val_id, options)));
        },
        .tagged_union, .structure => {
            const nid = switch (try symbols.getShape(id)) {
                .target => |tid| tid,
                else => id,
            };

            const name = try symbols.getShapeName(nid, .pascal, .{
                .suffix = "_schema",
            });

            if (options.at_schemas_file) {
                return exp.id(name);
            } else {
                return exp.id(cfg.schemas_scope).dot().id(name);
            }
        },
        .document => {
            // AWS usage: controltower, identitystore, inspector-scan, bedrock-agent-runtime, marketplace-catalog
            @panic("Document shape schema construction not implemented");
        },
        .operation, .resource, .service, .target => unreachable,
    }

    return exp.structLiteral(null, try fields.toOwnedSlice());
}

pub fn writeShapeSchema(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    id: SmithyId,
    options: SchemaOptions,
) !void {
    switch (try symbols.getShape(id)) {
        .tagged_union => |m| try writeUnionSchema(arena, symbols, bld, id, m, options),
        .structure => {
            const is_input = symbols.hasTrait(id, trt_refine.input_id);
            const flat_members = try shape.listStructMembersAndMixins(symbols, id);
            try writeStructSchema(arena, symbols, bld, id, flat_members, is_input, options);
        },
        else => {},
    }
}

fn writeUnionSchema(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    id: SmithyId,
    members: []const SmithyId,
    options: SchemaOptions,
) !void {
    var fields = std.ArrayList(zig.ExprBuild).init(arena);
    try fields.append(bld.x.structAssign("shape", bld.x.id("SerialType").valueOf(.tagged_union)));

    var member_options = options;
    member_options.at_schemas_file = true;

    var schema = std.ArrayList(zig.ExprBuild).init(arena);
    for (members) |mid| {
        try schema.append(try structMemberSchema(arena, symbols, bld.x, false, mid, options));
    }
    try fields.append(bld.x.structAssign("members", bld.x.structLiteral(null, try schema.toOwnedSlice())));

    const schema_name = try symbols.getShapeName(id, .pascal, .{ .suffix = "_schema" });
    try bld.public().constant(schema_name).assign(
        bld.x.structLiteral(null, try fields.toOwnedSlice()),
    );
}

test "write union schema" {
    try schemaTester(.union_str, SmithyId.of("test#Union"), .{
        .at_schemas_file = true,
    },
        \\pub const Union_schema = .{ .shape = SerialType.tagged_union, .members = .{
        \\    .{
        \\        .name_api = "FOO",
        \\        .name_zig = "foo",
        \\        .schema = .{.shape = SerialType.none},
        \\    },
        \\    .{
        \\        .name_api = "BAR",
        \\        .name_zig = "bar",
        \\        .schema = .{.shape = SerialType.integer},
        \\    },
        \\    .{
        \\        .name_api = "BAZ",
        \\        .name_zig = "baz",
        \\        .schema = .{.shape = SerialType.string},
        \\    },
        \\} };
    );
}

fn writeStructSchema(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    id: SmithyId,
    members: []const SmithyId,
    is_input: bool,
    options: SchemaOptions,
) !void {
    var fields = std.ArrayList(zig.ExprBuild).init(arena);
    try fields.append(bld.x.structAssign("shape", bld.x.id("SerialType").valueOf(.structure)));

    var member_options = options;
    member_options.at_schemas_file = true;

    var schema = std.ArrayList(zig.ExprBuild).init(arena);
    var attrs = std.ArrayList(zig.ExprBuild).init(arena);
    var body = std.ArrayList(zig.ExprBuild).init(arena);

    for (members) |mid| {
        if (symbols.service_xml_traits and symbols.hasTrait(mid, trt_proto.xml_attribute_id)) {
            if (attrs.items.len == 0) {
                const len = schema.items.len;
                body = try .initCapacity(arena, len);
                for (0..len) |i| body.appendAssumeCapacity(bld.x.valueOf(i));
            }

            try attrs.append(bld.x.valueOf(schema.items.len));
        } else if (attrs.items.len > 0) {
            try body.append(bld.x.valueOf(schema.items.len));
        }

        try schema.append(try structMemberSchema(arena, symbols, bld.x, is_input, mid, options));
    }

    if (attrs.items.len > 0) {
        try fields.append(bld.x.structAssign("attr_ids", bld.x.structLiteral(null, try attrs.toOwnedSlice())));
        try fields.append(bld.x.structAssign("body_ids", bld.x.structLiteral(null, try body.toOwnedSlice())));
    }

    try fields.append(bld.x.structAssign("members", bld.x.structLiteral(null, try schema.toOwnedSlice())));

    const schema_name = try symbols.getShapeName(id, .pascal, .{ .suffix = "_schema" });
    try bld.public().constant(schema_name).assign(
        bld.x.structLiteral(null, try fields.toOwnedSlice()),
    );
}

test "write struct schema" {
    try schemaTester(.structure, SmithyId.of("test#Struct"), .{
        .at_schemas_file = false,
    },
        \\pub const Struct_schema = .{ .shape = SerialType.structure, .members = .{
        \\    .{
        \\        .name_api = "fooBar",
        \\        .name_zig = "foo_bar",
        \\        .required = true,
        \\        .schema = .{.shape = SerialType.string},
        \\    },
        \\    .{
        \\        .name_api = "bazQux",
        \\        .name_zig = "baz_qux",
        \\        .required = true,
        \\        .schema = .{.shape = SerialType.int_enum},
        \\    },
        \\    .{
        \\        .name_api = "mixed",
        \\        .name_zig = "mixed",
        \\        .schema = .{.shape = SerialType.boolean},
        \\    },
        \\} };
    );
}

fn schemaTester(part: test_symbols.Part, id: SmithyId, options: SchemaOptions, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var symbols = try test_symbols.setup(arena_alloc, part);
    defer symbols.deinit();

    var buffer = std.ArrayList(u8).init(arena_alloc);
    defer buffer.deinit();

    var build = zig.ContainerBuild.init(arena_alloc);
    writeShapeSchema(arena_alloc, &symbols, &build, id, options) catch |err| {
        build.deinit();
        return err;
    };

    var codegen = Writer.init(arena_alloc, buffer.writer().any());
    defer codegen.deinit();

    const container = build.consume() catch |err| {
        build.deinit();
        return err;
    };

    codegen.appendValue(container) catch |err| {
        container.deinit(arena_alloc);
        return err;
    };

    try testing.expectEqualStrings(expected, buffer.items);
}
