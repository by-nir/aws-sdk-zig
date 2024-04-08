//! All Smithy models automatically include a prelude.
//!
//! The prelude defines various simple shapes and every trait defined in the
//! core specification. When using the IDL, shapes defined in the prelude that
//! are not marked with the private trait can be referenced from within any
//! namespace using a relative shape ID.
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/model.html#prelude)

pub const TYPE_UNIT = "smithy.api#Unit";
pub const TYPE_BLOB = "smithy.api#Blob";
pub const TYPE_BOOL = "smithy.api#Boolean";
pub const TYPE_STRING = "smithy.api#String";
pub const TYPE_BYTE = "smithy.api#Byte";
pub const TYPE_SHORT = "smithy.api#Short";
pub const TYPE_INT = "smithy.api#Integer";
pub const TYPE_LONG = "smithy.api#Long";
pub const TYPE_FLOAT = "smithy.api#Float";
pub const TYPE_DOUBLE = "smithy.api#Double";
pub const TYPE_BIGINT = "smithy.api#BigInteger";
pub const TYPE_BIGDEC = "smithy.api#BigDecimal";
pub const TYPE_TIMESTAMP = "smithy.api#Timestamp";
pub const TYPE_DOCUMENT = "smithy.api#Document";

/// [Smithy Spec](https://smithy.io/2.0/spec/type-refinement-traits.html#sparse-trait)
pub const AggregateOptional = enum {
    /// Null values are not allowed in the aggregate.
    dense,
    /// Indicates that an aggregate MAY contain null values.
    sparse,
};

/// Defines an optional custom timestamp serialization format.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/protocol-traits.html#timestamp-formats)
pub const TimestampFormat = enum {
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
