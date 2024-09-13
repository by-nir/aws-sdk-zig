const SmithyId = @import("smithy_id.zig").SmithyId;
const SmithyRefMapValue = @import("mapping.zig").SmithyRefMapValue;

/// A service is the entry point of an API that aggregates resources and operations together.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/service-types.html#service)
pub const SmithyService = struct {
    /// Defines the optional version of the service.
    version: ?[]const u8 = null,
    /// Binds a set of operation shapes to the service.
    operations: []const SmithyId = &.{},
    /// Binds a set of resource shapes to the service.
    resources: []const SmithyId = &.{},
    /// Defines a list of common errors that every operation bound within the closure of the service can return.
    errors: []const SmithyId = &.{},
    /// Disambiguates shape name conflicts in the
    /// [service closure](https://smithy.io/2.0/spec/service-types.html#service-closure).
    rename: []const SmithyRefMapValue = &.{},
};

/// The operation type represents the input, output, and possible errors of an API operation.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/service-types.html#resource)
pub const SmithyResource = struct {
    /// Defines a map of identifier string names to Shape IDs used to identify the resource.
    identifiers: []const SmithyRefMapValue = &.{},
    /// Defines a map of property string names to Shape IDs that enumerate the properties of the resource.
    properties: []const SmithyRefMapValue = &.{},
    /// Defines the lifecycle operation used to create a resource using one or more identifiers created by the service.
    create: ?SmithyId = null,
    /// Defines an idempotent lifecycle operation used to create a resource using identifiers provided by the client.
    put: ?SmithyId = null,
    /// Defines the lifecycle operation used to retrieve the resource.
    read: ?SmithyId = null,
    /// Defines the lifecycle operation used to update the resource.
    update: ?SmithyId = null,
    /// Defines the lifecycle operation used to delete the resource.
    delete: ?SmithyId = null,
    /// Defines the lifecycle operation used to list resources of this type.
    list: ?SmithyId = null,
    /// Binds a list of non-lifecycle instance operations to the resource.
    operations: []const SmithyId = &.{},
    /// Binds a list of non-lifecycle collection operations to the resource.
    collection_ops: []const SmithyId = &.{},
    /// Binds a list of resources to this resource as a child resource, forming a containment relationship.
    resources: []const SmithyId = &.{},
};

/// Smithy defines a resource as an entity with an identity that has a set of operations.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/service-types.html#operation)
pub const SmithyOperation = struct {
    /// The input of the operation defined using a shape ID that MUST target a structure.
    input: ?SmithyId = null,
    /// The output of the operation defined using a shape ID that MUST target a structure.
    output: ?SmithyId = null,
    /// The errors that an operation can return.
    errors: []const SmithyId = &.{},
};
