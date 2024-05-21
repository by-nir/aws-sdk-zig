//! HTTP Protocol Compliance Tests
//!
//! Smithy is a protocol-agnostic IDL that tries to abstract the serialization
//! format of request and response messages sent between a client and server.
//!
//! [Smithy Spec](https://smithy.io/2.0/additional-specs/http-protocol-compliance-tests.html)
const TraitsList = @import("../symbols/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsList = &.{
    // smithy.test#httpMalformedRequestTests
    // smithy.test#httpRequestTests
    // smithy.test#httpResponseTests
};
