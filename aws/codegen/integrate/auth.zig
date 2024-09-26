const std = @import("std");
const Allocator = std.mem.Allocator;
const zig = @import("razdaz").zig;
const Delegate = @import("jobz").Delegate;
const smithy = @import("smithy/codegen");
const SmithyId = smithy.SmithyId;
const SymbolsProvider = smithy.SymbolsProvider;
const trt_smithy = smithy.traits.auth;
const AuthId = trt_smithy.AuthId;
const aws_cfg = @import("../config.zig");
const trt_auth = @import("../traits/auth.zig");

pub fn extendAuthSchemes(_: *const Delegate, symbols: *SymbolsProvider, extension: *smithy.ServiceExtension) !void {
    if (symbols.hasTrait(symbols.service_id, trt_auth.SigV4.id)) {
        try extension.appendAuthScheme(trt_auth.SigV4.auth_id);
    }

    if (symbols.hasTrait(symbols.service_id, trt_auth.SigV4A.id)) {
        try extension.appendAuthScheme(trt_auth.SigV4A.auth_id);
    }
}

const SignContext = struct {
    op_id: SmithyId,
    symbols: *SymbolsProvider,
    schemes: []const AuthId,
    config_expr: ?zig.ExprBuild = null,
};

pub fn writeOperationAuth(
    _: Allocator,
    symbols: *SymbolsProvider,
    bld: *zig.BlockBuild,
    func: smithy.OperationFunc,
) !void {
    std.debug.assert(func.auth_schemes.len > 0);
    if (symbols.hasTrait(func.id, trt_smithy.optional_auth_id)) {
        return error.OptionalAuthUnimplemented; // TODO
    }

    pre_pass: for (func.auth_schemes) |id| switch (id) {
        trt_auth.SigV4.auth_id, trt_auth.SigV4A.auth_id => {
            try writeSignBuffer(bld);
            break :pre_pass;
        },
        else => {},
    };

    const context = SignContext{
        .op_id = func.id,
        .symbols = symbols,
        .schemes = func.auth_schemes,
    };
    try bld.@"if"(bld.x.raw(aws_cfg.send_endpoint_param ++ ".auth_schemes.len > 0"))
        .body(bld.x.blockWith(context, writeSchemeResolver))
        .@"else"().body(
        switch (func.auth_schemes[0]) {
            trt_auth.SigV4.auth_id => bld.x.blockWith(context, writeSigV4),
            else => return error.UnimplementedAuthScheme,
        },
    ).end();
}

fn writeSignBuffer(bld: *zig.BlockBuild) !void {
    try bld.variable("auth_buffer")
        .typing(bld.x.id(aws_cfg.scope_private).dot().id("SignBuffer"))
        .assign(bld.x.raw("undefined"));
}

/// https://smithy.io/2.0/aws/rules-engine/auth-schemes.html
///
/// If an authSchemes property is present on an Endpoint object, clients MUST resolve
/// an authentication scheme to use via the following process:
///
/// 1. Iterate through configuration objects in the authSchemes property.
/// 2. If the name property in a configuration object contains a supported authentication scheme, resolve this scheme.
/// 3. If the name is unknown or unsupported, ignore it and continue iterating.
/// 4. If the list has been fully iterated and no scheme has been resolved, clients MUST return an error.
fn writeSchemeResolver(ctx: SignContext, bld: *zig.BlockBuild) !void {
    try bld.@"for"()
        .iter(bld.x.raw(aws_cfg.send_endpoint_param ++ ".auth_schemes"), "scheme")
        .iter(bld.x.valFrom(bld.x.valueOf(0)), "i")
        .body(bld.x.switchWith(bld.x.raw("scheme.id"), ctx, struct {
        fn f(c: SignContext, b: *zig.SwitchBuild) !void {
            for (c.schemes) |id| {
                switch (id) {
                    .http_bearer => {
                        const case = b.x.raw(aws_cfg.scope_smithy).dot().call("AuthId.of", &.{b.x.valueOf("bearer")});
                        try b.branch().case(case).body(b.x.block(writeBearer));
                    },
                    trt_auth.SigV4.auth_id => {
                        var sign_ctx = c;
                        sign_ctx.config_expr = b.x.raw(aws_cfg.send_endpoint_param).dot().id("auth_schemes").valIndexer(b.x.id("i"));
                        const case = b.x.raw(aws_cfg.scope_smithy).dot().call("AuthId.of", &.{b.x.valueOf("sigv4")});
                        try b.branch().case(case).body(b.x.blockWith(sign_ctx, writeSigV4));
                    },
                    else => {
                        // .http_basic, .http_digest, .http_api_key
                        return error.UnimplementedAuthScheme;
                    },
                }
            }

            try b.@"else"().body(b.x.valueOf({}));
        }
    }.f)).end();

    try bld.returns().valueOf(error.UnresolvedAuthScheme).end();
}

fn writeBearer(bld: *zig.BlockBuild) !void {
    try bld.constant("identity").assign(try resolveExpr(bld.x, "token"));

    try bld.constant("auth_bearer").assign(bld.x.call("std.fmt.allocPrint", &.{
        bld.x.raw("aws_cfg.scratch_alloc"),
        bld.x.valueOf("Bearer {s}"),
        bld.x.structLiteral(null, &.{bld.x.raw("identity")}),
    }));

    try bld.trys().id(aws_cfg.send_op_param).dot().call("request.putHeader", &.{
        bld.x.valueOf("authorization"),
        bld.x.id("auth_bearer"),
    }).end();
}

fn writeSigV4(ctx: SignContext, bld: *zig.BlockBuild) !void {
    const sign_name = if (trt_auth.SigV4.get(ctx.symbols, ctx.symbols.service_id)) |trait|
        bld.x.valueOf(trait.name)
    else
        bld.x.id("service_code");

    try bld.constant("scheme_config").assign(
        bld.x.raw(aws_cfg.scope_auth).dot().call("SigV4Scheme.evaluate", &.{
            sign_name,
            bld.x.raw("self.config_sdk.region.toString()"),
            ctx.config_expr orelse bld.x.valueOf(null),
        }),
    );

    const unsigned_payload = ctx.symbols.hasTrait(ctx.op_id, trt_auth.unsigned_payload_id);
    try bld.constant("identity").assign(try resolveExpr(bld.x, "credentials"));

    try bld.trys().raw(aws_cfg.scope_auth).dot().call("signV4", &.{
        bld.x.addressOf().id("auth_buffer"),
        bld.x.id(aws_cfg.send_op_param),
        bld.x.id("scheme_config"),
        bld.x.id("identity"),
        bld.x.valueOf(unsigned_payload),
    }).end();
}

fn resolveExpr(exp: zig.ExprBuild, kind: []const u8) !zig.ExprBuild {
    const kind_expr = exp.dot().id(kind);
    const resolve = exp.trys().call("self.identity.resolve", &.{kind_expr});
    return exp.group(resolve).dot().call("as", &.{kind_expr});
}
