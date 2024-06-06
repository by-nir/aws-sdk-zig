//! Model validation
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/model-validation.html)
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsRegistry = &.{
    // smithy.api#suppress
    // smithy.api#traitValidators
};
