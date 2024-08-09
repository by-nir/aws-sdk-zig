//! Endpoint traits
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/endpoint-traits.html)
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const registry: TraitsRegistry = &.{
    // smithy.api#endpoint
    // smithy.api#hostLabel
};
