//! Model validation
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/model-validation.html)

const TraitsList = @import("../symbols/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsList = &.{
    // smithy.api#suppress
    // smithy.api#traitValidators
};
