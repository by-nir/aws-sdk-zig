//! Serialization and Protocol traits
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/protocol-traits.html)

const TraitsList = @import("../symbols/traits.zig").TraitsList;

// TODO: Pending traits
// smithy.api#protocolDefinition
// smithy.api#jsonName
// smithy.api#mediaType
// smithy.api#timestampFormat
// smithy.api#xmlAttribute
// smithy.api#xmlFlattened
// smithy.api#xmlName
// smithy.api#xmlNamespace
pub const traits: TraitsList = &.{};
