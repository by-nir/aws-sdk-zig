const std = @import("std");
const Allocator = std.mem.Allocator;
const zig = @import("razdaz").zig;
const shape = @import("shape.zig");
const cfg = @import("../config.zig");
const SmithyId = @import("../model.zig").SmithyId;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const trt_http = @import("../traits/http.zig");
const trt_refine = @import("../traits/refine.zig");
const trt_protocol = @import("../traits/protocol.zig");
const JsonName = trt_protocol.JsonName;
const MediaType = trt_protocol.MediaType;
const TimestampFormat = trt_protocol.TimestampFormat;

pub fn operationErrorScheme(
    arena: Allocator,
    exp: zig.ExprBuild,
    members: []const SymbolsProvider.Error,
) !zig.ExprBuild {
    var scheme = std.ArrayList(zig.ExprBuild).init(arena);
    for (members) |member| {
        const name_api = exp.valueOf(member.name_api);
        const name_field = exp.valueOf(member.name_field);
        try scheme.append(exp.structLiteral(null, &.{ name_api, name_field, exp.structLiteral(null, &.{}) }));
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
    const members = (try symbols.getShape(id)).structure;
    const is_input = symbols.hasTrait(id, trt_refine.input_id);
    const base_param = exp.id(cfg.runtime_scope).dot().id("MetaParam");

    var meta = std.ArrayList(zig.ExprBuild).init(arena);
    var labels = std.ArrayList(zig.ExprBuild).init(arena);
    var params = std.ArrayList(zig.ExprBuild).init(arena);
    var body = std.ArrayList(zig.ExprBuild).init(arena);
    var scheme = std.ArrayList(zig.ExprBuild).init(arena);

    for (members) |mid| {
        var options = SchemeOptions{
            .timestamp_fmt = symbols.service_timestamp_fmt,
        };

        const did_consume = if (symbols.getTraits(mid)) |traits| blk: {
            if (traits.has(trt_http.http_payload_id)) {
                const media_type = MediaType.get(symbols, mid) orelse switch (try symbols.getShape(mid)) {
                    .target => |d| MediaType.get(symbols, d),
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
                const has_media = symbols.hasTrait(mid, MediaType.id) or switch (try symbols.getShape(mid)) {
                    .target => |d| symbols.hasTrait(d, MediaType.id),
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

        if (!did_consume) try body.append(exp.valueOf(scheme.items.len));
        try scheme.append(try structMemberScheme(arena, symbols, exp, is_input, mid, options));
    }

    if (labels.items.len > 0) {
        try meta.append(exp.structAssign("labels", exp.structLiteral(null, try labels.toOwnedSlice())));
    }

    if (params.items.len > 0) {
        try meta.append(exp.structAssign("params", exp.structLiteral(null, try params.toOwnedSlice())));
    }

    return exp.structLiteral(null, &.{
        exp.structLiteral(null, try meta.toOwnedSlice()),
        exp.structLiteral(null, try body.toOwnedSlice()),
        exp.structLiteral(null, try scheme.toOwnedSlice()),
    });
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

const SchemeOptions = struct {
    timestamp_fmt: TimestampFormat.Value = .epoch_seconds,
};

fn shapeScheme(
    arena: Allocator,
    symbols: *SymbolsProvider,
    exp: zig.ExprBuild,
    id: SmithyId,
    options: SchemeOptions,
) !zig.ExprBuild {
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
        => |_, g| return exp.structLiteral(null, &.{exp_type.valueOf(g)}),
        .timestamp => {
            const format = TimestampFormat.get(symbols, id) orelse switch (try symbols.getShape(id)) {
                .target => |d| TimestampFormat.get(symbols, d) orelse options.timestamp_fmt,
                else => options.timestamp_fmt,
            };

            const kind = switch (format) {
                .date_time => exp.id("SerialType").valueOf(.timestamp_date_time),
                .http_date => exp.id("SerialType").valueOf(.timestamp_http_date),
                .epoch_seconds => exp.id("SerialType").valueOf(.timestamp_epoch_seconds),
            };
            return exp.structLiteral(null, &.{kind});
        },
        .list => |member| {
            const member_scheme = try shapeScheme(arena, symbols, exp, member, options);
            const member_kind = switch (shape.listType(symbols, id)) {
                .dense => exp_type.valueOf(.list_dense),
                .sparse => exp_type.valueOf(.list_sparse),
                .set => exp_type.valueOf(.set),
            };
            return exp.structLiteral(null, &.{ member_kind, member_scheme });
        },
        .map => |members| {
            const sparse = exp.valueOf(symbols.hasTrait(id, trt_refine.sparse_id));
            const key_scheme = try shapeScheme(arena, symbols, exp, members[0], options);
            const val_scheme = try shapeScheme(arena, symbols, exp, members[1], options);
            return exp.structLiteral(null, &.{ exp_type.valueOf(.map), sparse, key_scheme, val_scheme });
        },
        .tagged_union => |members| {
            var schemes = std.ArrayList(zig.ExprBuild).init(arena);
            for (members) |member| {
                const name_api = exp.valueOf(
                    JsonName.get(symbols, member) orelse try symbols.getShapeName(member, .pascal, .{}),
                );
                const name_field = exp.valueOf(try symbols.getShapeName(member, .snake, .{}));
                const member_scheme = try shapeScheme(arena, symbols, exp, member, options);
                try schemes.append(exp.structLiteral(null, &.{ name_api, name_field, member_scheme }));
            }

            return exp.structLiteral(null, &.{
                exp_type.valueOf(.tagged_union),
                exp.structLiteral(null, try schemes.toOwnedSlice()),
            });
        },
        .structure => |members| {
            var scheme = std.ArrayList(zig.ExprBuild).init(arena);
            const is_input = symbols.hasTrait(id, trt_refine.input_id);
            for (members) |mid| {
                try scheme.append(try structMemberScheme(arena, symbols, exp, is_input, mid, options));
            }

            return exp.structLiteral(null, &.{
                exp_type.valueOf(.structure),
                exp.structLiteral(null, try scheme.toOwnedSlice()),
            });
        },
        .document => {
            // AWS usage: controltower, identitystore, inspector-scan, bedrock-agent-runtime, marketplace-catalog
            @panic("Document shape scheme construction not implemented");
        },
        .unit, .operation, .resource, .service, .target => unreachable,
    }
}

fn structMemberScheme(
    arena: Allocator,
    symbols: *SymbolsProvider,
    exp: zig.ExprBuild,
    is_input: bool,
    id: SmithyId,
    options: SchemeOptions,
) anyerror!zig.ExprBuild {
    const name_api = exp.valueOf(
        JsonName.get(symbols, id) orelse try symbols.getShapeName(id, .pascal, .{}),
    );
    const name_field = exp.valueOf(try symbols.getShapeName(id, .snake, .{}));
    const member_scheme = try shapeScheme(arena, symbols, exp, id, options);
    const is_required = exp.valueOf(!shape.isStructMemberOptional(symbols, id, is_input));
    return exp.structLiteral(null, &.{ name_api, name_field, is_required, member_scheme });
}
