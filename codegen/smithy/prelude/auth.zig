//! Authentication traits
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/authentication-traits.html)

const TraitsList = @import("../symbols/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsList = &.{
    // smithy.api#auth
    // smithy.api#authDefinition
    // smithy.api#httpBasicAuth
    // smithy.api#httpBearerAuth
    // smithy.api#httpApiKeyAuth
    // smithy.api#httpDigestAuth
    // smithy.api#optionalAuth
};
