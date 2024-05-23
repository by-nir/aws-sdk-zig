//! MQTT Protocol Bindings
//!
//! [Smithy Spec](https://smithy.io/2.0/additional-specs/mqtt.html)
const TraitsList = @import("../symbols/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsList = &.{
    // smithy.mqtt#publish
    // smithy.mqtt#subscribe
    // smithy.mqtt#topicLabel
};
