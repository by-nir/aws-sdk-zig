const zig = @import("razdaz").zig;
const Expr = zig.Expr;
const ExprBuild = zig.ExprBuild;
const smithy = @import("smithy/codegen");
const Function = smithy.RulesFunc;
const BuiltIn = smithy.RulesBuiltIn;
const FunctionsRegistry = smithy.RulesFuncsRegistry;
const BuiltInsRegistry = smithy.RulesBuiltInsRegistry;
const ArgValue = smithy.RulesArgValue;
const Generator = smithy.RulesGenerator;
const aws_cfg = @import("../config.zig");

const RulesId = smithy.RulesBuiltIn.Id;

/// Provides a mapping from an endpoint built-in to a config value.
pub fn mapConfigBuiltins(x: ExprBuild, id: RulesId) !Expr {
    const field: []const u8 = switch (id) {
        // Smithy
        RulesId.endpoint => "endpoint_url",
        // AWS
        RulesId.of("AWS::Region") => "region.toString()",
        RulesId.of("AWS::UseFIPS") => "use_fips",
        RulesId.of("AWS::UseDualStack") => "use_dual_stack",
        // TODO: Remaining built-ins
        //  BuiltInId.of("AWS::Auth::AccountId")
        //  BuiltInId.of("AWS::Auth::AccountIdEndpointMode")
        //  BuiltInId.of("AWS::Auth::CredentialScope")
        //  BuiltInId.of("AWS::S3::Accelerate")
        //  BuiltInId.of("AWS::S3::DisableMultiRegionAccessPoints")
        //  BuiltInId.of("AWS::S3::ForcePathStyle")
        //  BuiltInId.of("AWS::S3::UseArnRegion")
        //  BuiltInId.of("AWS::S3::UseGlobalEndpoint")
        //  BuiltInId.of("AWS::S3Control::UseArnRegion")
        //  BuiltInId.of("AWS::STS::UseGlobalEndpoint")
        else => return error.UnresolvedEndpointBuiltIn,
    };
    return x.id("source").dot().raw(field).consume();
}

pub const std_builtins: BuiltInsRegistry = &.{
    .{ BuiltIn.Id.of("AWS::Region"), BuiltIn{
        .type = .{ .string = null },
        .documentation = "The AWS region configured for the SDK client.",
    } },
    .{ BuiltIn.Id.of("AWS::UseDualStack"), BuiltIn{
        .type = .{ .boolean = false },
        .documentation = "If the SDK client is configured to use dual stack endpoints.",
    } },
    .{ BuiltIn.Id.of("AWS::UseFIPS"), BuiltIn{
        .type = .{ .boolean = false },
        .documentation = "If the SDK client is configured to use FIPS-compliant endpoints.",
    } },
    .{ BuiltIn.Id.of("AWS::Auth::AccountId"), BuiltIn{
        .type = .{ .string = null },
        .documentation = "The AWS AccountId.",
    } },
    .{ BuiltIn.Id.of("AWS::Auth::AccountIdEndpointMode"), BuiltIn{
        .type = .{ .string = null },
        .documentation = "The AccountId Endpoint Mode.",
    } },
    .{ BuiltIn.Id.of("AWS::Auth::CredentialScope"), BuiltIn{
        .type = .{ .string = null },
        .documentation = "The AWS Credential Scope.",
    } },
    .{ BuiltIn.Id.of("AWS::S3::Accelerate"), BuiltIn{
        .type = .{ .boolean = false },
        .documentation = "If the SDK client is configured to use S3 transfer acceleration.",
    } },
    .{ BuiltIn.Id.of("AWS::S3::DisableMultiRegionAccessPoints"), BuiltIn{
        .type = .{ .boolean = false },
        .documentation = "If the SDK client is configured to not use S3's multi-region access points.",
    } },
    .{ BuiltIn.Id.of("AWS::S3::ForcePathStyle"), BuiltIn{
        .type = .{ .boolean = false },
        .documentation = "If the SDK client is configured to use solely S3 path style routing.",
    } },
    .{ BuiltIn.Id.of("AWS::S3::UseArnRegion"), BuiltIn{
        .type = .{ .boolean = true },
        .documentation = "If the SDK client is configured to use S3 bucket ARN regions or raise an error when the bucket ARN and client region differ.",
    } },
    .{ BuiltIn.Id.of("AWS::S3::UseGlobalEndpoint"), BuiltIn{
        .type = .{ .boolean = false },
        .documentation = "If the SDK client is configured to use S3's global endpoint instead of the regional `us-east-1` endpoint.",
    } },
    .{ BuiltIn.Id.of("AWS::S3Control::UseArnRegion"), BuiltIn{
        .type = .{ .boolean = true },
        .documentation = "If the SDK client is configured to use S3 Control bucket ARN regions or raise an error when the bucket ARN and client region differ.",
    } },
    .{ BuiltIn.Id.of("AWS::STS::UseGlobalEndpoint"), BuiltIn{
        .type = .{ .boolean = false },
        .documentation = "If the SDK client is configured to use STS' global endpoint instead of the regional `us-east-1` endpoint.",
    } },
};

pub const std_functions: FunctionsRegistry = &.{
    .{ Function.Id.of("aws.partition"), Function{
        .returns = Expr{ .raw = "?*const " ++ aws_cfg.scope_private ++ ".Partition" },
        .returns_optional = true,
        .genFn = fnPartition,
    } },
    .{ Function.Id.of("aws.parseArn"), Function{
        .returns = Expr{ .raw = "?" ++ aws_cfg.scope_private ++ ".Arn" },
        .returns_optional = true,
        .genFn = fnParseArn,
    } },
    .{ Function.Id.of("aws.isVirtualHostableS3Bucket"), Function{
        .returns = Expr.typeOf(bool),
        .genFn = fnIsVirtualHostableS3Bucket,
    } },
};

fn fnPartition(gen: *Generator, x: ExprBuild, args: []const ArgValue) !Expr {
    const region = try gen.evalArg(x, args[0]);
    return x.call(aws_cfg.scope_private ++ ".resolvePartition", &.{x.fromExpr(region)}).consume();
}

test "fnPartition" {
    try Function.expect(fnPartition, &.{
        .{ .string = "us-east-1" },
    }, aws_cfg.scope_private ++ ".resolvePartition(\"us-east-1\")");
}

fn fnParseArn(gen: *Generator, x: ExprBuild, args: []const ArgValue) !Expr {
    const value = try gen.evalArg(x, args[0]);
    return x.call(aws_cfg.scope_private ++ ".Arn.init", &.{
        x.id(aws_cfg.stack_alloc),
        x.fromExpr(value),
    }).consume();
}

test "fnParseArn" {
    try Function.expect(fnParseArn, &.{
        .{ .string = "arn:aws:iam::012345678910:user/johndoe" },
    }, aws_cfg.scope_private ++ ".Arn.init(scratch_alloc, \"arn:aws:iam::012345678910:user/johndoe\")");
}

fn fnIsVirtualHostableS3Bucket(gen: *Generator, x: ExprBuild, args: []const ArgValue) !Expr {
    return x.call(aws_cfg.scope_private ++ ".isVirtualHostableS3Bucket", &.{
        x.fromExpr(try gen.evalArg(x, args[0])),
        x.fromExpr(try gen.evalArg(x, args[1])),
    }).consume();
}

test "fnIsVirtualHostableS3Bucket" {
    try Function.expect(fnIsVirtualHostableS3Bucket, &.{
        .{ .string = "foo" },
        .{ .boolean = false },
    }, aws_cfg.scope_private ++ ".isVirtualHostableS3Bucket(\"foo\", false)");
}
