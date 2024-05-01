//! Constraint traits are used to constrain the values that can be provided for
//! a shape. Constraint traits are for validation only and SHOULD NOT impact the
//! types signatures of generated code.
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/constraint-traits.html)

const TraitsList = @import("../symbols/traits.zig").TraitsList;

// TODO: Pending traits
// smithy.api#idRef
// smithy.api#length
// smithy.api#pattern
// smithy.api#private
// smithy.api#range
// smithy.api#uniqueItems
// smithy.api#enum – Deprecated, but still used by most AWS services that declare enums
pub const traits: TraitsList = &.{};
