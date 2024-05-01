//! Model validation
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/model-validation.html)

const TraitsList = @import("../symbols/traits.zig").TraitsList;

// TODO: Pending traits
// smithy.api#suppress
// smithy.api#traitValidators
pub const traits: TraitsList = &.{};
