//! Smoke tests are small, simple tests intended to uncover large issues by
//! ensuring core functionality works as expected.
//!
//! [Smithy Spec](https://smithy.io/2.0/additional-specs/smoke-tests.html)
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsRegistry = &.{
    // smithy.test#smokeTests
};
