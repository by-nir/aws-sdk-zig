//! Behavior traits
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/behavior-traits.html)
const symbols = @import("../systems/symbols.zig");
const SmithyId = symbols.SmithyId;
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsRegistry = &.{
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
