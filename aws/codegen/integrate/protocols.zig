const std = @import("std");
const Allocator = std.mem.Allocator;
const zig = @import("codmod").zig;
const smithy = @import("smithy/codegen");
const SymbolsProvider = smithy.SymbolsProvider;
const aws_cfg = @import("../config.zig");
const trt_proto = @import("../traits/protocols.zig");
const TimestampFormat = smithy.traits.protocol.TimestampFormat.Value;

pub const Protocol = enum {
    json_1_0,
    json_1_1,
    rest_json_1,
    rest_xml,
    query,
    ec2_query,
};

const WriteCtx = struct {
    symbols: *SymbolsProvider,
    protocol: Protocol,
};

pub fn resolveServiceProtocol(symbols: *SymbolsProvider) !Protocol {
    const traits = symbols.getTraits(symbols.service_id) orelse return error.MissingServiceTraits;
    for (traits.values) |trait| {
        switch (trait.id) {
            trt_proto.AwsJson10.id => return .json_1_0,
            trt_proto.AwsJson11.id => return .json_1_1,
            trt_proto.RestJson1.id => return .rest_json_1,
            trt_proto.RestXml.id => return .rest_xml,
            trt_proto.aws_query_id => return .query,
            else => {},
        }
    }
    return error.UnsupportedServiceProtocol;
}

/// [ALPN Protocol ID](https://www.iana.org/assignments/tls-extensiontype-values/tls-extensiontype-values.xhtml#alpn-protocol-ids)
pub const Transport = enum {
    http_1_1,
    // http_2,
};

pub const ServiceTransports = struct {
    http_request: Transport,
    http_stream: Transport,
};

const default_transport: Transport = .http_1_1;

const supported_transports = std.StaticStringMap(Transport).initComptime(.{
    .{ "http/1.1", .http_1_1 },
    // .{"h2", .http_2},
});

/// Assumes the service supports the protocol
pub fn resolveServiceTransport(symbols: *SymbolsProvider, protocol: Protocol) !ServiceTransports {
    const StringsSlice = []const []const u8;
    const request_priority: StringsSlice, const stream_priority: StringsSlice = blk: {
        switch (protocol) {
            .json_1_0 => {
                const value = trt_proto.AwsJson10.get(symbols, symbols.service_id).?;
                break :blk .{ value.http orelse &.{}, value.event_stream_http orelse &.{} };
            },
            .json_1_1 => {
                const value = trt_proto.AwsJson11.get(symbols, symbols.service_id).?;
                break :blk .{ value.http orelse &.{}, value.event_stream_http orelse &.{} };
            },
            .rest_json_1 => {
                const value = trt_proto.RestJson1.get(symbols, symbols.service_id).?;
                break :blk .{ value.http orelse &.{}, value.event_stream_http orelse &.{} };
            },
            .rest_xml => {
                const value = trt_proto.RestXml.get(symbols, symbols.service_id).?;
                break :blk .{ value.http orelse &.{}, value.event_stream_http orelse &.{} };
            },
            .query => return .{
                .http_request = .http_1_1,
                .http_stream = .http_1_1, // Doesn’t actually support streaming
            },
            else => return error.UnimplementedServiceProtocol,
        }
    };

    const request = try resolveTransportPriority(request_priority, default_transport);
    const stream = try resolveTransportPriority(stream_priority, request);
    return .{
        .http_request = request,
        .http_stream = stream,
    };
}

fn resolveTransportPriority(transports: []const []const u8, default: Transport) !Transport {
    if (transports.len == 0) return default;

    for (transports) |transport| {
        if (supported_transports.get(transport)) |t| return t;
    }

    return error.UnsupportedTransports;
}

pub fn resolveHttpMethod(exp: zig.ExprBuild, protocol: Protocol) !zig.ExprBuild {
    return switch (protocol) {
        .json_1_0, .json_1_1, .query => exp.valueOf(.POST),
        .rest_json_1, .rest_xml => exp.fromExpr(try exp.id(aws_cfg.send_meta_param).dot().id("http_method").consume()),
        else => unreachable,
    };
}

pub fn resolveXmlTraitsUsage(protocol: Protocol) bool {
    return switch (protocol) {
        .rest_xml, .query => true,
        else => false,
    };
}

pub fn resolveTimestampFormat(protocol: Protocol) TimestampFormat {
    return switch (protocol) {
        .json_1_0, .json_1_1, .rest_json_1 => .epoch_seconds,
        .rest_xml, .query => .date_time,
        else => unreachable,
    };
}

pub fn writeOperationRequest(_: Allocator, symbols: *SymbolsProvider, bld: *zig.BlockBuild, protocol: Protocol) !void {
    switch (protocol) {
        .rest_json_1, .rest_xml => {
            try writeMetaConstant(bld);
            try writePayloadConstant(bld);
            try writeRequestHttp(bld);
        },
        .json_1_0, .json_1_1 => {
            try writeRequestHttpTarget(bld, symbols);
        },
        .query => {},
        else => return error.UnimplementedProtocol,
    }

    try bld.@"if"(bld.x.id("http_method").dot().call("requestHasBody", &.{})).body(
        bld.x.blockWith(WriteCtx{
            .symbols = symbols,
            .protocol = protocol,
        }, writeRequestBody),
    ).end();
}

const META_SCHEMA_CONST = "meta_schema";
fn writeMetaConstant(bld: *zig.BlockBuild) !void {
    try bld.constant(META_SCHEMA_CONST).assign(
        bld.x.id(aws_cfg.send_meta_param).dot().id("schema_input").dot().id("meta"),
    );
}

fn writePayloadConstant(bld: *zig.BlockBuild) !void {
    const member_idx = bld.x.id(META_SCHEMA_CONST).dot().id("payload").valIndexer(bld.x.valueOf(1));
    try bld.constant("payload_schema").assign(bld.x.@"if"(
        bld.x.raw("@hasField(@TypeOf(meta_schema), \"payload\")"),
    ).body(
        bld.x.id(aws_cfg.send_meta_param).dot().id("schema_input").dot().id("members").valIndexer(member_idx),
    ).@"else"().body(
        bld.x.valueOf(null),
    ).end());
}

fn writeRequestHttpTarget(bld: *zig.BlockBuild, symbols: *SymbolsProvider) !void {
    const target = bld.x
        .valueOf(try symbols.getShapeName(symbols.service_id, .pascal, .{ .suffix = "." }))
        .op(.@"++").id(aws_cfg.send_meta_param).dot().id("name");

    try bld.trys().id(aws_cfg.send_op_param).dot().id("request").dot().call("putHeader", &.{
        bld.x.id(aws_cfg.scratch_alloc),
        bld.x.valueOf("x-amz-target"),
        target,
    }).end();
}

fn writeRequestHttp(bld: *zig.BlockBuild) !void {
    const schema_exp = bld.x.id(aws_cfg.send_meta_param).dot().id("schema_input");

    try bld.constant("uri_path").assign(bld.x.@"if"(
        bld.x.raw("@hasField(@TypeOf(meta_schema), \"labels\")"),
    ).body(bld.x.trys().id(aws_cfg.scope_protocol).dot().call("http.uriMetaLabels", &.{
        bld.x.id(aws_cfg.send_op_param).dot().id("allocator"),
        schema_exp.dot().id("meta").dot().id("labels"),
        schema_exp.dot().id("members"),
        bld.x.id(aws_cfg.send_meta_param).dot().id("http_uri"),
        bld.x.id(aws_cfg.send_input_param),
    })).@"else"().body(
        bld.x.id(aws_cfg.send_meta_param).dot().id("http_uri"),
    ).end());

    try bld.id(aws_cfg.send_op_param).raw(".request.endpoint.path").assign().structLiteral(null, &.{
        bld.x.structAssign("raw", bld.x.id("uri_path")),
    }).end();

    try bld.@"if"(
        bld.x.raw("@hasField(@TypeOf(meta_schema), \"params\")"),
    ).body(bld.x.trys().id(aws_cfg.scope_protocol).dot().call("http.writeMetaParams", &.{
        bld.x.id(aws_cfg.send_op_param).dot().id("allocator"),
        schema_exp.dot().id("meta").dot().id("params"),
        schema_exp.dot().id("members"),
        bld.x.id(aws_cfg.send_input_param),
        bld.x.addressOf().id(aws_cfg.send_op_param).dot().id("request"),
    })).end();
}

fn writeRequestBody(ctx: WriteCtx, bld: *zig.BlockBuild) !void {
    switch (ctx.protocol) {
        .json_1_0, .json_1_1 => try writeAwsJsonBody(bld, ctx.protocol),
        .rest_json_1 => try writeRestJsonBody(bld),
        .rest_xml => try writeRestXmlBody(bld),
        .query => try writeAwsQueryBody(bld, ctx.symbols),
        else => return error.UnimplementedProtocol,
    }
}

fn writeAwsJsonBody(bld: *zig.BlockBuild, protocol: Protocol) !void {
    const schema_exp = bld.x.id(aws_cfg.send_meta_param).dot().id("schema_input");
    try bld.trys().id(aws_cfg.scope_protocol).dot().call("json.requestWithShape", &.{
        bld.x.id(aws_cfg.send_op_param).dot().id("allocator"),
        schema_exp.dot().id("members"),
        schema_exp.dot().id("body_ids"),
        bld.x.valueOf(switch (protocol) {
            .json_1_0 => "application/x-amz-json-1.0",
            .json_1_1 => "application/x-amz-json-1.1",
            else => unreachable,
        }),
        bld.x.addressOf().id(aws_cfg.send_op_param).dot().id("request"),
        bld.x.id(aws_cfg.send_input_param),
    }).end();
}

fn writeRestJsonBody(bld: *zig.BlockBuild) !void {
    const schema_exp = bld.x.id(aws_cfg.send_meta_param).dot().id("schema_input");

    try bld.@"if"(bld.x.id("payload_schema")).capture("pld").body(bld.x.block(struct {
        fn f(b: *zig.BlockBuild) !void {
            try b.trys().id(aws_cfg.scope_protocol).dot().call("json.requestWithPayload", &.{
                b.x.id(aws_cfg.send_op_param).dot().id("allocator"),
                b.x.id(META_SCHEMA_CONST).dot().id("payload"),
                b.x.id("pld"),
                b.x.addressOf().id(aws_cfg.send_op_param).dot().id("request"),
                b.x.call("@field", &.{
                    b.x.id(aws_cfg.send_input_param),
                    b.x.id("pld").dot().id("name_zig"),
                }),
            }).end();
        }
    }.f)).@"else"().body(
        bld.x.trys().id(aws_cfg.scope_protocol).dot().call("json.requestWithShape", &.{
            bld.x.id(aws_cfg.send_op_param).dot().id("allocator"),
            schema_exp.dot().id("members"),
            schema_exp.dot().id("body_ids"),
            bld.x.valueOf("application/json"),
            bld.x.addressOf().id(aws_cfg.send_op_param).dot().id("request"),
            bld.x.id(aws_cfg.send_input_param),
        }),
    ).end();
}

fn writeRestXmlBody(bld: *zig.BlockBuild) !void {
    const schema_exp = bld.x.id(aws_cfg.send_meta_param).dot().id("schema_input");

    try bld.@"if"(bld.x.id("payload_schema")).capture("pld").body(bld.x.block(struct {
        fn f(b: *zig.BlockBuild) !void {
            try b.trys().id(aws_cfg.scope_protocol).dot().call("xml.requestWithPayload", &.{
                b.x.id(aws_cfg.send_op_param).dot().id("allocator"),
                b.x.id(META_SCHEMA_CONST).dot().id("payload"),
                b.x.id("pld"),
                b.x.addressOf().id(aws_cfg.send_op_param).dot().id("request"),
                b.x.call("@field", &.{
                    b.x.id(aws_cfg.send_input_param),
                    b.x.id("pld").dot().id("name_zig"),
                }),
            }).end();
        }
    }.f)).@"else"().body(
        bld.x.trys().id(aws_cfg.scope_protocol).dot().call("xml.requestWithShape", &.{
            bld.x.id(aws_cfg.send_op_param).dot().id("allocator"),
            schema_exp,
            bld.x.addressOf().id(aws_cfg.send_op_param).dot().id("request"),
            bld.x.id(aws_cfg.send_input_param),
        }),
    ).end();
}

fn writeAwsQueryBody(bld: *zig.BlockBuild, symbols: *SymbolsProvider) !void {
    const version = (try symbols.getShape(symbols.service_id)).service.version orelse {
        return error.MissingServiceVersion;
    };

    try bld.trys().id(aws_cfg.scope_protocol).dot().call("query.requestInput", &.{
        bld.x.id(aws_cfg.send_op_param).dot().id("allocator"),
        bld.x.id(aws_cfg.send_meta_param).dot().id("schema_input"),
        bld.x.addressOf().id(aws_cfg.send_op_param).dot().id("request"),
        bld.x.id(aws_cfg.send_meta_param).dot().id("name"),
        bld.x.valueOf(version),
        bld.x.id(aws_cfg.send_input_param),
    }).end();
}

pub fn writeOperationResponse(symbols: *SymbolsProvider, bld: *zig.BlockBuild, protocol: Protocol) !void {
    try bld.constant("response").assign(
        bld.x.id(aws_cfg.send_op_param).dot().id("response").orElse().returns().valueOf(error.MissingResponse),
    );

    try bld.switchWith(bld.x.raw("response.status.class()"), WriteCtx{
        .symbols = symbols,
        .protocol = protocol,
    }, struct {
        fn f(ctx: WriteCtx, b: *zig.SwitchBuild) !void {
            try b.branch().case(b.x.valueOf(.success)).body(
                b.x.blockWith(ctx, writeResponseSuccess),
            );
            try b.branch().case(b.x.valueOf(.client_error)).case(b.x.valueOf(.server_error)).body(
                b.x.blockWith(ctx, writeResponseFail),
            );
            try b.@"else"().body(b.x.returns().valueOf(error.UnexpectedResponseStatus));
        }
    }.f);
}

fn writeResponseSuccess(ctx: WriteCtx, bld: *zig.BlockBuild) !void {
    try bld.variable("output").assign(bld.x.id(aws_cfg.scope_smithy).dot().call("serial.zeroInit", &.{
        bld.x.id(aws_cfg.send_meta_param).dot().id("Output"),
        bld.x.structLiteral(null, &.{}),
    }));

    switch (ctx.protocol) {
        .rest_json_1, .rest_xml => {
            try bld.trys().id(aws_cfg.scope_protocol).dot().call("http.parseMeta", &.{
                bld.x.id(aws_cfg.output_arena).dot().call("allocator", &.{}),
                bld.x.id(aws_cfg.send_meta_param).dot().id("schema_output").dot().id("meta"),
                bld.x.id(aws_cfg.send_meta_param).dot().id("schema_output").dot().id("members"),
                bld.x.id("response"),
                bld.x.addressOf().id("output"),
            }).end();
        },
        else => {},
    }

    const func_name = switch (ctx.protocol) {
        .json_1_0, .json_1_1, .rest_json_1 => "json.responseOutput",
        .rest_xml => "xml.responseOutput",
        .query => "query.responseOutput",
        else => return error.UnimplementedProtocol,
    };
    try bld.trys().id(aws_cfg.scope_protocol).dot().call(func_name, &.{
        bld.x.id(aws_cfg.scratch_alloc),
        bld.x.id(aws_cfg.output_arena).dot().call("allocator", &.{}),
        bld.x.id(aws_cfg.send_meta_param).dot().id("schema_output"),
        bld.x.id("response").dot().id("body"),
        bld.x.addressOf().id("output"),
    }).end();

    try bld.@"if"(
        bld.x.id(aws_cfg.output_arena).dot().call("queryCapacity", &.{}).op(.gt).valueOf(0),
    ).body(
        bld.x.id("output").dot().id("arena").assign().id(aws_cfg.output_arena),
    ).end();

    try bld.returns().structLiteral(null, &.{
        bld.x.structAssign("ok", bld.x.id("output")),
    }).end();
}

fn writeResponseFail(ctx: WriteCtx, bld: *zig.BlockBuild) !void {
    const err_exp = switch (ctx.protocol) {
        .json_1_0, .json_1_1, .rest_json_1 => |protocol| blk: {
            const func_name = switch (protocol) {
                .query => "query.responseError",
                else => "json.responseError",
            };

            break :blk bld.x.trys().id(aws_cfg.scope_protocol).dot().call(func_name, &.{
                bld.x.id(aws_cfg.scratch_alloc),
                bld.x.addressOf().id(aws_cfg.output_arena),
                bld.x.id(aws_cfg.send_meta_param).dot().id("schema_errors"),
                bld.x.id(aws_cfg.send_meta_param).dot().id("Errors"),
                bld.x.id("response"),
            });
        },
        .rest_xml, .query => |p| blk: {
            const has_wrap = p == .rest_xml and !trt_proto.RestXml.get(ctx.symbols, ctx.symbols.service_id).?.no_error_wrapping;
            break :blk bld.x.trys().id(aws_cfg.scope_protocol).dot().call("xml.responseError", &.{
                bld.x.id(aws_cfg.scratch_alloc),
                bld.x.addressOf().id(aws_cfg.output_arena),
                bld.x.id(aws_cfg.send_meta_param).dot().id("schema_errors"),
                bld.x.id(aws_cfg.send_meta_param).dot().id("Errors"),
                bld.x.id("response"),
                bld.x.valueOf(has_wrap),
            });
        },
        else => return error.UnimplementedProtocol,
    };

    try bld.returns().structLiteral(null, &.{
        bld.x.structAssign("fail", err_exp),
    }).end();
}
