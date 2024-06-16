//! Serialization and Protocol traits
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/protocol-traits.html)
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const registry: TraitsRegistry = &.{
    // smithy.api#protocolDefinition
    // smithy.api#jsonName
    // smithy.api#mediaType
    // smithy.api#timestampFormat
    // smithy.api#xmlAttribute
    // smithy.api#xmlFlattened
    // smithy.api#xmlName
    // smithy.api#xmlNamespace
};
