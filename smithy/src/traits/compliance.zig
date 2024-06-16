//! HTTP Protocol Compliance Tests
//!
//! Smithy is a protocol-agnostic IDL that tries to abstract the serialization
//! format of request and response messages sent between a client and server.
//!
//! [Smithy Spec](https://smithy.io/2.0/additional-specs/http-protocol-compliance-tests.html)
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const registry: TraitsRegistry = &.{
    // smithy.test#httpMalformedRequestTests
    // smithy.test#httpRequestTests
    // smithy.test#httpResponseTests
};
