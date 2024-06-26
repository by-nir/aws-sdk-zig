//! Waiters are a client-side abstraction used to poll a resource until a
//! desired state is reached, or until it is determined that the resource will
//! never enter into the desired state.
//!
//! [Smithy Spec](https://smithy.io/2.0/additional-specs/waiters.html)
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const registry: TraitsRegistry = &.{
    // smithy.waiters#waitable
};
