//! Behavior traits
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/behavior-traits.html)
const TraitsList = @import("../symbols/traits.zig").TraitsRegistry;
const syb_id = @import("../symbols/identity.zig");
const SmithyId = syb_id.SmithyId;

// TODO: Remainig traits
pub const traits: TraitsList = &.{
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
