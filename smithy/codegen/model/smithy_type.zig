const std = @import("std");
const testing = std.testing;
const hash = std.hash.CityHash32.hash;
const srvc = @import("service.zig");
const SmithyId = @import("smithy_id.zig").SmithyId;

/// A Smithy shape’s type.
pub const SmithyType = union(enum) {
    /// A reference to a shape that is not a member of the prelude.
    target: SmithyId,

    /// The singular unit type in Smithy is similar to Void and None in other languages.
    /// It is used when the input or output of an operation has no meaningful value
    /// or if a union member has no meaningful value. It MUST NOT be referenced
    /// in any other context.
    ///
    /// [Smithy Spec](https://smithy.io/2.0/spec/model.html#unit-type)
    unit,

    //
    // Simple types are types that do not contain nested types or shape references.
    // https://smithy.io/2.0/spec/simple-types.html#simple-types
    //

    /// Uninterpreted binary data.
    blob,
    /// Boolean value type.
    boolean,
    /// UTF-8 encoded string.
    string,
    /// A string with a fixed set of values.
    str_enum: []const SmithyId,
    /// 8-bit signed integer ranging from -128 to 127 (inclusive).
    byte,
    /// 16-bit signed integer ranging from -32,768 to 32,767 (inclusive).
    short,
    /// 32-bit signed integer ranging from -2^31 to (2^31)-1 (inclusive).
    integer,
    /// An integer with a fixed set of values.
    int_enum: []const SmithyId,
    /// 64-bit signed integer ranging from -2^63 to (2^63)-1 (inclusive).
    long,
    /// Single precision IEEE-754 floating point number.
    float,
    /// Double precision IEEE-754 floating point number.
    double,
    /// Arbitrarily large signed integer.
    big_integer,
    /// Arbitrary precision signed decimal number.
    big_decimal,
    /// An instant in time with no UTC offset or timezone.
    timestamp,
    /// Open content that functions as a kind of "any" type.
    document,

    //
    // Aggregate types contain configurable member references to others shapes.
    // https://smithy.io/2.0/spec/aggregate-types.html#aggregate-types
    //

    /// Ordered collection of homogeneous values.
    list: SmithyId,
    /// Map data structure that maps string keys to homogeneous values.
    map: [2]SmithyId,
    /// Fixed set of named heterogeneous members.
    structure: []const SmithyId,
    /// Tagged union data structure that can take on one of several different, but fixed, types.
    tagged_uinon: []const SmithyId,

    //
    // Service types have specific semantics and define services, resources, and operations.
    // https://smithy.io/2.0/spec/service-types.html#service-types
    //

    /// The operation type represents the input, output, and possible errors of an API operation.
    operation: *const srvc.SmithyOperation,
    /// Smithy defines a resource as an entity with an identity that has a set of operations.
    resource: *const srvc.SmithyResource,
    /// A service is the entry point of an API that aggregates resources and operations together.
    service: *const srvc.SmithyService,
};
