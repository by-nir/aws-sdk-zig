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
    json_10,
    json_11,
    rest_json1,
    rest_xml,
    query,
    ec2_query,
};

pub fn defaultHttpMethod(protocol: Protocol) std.http.Method {
    return switch (protocol) {
        .json_10 => .POST,
        else => unreachable,
    };
}

pub fn writeOperationRequest(arena: Allocator, symbols: *SymbolsProvider, bld: *zig.BlockBuild, shape: smithy.OperationShape, protocol: Protocol) !void {
    switch (protocol) {
        .json_10 => try writeJson10Request(arena, symbols, bld, shape),
        else => return error.UnimplementedProtocol,
    }
}

pub fn writeOperationResponse(arena: Allocator, symbols: *SymbolsProvider, bld: *zig.BlockBuild, shape: smithy.OperationShape, protocol: Protocol) !void {
    switch (protocol) {
        .json_10 => try writeJson10Response(arena, symbols, bld, shape),
        else => return error.UnimplementedProtocol,
    }
}

fn writeJson10Request(arena: Allocator, symbols: *SymbolsProvider, bld: *zig.BlockBuild, shape: smithy.OperationShape) !void {
    const target = try std.fmt.allocPrint(arena, "{s}.{s}", .{
        try symbols.getShapeNameRaw(symbols.service_id),
        try symbols.getShapeNameRaw(shape.id),
    });

    const payload = bld.trys().id(aws_cfg.scope_protocol).dot().call("aws_json.inputJson10", &.{
        bld.x.id(aws_cfg.send_op_param),
        bld.x.valueOf(target),
        bld.x.id(aws_cfg.send_input_param),
        bld.x.raw(".{}"),
    });

    try bld.constant("payload").assign(payload);
    try bld.defers(bld.x.id(aws_cfg.alloc_param).dot().raw("free(payload)"));
}

fn writeJson10Response(arena: Allocator, symbols: *SymbolsProvider, bld: *zig.BlockBuild, shape: smithy.OperationShape) !void {
    try bld.returns().id(aws_cfg.scope_protocol).dot().call("aws_json.outputJson10", &.{
        bld.x.id(aws_cfg.send_op_param),
        if (shape.output_type) |s| bld.x.raw(s) else bld.x.typeOf(void),
        if (shape.errors_type) |s| bld.x.raw(s) else bld.x.typeOf(void),
        bld.x.raw(".{}"),
        bld.x.raw(".{}"),
    }).end();
}
