const std = @import("std");

/// [Simple](https://smithy.io/2.0/spec/simple-types.html#simple-types) or
/// [Aggregate](https://smithy.io/2.0/spec/aggregate-types.html#aggregate-types) shape.
pub const SmithyType = union(enum) {
    //
    // Simple types are types that do not contain nested types or shape references.
    //

    /// Uninterpreted binary data.
    blob,
    /// Boolean value type.
    boolean,
    /// UTF-8 encoded string.
    string,
    /// A string with a fixed set of values.
    /// [Smithy Spec](https://smithy.io/2.0/spec/simple-types.html#enum)
    @"enum": SmithyEnum,
    /// 8-bit signed integer ranging from -128 to 127 (inclusive).
    byte,
    /// 16-bit signed integer ranging from -32,768 to 32,767 (inclusive).
    short,
    /// 32-bit signed integer ranging from -2^31 to (2^31)-1 (inclusive).
    integer,
    /// An integer with a fixed set of values.
    /// [Smithy Spec](https://smithy.io/2.0/spec/simple-types.html#intenum)
    int_enum,
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
    /// [Smithy Spec](https://smithy.io/2.0/spec/simple-types.html#timestamp)
    timestamp: TimeStampFormat,
    /// Open content that functions as a kind of "any" type.
    /// [Smithy Spec](https://smithy.io/2.0/spec/simple-types.html#document)
    document,

    //
    // Aggregate types contain configurable member references to others shapes.
    //

    /// Ordered collection of homogeneous values.
    /// [Smithy Spec](https://smithy.io/2.0/spec/aggregate-types.html#list)
    list: *const SmithyList,
    /// Map data structure that maps string keys to homogeneous values.
    /// [Smithy Spec](https://smithy.io/2.0/spec/aggregate-types.html#map)
    map: *const SmithyMap,
    /// Fixed set of named heterogeneous members.
    /// [Smithy Spec](https://smithy.io/2.0/spec/aggregate-types.html#structure)
    structure: *const SmithyStructure,
    /// Tagged union data structure that can take on one of several different, but fixed, types.
    /// [Smithy Spec](https://smithy.io/2.0/spec/aggregate-types.html#union)
    @"union": *const SmithyUnion,
};

/// A string with a fixed set of values.
/// Enums are non-exhaustive, clients must allow sending and receiving unknown values.
/// [Smithy Spec](https://smithy.io/2.0/spec/simple-types.html#enum)
pub const SmithyEnum = struct {
    count: u8,
    members: [*]Member,

    pub const Member = packed struct {
        name: [:0]const u8,
        value: [:0]const u8,
    };
};

/// An integer with a fixed set of values.
/// int_enums are non-exhaustive, clients must allow sending and receiving unknown values.
/// [Smithy Spec](https://smithy.io/2.0/spec/simple-types.html#intenum)
pub const SmithyIntEnum = struct {
    count: u8,
    members: [*]Member,

    pub const Member = packed struct {
        value: i32,
        name: [:0]const u8,
    };
};

/// Defines an optional custom timestamp serialization format.
/// [Smithy Spec](https://smithy.io/2.0/spec/protocol-traits.html#timestamp-formats)
pub const TimeStampFormat = enum {
    /// By default, the serialization format of a timestamp is implicitly determined
    /// by the protocol of a service.
    default,
    /// Date time as defined by the date-time production in RFC 3339 (section 5.6),
    /// with optional millisecond precision but no UTC offset.
    /// ```
    /// 1985-04-12T23:20:50.520Z
    /// ```
    date_time,
    /// An HTTP date as defined by the IMF-fixdate production in RFC 7231 (section 7.1.1.1).
    /// ```
    /// Tue, 29 Apr 2014 18:30:38 GMT
    /// ```
    http_date,
    /// Also known as Unix time, the number of seconds that have elapsed since
    /// _00:00:00 Coordinated Universal Time (UTC), Thursday, 1 January 1970_,
    /// with optional millisecond precision.
    /// ```
    /// 1515531081.123
    /// ```
    epoch_seconds,
};

/// Ordered collection of homogeneous values.
/// [Smithy Spec](https://smithy.io/2.0/spec/aggregate-types.html#list)
pub const SmithyList = struct {
    member: SmithyType,
    /// Lists are considered `dense` by default.
    spread: AggregateOptional = .dense,
};

/// Map data structure that maps string keys to homogeneous values.
/// [Smithy Spec](https://smithy.io/2.0/spec/aggregate-types.html#map)
pub const SmithyMap = struct {
    key: SmithyType,
    value: SmithyType,
    /// Maps are considered `dense` by default.
    /// The sparse trait has no effect on keys; map keys are never allowed to be null.
    spread: AggregateOptional = .dense,
};

/// [Smithy Spec](https://smithy.io/2.0/spec/type-refinement-traits.html#sparse-trait)
pub const AggregateOptional = enum {
    /// Null values are not allowed in the aggregate.
    dense,
    /// Indicates that an aggregate MAY contain null values.
    sparse,
};

/// Fixed set of named heterogeneous members.
/// [Smithy Spec](https://smithy.io/2.0/spec/aggregate-types.html#structure)
pub const SmithyStructure = struct {
    count: u8,
    members: [*]SmithyMember,
};

/// Tagged union data structure that can take on one of several different, but fixed, types.
/// [Smithy Spec](https://smithy.io/2.0/spec/aggregate-types.html#union)
pub const SmithyUnion = struct {
    count: u8,
    members: ?[*]SmithyMember,
};

/// The actual list of traits MUST follow this member!
/// [Smithy Spec](https://smithy.io/2.0/spec/idl.html#structure-shapes)
pub const SmithyMember = packed struct {
    target: SmithyType,
    name: [:0]const u8,
    traits_count: u8,
};
