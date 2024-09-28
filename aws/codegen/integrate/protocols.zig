const std = @import("std");
const Allocator = std.mem.Allocator;
const zig = @import("razdaz").zig;
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

pub fn resolveHttpMethod(protocol: Protocol) std.http.Method {
    return switch (protocol) {
        .json_1_0, .json_1_1 => .POST,
        else => unreachable,
    };
}

pub fn resolveTimestampFormat(protocol: Protocol) TimestampFormat {
    return switch (protocol) {
        .json_1_0, .json_1_1 => .epoch_seconds,
        else => unreachable,
    };
}

pub fn writeOperationRequest(_: Allocator, symbols: *SymbolsProvider, bld: *zig.BlockBuild, protocol: Protocol) !void {
    switch (protocol) {
        .json_1_0 => try writeAwsJsonRequest(10, symbols, bld),
        .json_1_1 => try writeAwsJsonRequest(11, symbols, bld),
        else => return error.UnimplementedProtocol,
    }
}

pub fn writeOperationResult(
    _: Allocator,
    _: *SymbolsProvider,
    bld: *zig.BlockBuild,
    protocol: Protocol,
) !zig.ExprBuild {
    return switch (protocol) {
        .json_1_0 => try writeAwsJsonResult(10, bld.x),
        .json_1_1 => try writeAwsJsonResult(11, bld.x),
        else => error.UnimplementedProtocol,
    };
}

fn writeAwsJsonRequest(comptime flavor: u8, symbols: *SymbolsProvider, bld: *zig.BlockBuild) !void {
    const target = bld.x.valueOf(
        try symbols.getShapeName(symbols.service_id, .pascal, .{ .suffix = "." }),
    ).op(.@"++").id(aws_cfg.send_meta_param).dot().id("name");

    try bld.trys().id(aws_cfg.scope_protocol).dot().call("json.operationRequest", &.{
        bld.x.valueOf(switch (flavor) {
            10 => .aws_1_0,
            11 => .aws_1_1,
            else => unreachable,
        }),
        target,
        bld.x.id(aws_cfg.send_serial_param).dot().id("input"),
        bld.x.id(aws_cfg.send_op_param),
        bld.x.id(aws_cfg.send_input_param),
    }).end();
}

fn writeAwsJsonResult(comptime flavor: u8, exp: zig.ExprBuild) !zig.ExprBuild {
    return exp.id(aws_cfg.scope_protocol).dot().call("json.operationResponse", &.{
        exp.valueOf(switch (flavor) {
            10 => .aws_1_0,
            11 => .aws_1_1,
            else => unreachable,
        }),
        exp.id(aws_cfg.send_meta_param).dot().id("Output"),
        exp.id(aws_cfg.send_serial_param).dot().id("output"),
        exp.id(aws_cfg.send_meta_param).dot().id("Errors"),
        exp.id(aws_cfg.send_serial_param).dot().id("errors"),
        exp.addressOf().id(aws_cfg.output_arena),
        exp.id(aws_cfg.send_op_param),
    });
}
