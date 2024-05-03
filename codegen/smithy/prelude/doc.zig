//! Documentation traits describe shapes in the model in a way that does not
//! materially affect the semantics of the model.
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/documentation-traits.html)

const TraitsList = @import("../symbols/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsList = &.{
    // smithy.api#deprecated
    // smithy.api#documentation
    // smithy.api#examples
    // smithy.api#externalDocumentation
    // smithy.api#internal
    // smithy.api#recommended
    // smithy.api#sensitive
    // smithy.api#since
    // smithy.api#tags
    // smithy.api#title
    // smithy.api#unstable
};
