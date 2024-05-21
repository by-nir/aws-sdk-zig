//! The Smithy rules engine provides service owners with a collection of traits
//! and components to define rule sets. Rule sets specify a type of client
//! behavior to be resolved at runtime, for example rules-based endpoint or
//! authentication scheme resolution.
//!
//! [Smithy Spec](https://smithy.io/2.0/additional-specs/rules-engine/index.html)
const TraitsList = @import("../symbols/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsList = &.{
    // smithy.rules#clientContextParams
    // smithy.rules#contextParam
    // smithy.rules#endpointRuleSet
    // smithy.rules#staticContextParams
};
