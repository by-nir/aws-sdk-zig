const std = @import("std");
const Allocator = std.mem.Allocator;
const zig = @import("codmod").zig;
const Delegate = @import("jobz").Delegate;
const smithy = @import("smithy/codegen");
const AuthId = smithy.traits.auth.AuthId;
const SymbolsProvider = smithy.SymbolsProvider;
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

/// https://smithy.io/2.0/aws/rules-engine/auth-schemes.html
///
/// If an authSchemes property is present on an Endpoint object, clients MUST resolve
/// an authentication scheme to use via the following process:
///
/// 1. Iterate through configuration objects in the authSchemes property.
/// 2. If the name property in a configuration object contains a supported authentication scheme, resolve this scheme.
/// 3. If the name is unknown or unsupported, ignore it and continue iterating.
/// 4. If the list has been fully iterated and no scheme has been resolved, clients MUST return an error.
pub fn writeOperationAuth(_: Allocator, symbols: *SymbolsProvider, bld: *zig.BlockBuild) !void {
    // TODO
    try bld.@"if"(bld.x.id(aws_cfg.send_meta_param).dot().id("auth_optional"))
        .body(bld.call("@panic", &.{bld.x.valueOf("optional auth not implemented")}))
        .end();

    const meta_schemes = bld.x.id(aws_cfg.send_meta_param).dot().id("auth_schemes");
    const endpoint_schemes = bld.x.id(aws_cfg.send_endpoint_param).dot().id("auth_schemes");
    try bld.constant("auth_schemes").typing(
        bld.x.typeSlice(false, bld.x.id(aws_cfg.scope_smithy).dot().id("AuthScheme")),
    ).assign(
        bld.x.@"if"(meta_schemes.dot().id("len").op(.eql).valueOf(0)).body(bld.x.raw("&.{}"))
            .elseIf(endpoint_schemes.dot().id("len").op(.gt).valueOf(0)).body(endpoint_schemes)
            .@"else"().body(
            bld.x.addressOf().structLiteral(null, &.{
                bld.x.structLiteral(null, &.{bld.x.structAssign("id", meta_schemes.valIndexer(bld.x.valueOf(0)))}),
            }),
        ).end(),
    );

    try bld.@"for"().iter(bld.x.id("auth_schemes"), "scheme").body(
        bld.x.switchWith(bld.x.raw("scheme.id"), symbols, writeAuthSwitch),
    ).end();
}

fn writeAuthSwitch(symbols: *SymbolsProvider, bld: *zig.SwitchBuild) !void {
    for (symbols.service_auth_schemes) |aid| {
        const context = .{ .symbols = symbols, .auth_id = aid };
        const str = bld.x.valueOf(try symbols.arena.dupe(u8, aid.toString()));
        const case = bld.x.id(aws_cfg.scope_smithy).dot().id("AuthId").dot().call("of", &.{str});
        try bld.inlined().branch().case(case).capture("id").body(
            bld.x.@"if"(bld.x.compTime().call("std.mem.indexOfScalar", &.{
                bld.x.id(aws_cfg.scope_smithy).dot().id("AuthId"),
                bld.x.id(aws_cfg.send_meta_param).dot().id("auth_schemes"),
                bld.x.id("id"),
            })).capture("_").body(
                bld.x.blockWith(context, struct {
                    fn f(ctx: @TypeOf(context), b: *zig.BlockBuild) !void {
                        switch (ctx.auth_id) {
                            .http_bearer => try writeBearer(b),
                            trt_auth.SigV4.auth_id => try writeSigV4(ctx.symbols, b),
                            else => {
                                // .http_basic, .http_digest, .http_api_key
                                return error.UnimplementedAuthScheme;
                            },
                        }

                        try b.breaks(null).end();
                    }
                }.f),
            ).end(),
        );
    }

    try bld.@"else"().body(
        bld.x.call("@panic", &.{bld.x.valueOf("unimplemented auth scheme")}),
    );
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

fn writeSigV4(symbols: *SymbolsProvider, bld: *zig.BlockBuild) !void {
    const sign_name = if (trt_auth.SigV4.get(symbols, symbols.service_id)) |trait|
        bld.x.valueOf(trait.name)
    else
        bld.x.id("service_code");

    try bld.constant("auth_buffer").assign(bld.x.trys().call(
        aws_cfg.scratch_alloc ++ ".create",
        &.{bld.x.id(aws_cfg.scope_private).dot().id("SignBuffer")},
    ));

    try bld.constant("scheme_config").assign(
        bld.x.raw(aws_cfg.scope_auth).dot().call("SigV4Scheme.evaluate", &.{
            sign_name,
            bld.x.raw("self.config_sdk.region.toString()"),
            bld.x.id("scheme"),
        }),
    );

    try bld.constant("identity").assign(try resolveExpr(bld.x, "credentials"));

    try bld.trys().raw(aws_cfg.scope_auth).dot().call("signV4", &.{
        bld.x.id("auth_buffer"),
        bld.x.id(aws_cfg.send_op_param),
        bld.x.id("scheme_config"),
        bld.x.id("identity"),
        bld.x.id(aws_cfg.send_meta_param).dot().id("auth_skip_payload"),
    }).end();
}

fn resolveExpr(exp: zig.ExprBuild, kind: []const u8) !zig.ExprBuild {
    const kind_expr = exp.dot().id(kind);
    const resolve = exp.trys().call("self.identity.resolve", &.{kind_expr});
    return exp.group(resolve).dot().call("as", &.{kind_expr});
}
