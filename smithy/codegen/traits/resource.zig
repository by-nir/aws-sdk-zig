//! Resource traits
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/resource-traits.html)
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const registry: TraitsRegistry = &.{
    // smithy.api#nestedProperties
    // smithy.api#noReplace
    // smithy.api#notProperty
    // smithy.api#property
    // smithy.api#references
    // smithy.api#resourceIdentifier
};
