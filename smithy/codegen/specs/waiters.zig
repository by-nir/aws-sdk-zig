//! Waiters are a client-side abstraction used to poll a resource until a
//! desired state is reached, or until it is determined that the resource will
//! never enter into the desired state.
//!
//! [Smithy Spec](https://smithy.io/2.0/additional-specs/waiters.html)
const TraitsList = @import("../symbols/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsList = &.{
    // smithy.waiters#waitable
};
