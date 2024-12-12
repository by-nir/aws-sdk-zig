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

pub fn resolveServiceProtocol(symbols: *SymbolsProvider) !Protocol {
    const traits = symbols.getTraits(symbols.service_id) orelse return error.MissingServiceTraits;
    for (traits.values) |trait| {
        switch (trait.id) {
            trt_proto.AwsJson10.id => return .json_1_0,
            trt_proto.AwsJson11.id => return .json_1_1,
            trt_proto.RestJson1.id => return .rest_json_1,
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

pub fn resolveDefaultHttpMethod(protocol: Protocol) std.http.Method {
    return switch (protocol) {
        .json_1_0, .json_1_1 => .POST,
        .rest_json_1 => undefined,
        else => unreachable,
    };
}

pub fn resolveTimestampFormat(protocol: Protocol) TimestampFormat {
    return switch (protocol) {
        .json_1_0, .json_1_1, .rest_json_1 => .epoch_seconds,
        else => unreachable,
    };
}

pub fn writeOperationRequest(_: Allocator, symbols: *SymbolsProvider, bld: *zig.BlockBuild, protocol: Protocol) !void {
    switch (protocol) {
        .json_1_0, .json_1_1 => try writeAwsJsonRequest(protocol, symbols, bld),
        .rest_json_1 => {
            try writeHttpRequest(bld);
            try writeRestJsonRequest(bld);
        },
        else => return error.UnimplementedProtocol,
    }
}

fn writeHttpRequest(bld: *zig.BlockBuild) !void {
    const scheme_exp = bld.x.id(aws_cfg.send_meta_param).dot().id("scheme_input");
    try bld.constant("meta_scheme").assign(scheme_exp.dot().id("meta"));
    try bld.constant("members_scheme").assign(scheme_exp.dot().id("members"));

    try bld.constant("uri_path").assign(bld.x.@"if"(
        bld.x.raw("@hasField(@TypeOf(meta_scheme), \"labels\")"),
    ).body(bld.x.trys().id(aws_cfg.scope_protocol).dot().call("http.uriMetaLabels", &.{
        bld.x.id(aws_cfg.send_op_param).dot().id("allocator"),
        bld.x.id("meta_scheme").dot().id("labels"),
        bld.x.id("members_scheme"),
        bld.x.id(aws_cfg.send_meta_param).dot().id("http_uri"),
        bld.x.id(aws_cfg.send_input_param),
    })).@"else"().body(
        bld.x.id(aws_cfg.send_meta_param).dot().id("http_uri"),
    ).end());

    try bld.id(aws_cfg.send_op_param).raw(".request.endpoint.path").assign().structLiteral(null, &.{
        bld.x.structAssign("raw", bld.x.id("uri_path")),
    }).end();

    try bld.@"if"(
        bld.x.raw("@hasField(@TypeOf(meta_scheme), \"params\")"),
    ).body(bld.x.trys().id(aws_cfg.scope_protocol).dot().call("http.writeMetaParams", &.{
        bld.x.id(aws_cfg.send_op_param).dot().id("allocator"),
        bld.x.id("meta_scheme").dot().id("params"),
        bld.x.id("members_scheme"),
        bld.x.id(aws_cfg.send_input_param),
        bld.x.addressOf().id(aws_cfg.send_op_param).dot().id("request"),
    })).end();
}

fn writeAwsJsonRequest(protocol: Protocol, symbols: *SymbolsProvider, bld: *zig.BlockBuild) !void {
    const target = bld.x.valueOf(
        try symbols.getShapeName(symbols.service_id, .pascal, .{ .suffix = "." }),
    ).op(.@"++").id(aws_cfg.send_meta_param).dot().id("name");

    try bld.trys().id(aws_cfg.send_op_param).dot().id("request").dot().call("putHeader", &.{
        bld.x.id(aws_cfg.scratch_alloc),
        bld.x.valueOf("x-amz-target"),
        target,
    }).end();

    const scheme_exp = bld.x.id(aws_cfg.send_meta_param).dot().id("scheme_input");
    try bld.trys().id(aws_cfg.scope_protocol).dot().call("json.requestShape", &.{
        bld.x.id(aws_cfg.send_op_param).dot().id("allocator"),
        scheme_exp.dot().id("members"),
        scheme_exp.dot().id("body_ids"),
        bld.x.valueOf(switch (protocol) {
            .json_1_0 => "application/x-amz-json-1.0",
            .json_1_1 => "application/x-amz-json-1.1",
            else => unreachable,
        }),
        bld.x.addressOf().id(aws_cfg.send_op_param).dot().id("request"),
        bld.x.id(aws_cfg.send_input_param),
    }).end();
}

fn writeRestJsonRequest(bld: *zig.BlockBuild) !void {
    try bld.@"if"(
        bld.x.raw("@hasField(@TypeOf(meta_scheme), \"payload\")"),
    ).body(bld.x.block(struct {
        fn f(b: *zig.BlockBuild) !void {
            try b.constant("member_scheme").assign(b.x.id("members_scheme").valIndexer(
                b.x.id("meta_scheme").dot().id("payload").valIndexer(b.x.valueOf(1)),
            ));

            try b.trys().id(aws_cfg.scope_protocol).dot().call("json.requestPayload", &.{
                b.x.id(aws_cfg.send_op_param).dot().id("allocator"),
                b.x.id("meta_scheme").dot().id("payload"),
                b.x.id("member_scheme"),
                b.x.addressOf().id(aws_cfg.send_op_param).dot().id("request"),
                b.x.call("@field", &.{
                    b.x.id(aws_cfg.send_input_param),
                    b.x.id("member_scheme").valIndexer(b.x.valueOf(1)),
                }),
            }).end();
        }
    }.f)).@"else"().body(
        bld.x.trys().id(aws_cfg.scope_protocol).dot().call("json.requestShape", &.{
            bld.x.id(aws_cfg.send_op_param).dot().id("allocator"),
            bld.x.id("members_scheme"),
            bld.x.id(aws_cfg.send_meta_param).dot().id("scheme_input").dot().id("body_ids"),
            bld.x.valueOf("application/json"),
            bld.x.addressOf().id(aws_cfg.send_op_param).dot().id("request"),
            bld.x.id(aws_cfg.send_input_param),
        }),
    ).end();
}

pub fn writeOperationResponse(bld: *zig.BlockBuild, protocol: Protocol) !void {
    try bld.constant("response").assign(
        bld.x.id(aws_cfg.send_op_param).dot().id("response").orElse().returns().valueOf(error.MissingResponse),
    );

    try bld.switchWith(bld.x.raw("response.status.class()"), protocol, struct {
        fn f(p: Protocol, b: *zig.SwitchBuild) !void {
            try b.branch().case(b.x.valueOf(.success)).body(
                b.x.blockWith(p, writeResponseSuccess),
            );
            try b.branch().case(b.x.valueOf(.client_error)).case(b.x.valueOf(.server_error)).body(
                b.x.blockWith(p, writeResponseFail),
            );
            try b.@"else"().body(b.x.returns().valueOf(error.UnexpectedResponseStatus));
        }
    }.f);
}

fn writeResponseSuccess(protocol: Protocol, bld: *zig.BlockBuild) !void {
    try bld.variable("output").assign(bld.x.call("std.mem.zeroInit", &.{
        bld.x.id(aws_cfg.send_meta_param).dot().id("Output"),
        bld.x.structLiteral(null, &.{}),
    }));

    switch (protocol) {
        .rest_json_1 => {
            try bld.trys().id(aws_cfg.scope_protocol).dot().call("http.parseMeta", &.{
                bld.x.id(aws_cfg.output_arena).dot().call("allocator", &.{}),
                bld.x.id(aws_cfg.send_meta_param).dot().id("scheme_output").dot().id("meta"),
                bld.x.id(aws_cfg.send_meta_param).dot().id("scheme_output").dot().id("members"),
                bld.x.id("response"),
                bld.x.addressOf().id("output"),
            }).end();
        },
        else => {},
    }

    switch (protocol) {
        .json_1_0, .json_1_1, .rest_json_1 => {
            try bld.trys().id(aws_cfg.scope_protocol).dot().call("json.responseOutput", &.{
                bld.x.id(aws_cfg.scratch_alloc),
                bld.x.id(aws_cfg.output_arena).dot().call("allocator", &.{}),
                bld.x.id(aws_cfg.send_meta_param).dot().id("scheme_output"),
                bld.x.id("response").dot().id("body"),
                bld.x.addressOf().id("output"),
            }).end();
        },
        else => return error.UnimplementedProtocol,
    }

    try bld.@"if"(
        bld.x.id(aws_cfg.output_arena).dot().call("queryCapacity", &.{}).op(.gt).valueOf(0),
    ).body(
        bld.x.id("output").dot().id("arena").assign().id(aws_cfg.output_arena),
    ).end();

    try bld.returns().structLiteral(null, &.{
        bld.x.structAssign("ok", bld.x.id("output")),
    }).end();
}

fn writeResponseFail(protocol: Protocol, bld: *zig.BlockBuild) !void {
    const err_exp = switch (protocol) {
        .json_1_0, .json_1_1, .rest_json_1 => bld.x.trys().id(aws_cfg.scope_protocol).dot().call("json.responseError", &.{
            bld.x.id(aws_cfg.scratch_alloc),
            bld.x.addressOf().id(aws_cfg.output_arena),
            bld.x.id(aws_cfg.send_meta_param).dot().id("scheme_errors"),
            bld.x.id(aws_cfg.send_meta_param).dot().id("Errors"),
            bld.x.id("response"),
        }),
        else => return error.UnimplementedProtocol,
    };

    try bld.returns().structLiteral(null, &.{
        bld.x.structAssign("fail", err_exp),
    }).end();
}
