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

pub fn writeOperationRequest(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *zig.BlockBuild,
    func: smithy.OperationFunc,
    protocol: Protocol,
) !void {
    switch (protocol) {
        .json_1_0 => try writeAwsJsonRequest(arena, 10, symbols, bld, func),
        .json_1_1 => try writeAwsJsonRequest(arena, 11, symbols, bld, func),
        else => return error.UnimplementedProtocol,
    }
}

pub fn writeOperationResult(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *zig.BlockBuild,
    func: smithy.OperationFunc,
    protocol: Protocol,
) !zig.ExprBuild {
    return switch (protocol) {
        .json_1_0 => try writeAwsJsonResult(arena, 10, symbols, bld.x, func),
        .json_1_1 => try writeAwsJsonResult(arena, 11, symbols, bld.x, func),
        else => error.UnimplementedProtocol,
    };
}

fn writeAwsJsonRequest(
    arena: Allocator,
    comptime flavor: u8,
    symbols: *SymbolsProvider,
    bld: *zig.BlockBuild,
    func: smithy.OperationFunc,
) !void {
    const target = try std.fmt.allocPrint(arena, "{s}.{s}", .{
        try symbols.getShapeName(symbols.service_id, .pascal, .{}),
        try symbols.getShapeName(func.id, .pascal, .{}),
    });

    try bld.trys().id(aws_cfg.scope_protocol).dot().call("json.operationRequest", &.{
        bld.x.valueOf(switch (flavor) {
            10 => .aws_1_0,
            11 => .aws_1_1,
            else => unreachable,
        }),
        bld.x.valueOf(target),
        if (func.serial_input) |s| bld.x.raw(s) else bld.x.structLiteral(null, &.{}),
        bld.x.id(aws_cfg.send_op_param),
        bld.x.id(aws_cfg.send_input_param),
    }).end();
}

fn writeAwsJsonResult(
    _: Allocator,
    comptime flavor: u8,
    _: *SymbolsProvider,
    exp: zig.ExprBuild,
    func: smithy.OperationFunc,
) !zig.ExprBuild {
    return exp.id(aws_cfg.scope_protocol).dot().call("json.operationResponse", &.{
        exp.valueOf(switch (flavor) {
            10 => .aws_1_0,
            11 => .aws_1_1,
            else => unreachable,
        }),
        if (func.output_type) |s| exp.raw(s) else exp.typeOf(void),
        if (func.serial_output) |s| exp.raw(s) else exp.structLiteral(null, &.{}),
        if (func.errors_type) |s| exp.raw(s) else exp.typeOf(void),
        if (func.serial_error) |s| exp.raw(s) else exp.structLiteral(null, &.{}),
        exp.addressOf().id(aws_cfg.output_arena),
        exp.id(aws_cfg.send_op_param),
    });
}
