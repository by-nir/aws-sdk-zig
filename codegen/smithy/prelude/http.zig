//! Smithy provides various HTTP binding traits that can be used by protocols to
//! explicitly configure HTTP request and response messages.
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/http-bindings.html)

const TraitsList = @import("../symbols/traits.zig").TraitsList;

// TODO: Pending traits
// smithy.api#http
// smithy.api#httpError
// smithy.api#httpHeader
// smithy.api#httpLabel
// smithy.api#httpPayload
// smithy.api#httpPrefixHeaders
// smithy.api#httpQuery
// smithy.api#httpQueryParams
// smithy.api#httpResponseCode
// smithy.api#cors
// smithy.api#httpChecksumRequired
pub const traits: TraitsList = &.{};
