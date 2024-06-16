const std = @import("std");
const testing = std.testing;
const symbols = @import("../symbols.zig");
const idHash = symbols.idHash;
const JsonReader = @import("../../utils/JsonReader.zig");

pub const RulesBuiltInId = enum(symbols.IdHashInt) {
    pub const NULL: RulesBuiltInId = @enumFromInt(0);

    endpoint = idHash("SDK::Endpoint"),
    _,

    pub fn of(name: []const u8) RulesBuiltInId {
        return @enumFromInt(idHash(name));
    }
};

test "RulesBuiltInId" {
    try testing.expectEqual(.endpoint, RulesBuiltInId.of("SDK::Endpoint"));
    try testing.expectEqual(
        @as(RulesBuiltInId, @enumFromInt(0x472ff9ea)),
        RulesBuiltInId.of("FOO::Example"),
    );
}

pub const RulesFunctionId = enum(symbols.IdHashInt) {
    pub const NULL: RulesFunctionId = @enumFromInt(0);

    boolean_equals = idHash("booleanEquals"),
    get_attr = idHash("getAttr"),
    is_set = idHash("isSet"),
    is_valid_host_label = idHash("isValidHostLabel"),
    not = idHash("not"),
    parse_url = idHash("parseURL"),
    string_equals = idHash("stringEquals"),
    substring = idHash("substring"),
    uri_encode = idHash("uriEncode"),
    _,

    pub fn of(name: []const u8) RulesFunctionId {
        return @enumFromInt(idHash(name));
    }
};

test "RulesFunctionId" {
    try testing.expectEqual(.boolean_equals, RulesFunctionId.of("booleanEquals"));
    try testing.expectEqual(
        @as(RulesFunctionId, @enumFromInt(0xdcf4a50d)),
        RulesFunctionId.of("foo.example"),
    );
}

pub const Rule = union(enum) {
    endpoint: EndpointRule,
    err: ErrorRule,
    tree: TreeRule,
};

pub const RuleSet = struct {
    /// A map of zero or more endpoint parameter names to their parameter
    /// configuration.
    parameters: []const StringKV(Parameter) = &.{},
    /// One or more endpoint rule definitions of any rule type.
    rules: []const Rule = &.{},
};

pub const ParamValue = union(enum) {
    string: ?[]const u8,
    boolean: ?bool,
    string_array: ?[]const []const u8,
};

pub const ArgValue = union(enum) {
    string: []const u8,
    boolean: bool,
    array: []const ArgValue,
    reference: []const u8,
    function: FunctionCall,
};

/// The parameter typing is statically analyzed by the rules engine to validate
/// correct usage within the rule set.
///
/// [Smithy Spec](https://smithy.io/2.0/additional-specs/rules-engine/specification.html#parameter-object)
pub const Parameter = struct {
    /// Optionally specifies the default value for the parameter if not set.
    type: ParamValue,
    /// Specifies a named built-in value that is sourced and provided to the
    /// endpoint provider by a caller.
    built_in: ?RulesBuiltInId = null,
    /// Specifies that the parameter is required to be provided to the endpoint
    /// provider.
    required: ?bool = null,
    /// Specifies a string that will be used to generate API reference
    /// documentation for the endpoint parameter.
    documentation: []const u8 = "",
    /// Specifies whether an endpoint parameter has been deprecated.
    deprecated: ?Deprecated = null,
};

/// [Smithy Spec](https://smithy.io/2.0/additional-specs/rules-engine/specification.html#deprecated-object)
pub const Deprecated = struct {
    /// Specifies an optional message that can be used in documentation to provide recourse options to a user.
    message: ?[]const u8 = null,
    /// A date string that indicates when the parameter field was deprecated.
    since: ?[]const u8 = null,
};

/// Defines an endpoint selected based on successful evaluation of rule
/// conditions to that point.
///
/// [Smithy Spec](https://smithy.io/2.0/additional-specs/rules-engine/specification.html#endpoint-object)
pub const Endpoint = struct {
    /// The endpoint url.
    url: StringValue,
    /// A map containing zero or more key value property pairs.
    properties: ?[]const JsonReader.Value.KV = null,
    /// A map of transport header names to their respective values.
    headers: ?[]const StringKV([]const StringValue) = null,
};

/// [Smithy Spec](https://smithy.io/2.0/additional-specs/rules-engine/specification.html#endpoint-rule-object)
pub const EndpointRule = struct {
    /// Zero or more conditions used to determine whether the endpoint rule
    /// should be selected.
    conditions: []const Condition = &.{},
    /// The endpoint to return if this rule is selected.
    endpoint: Endpoint,
    /// string	A description of the rule.
    documentation: ?[]const u8 = null,
};

/// If all condition clauses evaluate successfully or zero conditions are
/// defined, then the error rule _must_ be selected.
///
/// [Smithy Spec](https://smithy.io/2.0/additional-specs/rules-engine/specification.html#error-rule-object)
pub const ErrorRule = struct {
    /// Zero or more conditions used to determine whether the endpoint rule
    /// should be selected.
    conditions: []const Condition = &.{},
    /// A descriptive message describing the error for consumption by the caller.
    message: StringValue,
    /// A description of the rule.
    documentation: ?[]const u8 = null,
};

/// If all condition clauses evaluate successfully, the tree rule is selected. If a condition fails, evaluation of the rule MUST be terminated and evaluation proceeds to any subsequent rules.
///
/// [Smithy Spec](https://smithy.io/2.0/additional-specs/rules-engine/specification.html#tree-rule-object)
pub const TreeRule = struct {
    /// Zero or more conditions used to determine whether the endpoint rule
    /// should be selected.
    conditions: []const Condition = &.{},
    /// One or more endpoint rule definitions of any rule type.
    rules: []const Rule = &.{},
    /// A description of the rule.
    documentation: ?[]const u8 = null,
};

/// Conditions are requirements for continuing to evaluate the rules within.
/// Conditions are evaluated in-order by their positional index in the array,
/// starting from zero.
pub const Condition = struct {
    /// The name of the function to be executed.
    function: RulesFunctionId = RulesFunctionId.NULL,
    /// The arguments for the function.
    args: []const ArgValue = &.{},
    /// The destination variable to assign the functions result to.
    assign: ?[]const u8 = null,
};

/// [Smithy Spec](https://smithy.io/2.0/additional-specs/rules-engine/specification.html#function-object)
pub const FunctionCall = struct {
    /// The name of the function to be executed.
    name: RulesFunctionId = RulesFunctionId.NULL,
    /// The arguments for the function.
    args: []const ArgValue = &.{},
};

pub fn StringKV(comptime T: type) type {
    return struct {
        key: []const u8,
        value: T,
    };
}

pub const StringValue = union(enum) {
    string: []const u8,
    reference: []const u8,
    function: FunctionCall,
};
