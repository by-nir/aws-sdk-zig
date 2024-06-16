//! MQTT Protocol Bindings
//!
//! [Smithy Spec](https://smithy.io/2.0/additional-specs/mqtt.html)
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const registry: TraitsRegistry = &.{
    // smithy.mqtt#publish
    // smithy.mqtt#subscribe
    // smithy.mqtt#topicLabel
};
