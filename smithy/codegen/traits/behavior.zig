//! Behavior traits
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/behavior-traits.html)
const SmithyId = @import("../model.zig").SmithyId;
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const registry: TraitsRegistry = &.{
    // smithy.api#idempotencyToken
    // smithy.api#idempotent
    // smithy.api#readonly
    .{ retryable_id, null },
    // smithy.api#paginated
    // smithy.api#requestCompression
};

/// Indicates that an error MAY be retried by the client.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/behavior-traits.html#retryable-trait)
pub const retryable_id = SmithyId.of("smithy.api#retryable");
