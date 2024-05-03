//! Resource traits
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/resource-traits.html)

const TraitsList = @import("../symbols/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsList = &.{
    // smithy.api#nestedProperties
    // smithy.api#noReplace
    // smithy.api#notProperty
    // smithy.api#property
    // smithy.api#references
    // smithy.api#resourceIdentifier
};
