const SmithyId = @import("smithy_id.zig").SmithyId;

/// Node values are JSON-like values used to define metadata and the value of an applied trait.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/model.html#node-values)
pub const SmithyMeta = union(enum) {
    /// The lack of a value.
    null,
    /// A UTF-8 string.
    string: []const u8,
    /// A double precision integer number.
    ///
    /// _Note: The original spec does not distinguish between number types._
    integer: i64,
    /// A double precision floating point number.
    ///
    /// _Note: The original spec does not distinguish between number types._
    float: f64,
    /// A Boolean, true or false value.
    boolean: bool,
    /// An array of heterogeneous node values.
    list: []const SmithyMeta,
    /// A object mapping string keys to heterogeneous node values.
    map: []const Pair,

    /// A key-value pair in a Map node.
    pub const Pair = struct {
        key: SmithyId,
        value: SmithyMeta,
    };
};
