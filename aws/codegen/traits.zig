const smithy = @import("smithy/codegen");
const trt_iam = @import("traits/iam.zig");
const trt_auth = @import("traits/auth.zig");
const trt_core = @import("traits/core.zig");
const trt_gateway = @import("traits/gateway.zig");
const trt_endpoint = @import("traits/endpoints.zig");
const trt_protocol = @import("traits/protocols.zig");
const trt_cloudformation = @import("traits/cloudformation.zig");

pub const aws_traits: smithy.TraitsRegistry =
    trt_iam.traits ++
    trt_auth.traits ++
    trt_core.traits ++
    trt_gateway.traits ++
    trt_endpoint.traits ++
    trt_protocol.traits ++
    trt_cloudformation.traits;

test {
    _ = trt_iam;
    _ = trt_auth;
    _ = trt_core;
    _ = trt_gateway;
    _ = trt_endpoint;
    _ = trt_protocol;
    _ = trt_cloudformation;
}
