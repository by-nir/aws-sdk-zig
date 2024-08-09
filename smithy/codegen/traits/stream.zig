//! Smithy operations can send and receive [streams of data](https://smithy.io/2.0/spec/streaming.html#data-streams)
//! or [streams of events](https://smithy.io/2.0/spec/streaming.html#event-streams).
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/streaming.html)
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const registry: TraitsRegistry = &.{
    // smithy.api#eventHeader
    // smithy.api#eventPayload
    // smithy.api#requiresLength
    // smithy.api#streaming
};
