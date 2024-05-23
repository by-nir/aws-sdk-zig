//! Endpoint traits
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/endpoint-traits.html)
const TraitsList = @import("../symbols/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsList = &.{
    // smithy.api#endpoint
    // smithy.api#hostLabel
};
