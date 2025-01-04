const std = @import("std");
const Allocator = std.mem.Allocator;
const zig = @import("codmod").zig;
const shape = @import("shape.zig");
const cfg = @import("../config.zig");
const SmithyId = @import("../model.zig").SmithyId;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const trt_http = @import("../traits/http.zig");
const trt_refine = @import("../traits/refine.zig");
const trt_proto = @import("../traits/protocol.zig");

pub fn operationErrorScheme(
    arena: Allocator,
    exp: zig.ExprBuild,
    members: []const SymbolsProvider.Error,
) !zig.ExprBuild {
    var scheme = std.ArrayList(zig.ExprBuild).init(arena);
    for (members) |member| {
        const name_api = exp.valueOf(member.name_api);
        const name_zig = exp.valueOf(member.name_zig);
        try scheme.append(exp.structLiteral(null, &.{ name_api, name_zig, exp.structLiteral(null, &.{}) }));
    }

    return exp.structLiteral(null, &.{
        exp.id("SerialType").valueOf(.tagged_union),
        exp.structLiteral(null, try scheme.toOwnedSlice()),
    });
}

pub fn operationTransportScheme(
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
    var scheme = std.ArrayList(zig.ExprBuild).init(arena);

    for (members) |mid| {
        var options = SchemeOptions{
            .is_local = false,
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

                try meta.append(exp.structAssign("payload", buildMeta(exp, scheme, kind, value)));
            } else if (traits.has(trt_http.http_response_code_id)) {
                const kind = exp.id(cfg.runtime_scope).dot().id("MetaTransport").valueOf(.status_code);
                try meta.append(exp.structAssign("transport", buildMeta(exp, scheme, kind, null)));
            } else if (traits.has(trt_http.http_label_id)) {
                const kind = exp.id(cfg.runtime_scope).dot().id("MetaLabel").valueOf(.path_shape);
                try labels.append(buildMeta(exp, scheme, kind, null));
                if ((try symbols.getShapeUnwrap(mid)) == .timestamp) options.timestamp_fmt = .date_time;
            } else if (traits.has(trt_http.http_query_params_id)) {
                const kind = base_param.valueOf(.query_map);
                try params.append(buildMeta(exp, scheme, kind, null));
            } else if (trt_http.HttpQuery.get(symbols, mid)) |query| {
                const kind = base_param.valueOf(.query_shape);
                try params.append(buildMeta(exp, scheme, kind, exp.valueOf(query)));
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
                try params.append(buildMeta(exp, scheme, kind, exp.valueOf(header)));
            } else if (trt_http.HttpPrefixHeaders.get(symbols, mid)) |prefix| {
                const kind = base_param.valueOf(.header_map);
                try params.append(buildMeta(exp, scheme, kind, exp.valueOf(prefix)));
            } else {
                break :blk false;
            }

            break :blk true;
        } else false;

        if (!did_consume) {
            if (symbols.service_xml_traits and symbols.hasTrait(mid, trt_proto.xml_attribute_id)) {
                try attrs.append(exp.valueOf(scheme.items.len));
            } else {
                try body.append(exp.valueOf(scheme.items.len));
            }
        }

        try scheme.append(try structMemberScheme(arena, symbols, exp, is_input, mid, options));
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
        exp.structAssign("members", exp.structLiteral(null, try scheme.toOwnedSlice())),
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

pub const SchemeOptions = struct {
    /// Whether the scheme is added in the types file.
    is_local: bool = true,
    timestamp_fmt: trt_proto.TimestampFormat.Value = .epoch_seconds,
};

fn structMemberScheme(
    arena: Allocator,
    symbols: *SymbolsProvider,
    exp: zig.ExprBuild,
    is_input: bool,
    id: SmithyId,
    options: SchemeOptions,
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

    try fields.append(exp.structAssign("scheme", try shapeScheme(arena, symbols, exp, id, options)));

    return exp.structLiteral(null, try fields.toOwnedSlice());
}

fn shapeScheme(
    arena: Allocator,
    symbols: *SymbolsProvider,
    exp: zig.ExprBuild,
    id: SmithyId,
    options: SchemeOptions,
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

            const z = try shapeScheme(arena, symbols, exp, member, options);
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

            try fields.append(exp.structAssign("key", try shapeScheme(arena, symbols, exp, key_id, options)));
            try fields.append(exp.structAssign("val", try shapeScheme(arena, symbols, exp, val_id, options)));
        },
        .tagged_union, .structure => {
            const nid = switch (try symbols.getShape(id)) {
                .target => |tid| tid,
                else => id,
            };

            const name = try symbols.getShapeName(nid, .pascal, .{
                .suffix = "_scheme",
            });

            if (options.is_local) {
                return exp.id(name);
            } else {
                return exp.id(cfg.types_scope).dot().id(name);
            }
        },
        .document => {
            // AWS usage: controltower, identitystore, inspector-scan, bedrock-agent-runtime, marketplace-catalog
            @panic("Document shape scheme construction not implemented");
        },
        .operation, .resource, .service, .target => unreachable,
    }

    return exp.structLiteral(null, try fields.toOwnedSlice());
}

pub fn writeUnionScheme(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    id: SmithyId,
    members: []const SmithyId,
    options: SchemeOptions,
) !void {
    var fields = std.ArrayList(zig.ExprBuild).init(arena);
    try fields.append(bld.x.structAssign("shape", bld.x.id("SerialType").valueOf(.tagged_union)));

    var member_options = options;
    member_options.is_local = true;

    var scheme = std.ArrayList(zig.ExprBuild).init(arena);
    for (members) |mid| {
        try scheme.append(try structMemberScheme(arena, symbols, bld.x, false, mid, options));
    }
    try fields.append(bld.x.structAssign("members", bld.x.structLiteral(null, try scheme.toOwnedSlice())));

    const scheme_name = try symbols.getShapeName(id, .pascal, .{ .suffix = "_scheme" });
    try bld.public().constant(scheme_name).assign(
        bld.x.structLiteral(null, try fields.toOwnedSlice()),
    );
}

pub fn writeStructScheme(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    id: SmithyId,
    members: []const SmithyId,
    is_input: bool,
    options: SchemeOptions,
) !void {
    var fields = std.ArrayList(zig.ExprBuild).init(arena);
    try fields.append(bld.x.structAssign("shape", bld.x.id("SerialType").valueOf(.structure)));

    var member_options = options;
    member_options.is_local = true;

    var scheme = std.ArrayList(zig.ExprBuild).init(arena);
    var attrs = std.ArrayList(zig.ExprBuild).init(arena);
    var body = std.ArrayList(zig.ExprBuild).init(arena);

    for (members) |mid| {
        if (symbols.service_xml_traits and symbols.hasTrait(mid, trt_proto.xml_attribute_id)) {
            if (attrs.items.len == 0) {
                const len = scheme.items.len;
                body = try .initCapacity(arena, len);
                for (0..len) |i| body.appendAssumeCapacity(bld.x.valueOf(i));
            }

            try attrs.append(bld.x.valueOf(scheme.items.len));
        } else if (attrs.items.len > 0) {
            try body.append(bld.x.valueOf(scheme.items.len));
        }

        try scheme.append(try structMemberScheme(arena, symbols, bld.x, is_input, mid, options));
    }

    if (attrs.items.len > 0) {
        try fields.append(bld.x.structAssign("attr_ids", bld.x.structLiteral(null, try attrs.toOwnedSlice())));
        try fields.append(bld.x.structAssign("body_ids", bld.x.structLiteral(null, try body.toOwnedSlice())));
    }

    try fields.append(bld.x.structAssign("members", bld.x.structLiteral(null, try scheme.toOwnedSlice())));

    const scheme_name = try symbols.getShapeName(id, .pascal, .{ .suffix = "_scheme" });
    try bld.public().constant(scheme_name).assign(
        bld.x.structLiteral(null, try fields.toOwnedSlice()),
    );
}
