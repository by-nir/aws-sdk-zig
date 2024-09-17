const std = @import("std");
const Allocator = std.mem.Allocator;
const zig = @import("razdaz").zig;
const smithy = @import("smithy/codegen");
const SymbolsProvider = smithy.SymbolsProvider;
const aws_cfg = @import("../config.zig");

// TODO: Unit tests

// TODO: S3 (and maybe others):
// const payload_hash = request.payloadHash();
// try request.addHeader("x-amz-content-sha256", &payload_hash);

pub const Protocol = enum {
    json_1_0,
    json_1_1,
    rest_json_1,
    rest_xml,
    query,
    ec2_query,
};

pub fn defaultHttpMethod(protocol: Protocol) std.http.Method {
    return switch (protocol) {
        .json_1_0, .json_1_1 => .POST,
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
