//! Authentication traits
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/authentication-traits.html)
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsRegistry = &.{
    // smithy.api#auth
    // smithy.api#authDefinition
    // smithy.api#httpBasicAuth
    // smithy.api#httpBearerAuth
    // smithy.api#httpApiKeyAuth
    // smithy.api#httpDigestAuth
    // smithy.api#optionalAuth
};
