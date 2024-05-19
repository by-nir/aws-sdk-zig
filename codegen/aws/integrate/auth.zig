//! AWS Authentication Traits
//!
//! [Smithy Spec](https://smithy.io/2.0/aws/aws-auth.html#aws-authentication-traits)

const smithy = @import("smithy");
const TraitsList = smithy.TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsList = &.{
    // aws.auth#cognitoUserPools
    // aws.auth#sigv4
    // aws.auth#sigv4a
    // aws.auth#unsignedPayload
};
