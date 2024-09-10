const std = @import("std");
const Allocator = std.mem.Allocator;
const zig = @import("codegen").zig;
const smithy = @import("smithy/codegen");
const SymbolsProvider = smithy.SymbolsProvider;
const aws_cfg = @import("../config.zig");

pub const Scheme = enum {
    none,
    basic,
    bearer,
    digest,
    api_key,
    sigv4,
    sigv4a,
};

pub fn writeOperationAuth(_: Allocator, _: *SymbolsProvider, bld: *zig.BlockBuild, _: smithy.OperationShape, scheme: Scheme) !void {
    switch (scheme) {
        .sigv4 => try writeSigV4(bld),
        else => return error.UnimplementedProtocol,
    }
}

fn writeSigV4(bld: *zig.BlockBuild) !void {
    try bld.variable("auth_buffer")
        .typing(bld.x.id(aws_cfg.scope_private).dot().id("SignBuffer"))
        .assign(bld.x.raw("undefined"));

    try bld.trys().id(aws_cfg.scope_auth).dot().call("signV4", &.{
        bld.x.addressOf().id("auth_buffer"),
        bld.x.id(aws_cfg.send_op_param),
        bld.x.id("service_code"),
        bld.x.raw("self.config_sdk.region"),
        bld.x.raw("self.TEMP_creds"),
    }).end();
}
