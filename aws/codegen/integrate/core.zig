//! Various AWS-specific traits are used to integrate Smithy models with other
//! AWS products like AWS CloudFormation and tools like the AWS SDKs.
//!
//! [Smithy Spec](https://smithy.io/2.0/aws/aws-core.html#aws-core-specification)
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const smithy = @import("smithy/codegen");
const SmithyId = smithy.SmithyId;
const SymbolsProvider = smithy.SymbolsProvider;
const TraitsRegistry = smithy.TraitsRegistry;
const JsonReader = smithy.JsonReader;

// TODO: Remainig traits
pub const traits: TraitsRegistry = &.{
    // aws.api#arn
    // aws.api#arnReference
    // aws.api#clientDiscoveredEndpoint
    // aws.api#clientEndpointDiscovery
    // aws.api#clientEndpointDiscoveryId
    // aws.api#controlPlane
    // aws.api#data
    // aws.api#dataPlane
    .{ Service.id, Service.parse },
    // aws.api#tagEnabled
    // aws.api#taggable
};

/// This trait provides information about the service like the name used to
/// generate AWS SDK client classes and the namespace used in ARNs.
///
/// [Smithy Spec](https://smithy.io/2.0/aws/aws-core.html#aws-api-service-trait)
pub const Service = struct {
    pub const id = SmithyId.of("aws.api#service");

    pub const Value = struct {
        /// Specifies the AWS SDK service ID. This value is used for generating
        /// client names in SDKs and for linking between services.
        sdk_id: []const u8,
        /// Specifies the AWS CloudFormation service name.
        cloudformation_name: ?[]const u8 = null,
        /// Defines the [ARN service namespace](http://docs.aws.amazon.com/general/latest/gr/aws-arns-and-namespaces.html#genref-aws-service-namespaces)
        /// of the service.
        arn_namespace: ?[]const u8 = null,
        /// Defines the AWS customer-facing eventSource property contained in
        /// CloudTrail [event records](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-event-reference-record-contents.html)
        /// emitted by the service.
        cloud_trail_source: ?[]const u8 = null,
        /// Used to implement linking between service and SDK documentation for
        /// AWS services.
        doc_id: ?[]const u8 = null,
        /// Identifies which endpoint in a given region should be used to
        /// connect to the service.
        endpoint_prefix: ?[]const u8 = null,
    };

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        const service = try arena.create(Value);
        service.* = Value{ .sdk_id = "" };

        try reader.nextObjectBegin();
        while (try reader.peek() == .string) {
            const prop = try reader.nextString();
            const val = try reader.nextStringAlloc(arena);
            if (mem.eql(u8, prop, "sdkId")) {
                service.sdk_id = val;
            } else if (mem.eql(u8, prop, "cloudFormationName")) {
                service.cloudformation_name = val;
            } else if (mem.eql(u8, prop, "arnNamespace")) {
                service.arn_namespace = val;
            } else if (mem.eql(u8, prop, "cloudTrailEventSource")) {
                service.cloud_trail_source = val;
            } else if (mem.eql(u8, prop, "docId")) {
                service.doc_id = val;
            } else if (mem.eql(u8, prop, "endpointPrefix")) {
                service.endpoint_prefix = val;
            } else {
                unreachable;
            }
        }
        try reader.nextObjectEnd();

        return service;
    }

    pub fn get(symbols: *SymbolsProvider, shape_id: SmithyId) ?*const Value {
        return symbols.getTrait(Value, shape_id, id);
    }
};

test "Service" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc,
        \\{
        \\  "sdkId": "foo",
        \\  "cloudFormationName": "bar",
        \\  "arnNamespace": "baz",
        \\  "cloudTrailEventSource": "qux",
        \\  "docId": "108",
        \\  "endpointPrefix": "109"
        \\}
    );
    errdefer reader.deinit();

    const service: *const Service.Value = @alignCast(@ptrCast(Service.parse(arena_alloc, &reader) catch |e| {
        reader.deinit();
        return e;
    }));
    reader.deinit();
    try testing.expectEqualDeep(&Service.Value{
        .sdk_id = "foo",
        .cloudformation_name = "bar",
        .arn_namespace = "baz",
        .cloud_trail_source = "qux",
        .doc_id = "108",
        .endpoint_prefix = "109",
    }, service);
}
