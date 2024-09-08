//! Documentation traits describe shapes in the model in a way that does not
//! materially affect the semantics of the model.
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/documentation-traits.html)
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const trt = @import("../systems/traits.zig");
const StringTrait = trt.StringTrait;
const TraitsRegistry = trt.TraitsRegistry;
const JsonReader = @import("../utils/JsonReader.zig");

// TODO: Remainig traits
pub const registry: TraitsRegistry = &.{
    // smithy.api#deprecated
    .{ Documentation.id, Documentation.parse },
    // smithy.api#examples
    // smithy.api#externalDocumentation
    // smithy.api#internal
    // smithy.api#recommended
    // smithy.api#sensitive
    // smithy.api#since
    // smithy.api#tags
    .{ Title.id, Title.parse },
    // smithy.api#unstable
};

/// Adds documentation to a shape or member using the [CommonMark](https://spec.commonmark.org) format.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/documentation-traits.html#documentation-trait)
pub const Documentation = StringTrait("smithy.api#documentation");

/// Defines a proper name for a service or resource shape.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/documentation-traits.html#title-trait)
pub const Title = StringTrait("smithy.api#title");
