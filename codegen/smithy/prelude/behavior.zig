//! Behavior traits
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/behavior-traits.html)

const TraitsList = @import("../symbols/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsList = &.{
    // smithy.api#idempotencyToken
    // smithy.api#idempotent
    // smithy.api#readonly
    // smithy.api#retryable
    // smithy.api#paginated
    // smithy.api#requestCompression
};
