//! The Smithy rules engine provides service owners with a collection of traits
//! and components to define rule sets. Rule sets specify a type of client
//! behavior to be resolved at runtime, for example rules-based endpoint or
//! authentication scheme resolution.
//!
//! [Smithy Spec](https://smithy.io/2.0/additional-specs/rules-engine/index.html)
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const symbols = @import("../systems/symbols.zig");
const SmithyId = symbols.SmithyId;
const SmithyModel = symbols.SmithyModel;
const idHash = symbols.idHash;
const RulesBuiltInId = enum(symbols.IdHashInt) {
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

const RulesFunctionId = enum(symbols.IdHashInt) {
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

pub const ParamType = enum {
    string,
    boolean,
    string_array,
};

const ParamValue = union(ParamType) {
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

pub const StringValue = union(enum) {
    string: []const u8,
    reference: []const u8,
    function: FunctionCall,
};

pub fn StringKV(comptime T: type) type {
    return struct {
        key: []const u8,
        value: T,
    };
}

/// Defines a rule set for deriving service endpoints at runtime.
///
/// [Smithy Spec](https://smithy.io/2.0/additional-specs/rules-engine/specification.html#smithy-rules-endpointruleset-trait)
pub const EndpointRuleSet = struct {
    pub const id = SmithyId.of("smithy.rules#endpointRuleSet");

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        const value = try arena.create(RuleSet);
        errdefer arena.destroy(value);

        try reader.nextObjectBegin();
        while (try reader.peek() != .object_end) {
            const prop = try reader.nextString();
            if (mem.eql(u8, prop, "parameters")) {
                var list = std.ArrayList(StringKV(Parameter)).init(arena);
                errdefer list.deinit();

                try reader.nextObjectBegin();
                while (try reader.peek() != .object_end) {
                    try list.append(try parseParameter(arena, reader));
                }
                try reader.nextObjectEnd();

                value.parameters = try list.toOwnedSlice();
            } else if (mem.eql(u8, prop, "rules")) {
                value.rules = try parseRules(arena, reader);
            } else if (mem.eql(u8, prop, "version")) {
                try reader.nextStringEql("1.0");
            } else {
                std.log.warn("Unknown EndpointRuleSet property `{s}`", .{prop});
                try reader.skipValueOrScope();
            }
        }
        try reader.nextObjectEnd();

        return value;
    }

    /// Sadly, at the time of writing the models position the type property at the end.
    fn parseParameter(arena: Allocator, reader: *JsonReader) !StringKV(Parameter) {
        var kv = StringKV(Parameter){
            .value = .{ .type = undefined },
            .key = try reader.nextStringAlloc(arena),
        };
        errdefer arena.free(kv.key);

        var did_set_type = false;
        try reader.nextObjectBegin();
        while (try reader.peek() != .object_end) {
            const prop = try reader.nextString();
            if (mem.eql(u8, prop, "type")) {
                if (did_set_type) {
                    try reader.skipValueOrScope();
                } else {
                    kv.value.type = if (std.ascii.eqlIgnoreCase(prop, "string"))
                        .{ .string = null }
                    else if (std.ascii.eqlIgnoreCase(prop, "boolean"))
                        .{ .boolean = null }
                    else if (std.ascii.eqlIgnoreCase(prop, "stringArray"))
                        .{ .string_array = null }
                    else
                        return error.UnexpectedType;
                    did_set_type = true;
                }
            } else if (mem.eql(u8, prop, "default")) {
                if (did_set_type) {
                    kv.value.type = switch (kv.value.type) {
                        .string => .{ .string = try reader.nextStringAlloc(arena) },
                        .boolean => .{ .boolean = try reader.nextBoolean() },
                        .string_array => blk: {
                            var list = std.ArrayList([]const u8).init(arena);
                            errdefer list.deinit();

                            try reader.nextArrayBegin();
                            while (try reader.peek() != .array_end) {
                                try list.append(try reader.nextStringAlloc(arena));
                            }
                            try reader.nextArrayEnd();

                            break :blk .{ .string_array = try list.toOwnedSlice() };
                        },
                    };
                } else {
                    const token = try reader.nextValueAlloc(arena);
                    kv.value.type = switch (token) {
                        .boolean => |t| .{ .boolean = t },
                        .string => |t| .{ .string = t },
                        .array => |t| blk: {
                            var list = try std.ArrayList([]const u8).initCapacity(arena, t.len);
                            errdefer list.deinit();

                            for (t) |v| {
                                list.appendAssumeCapacity(v.string);
                            }

                            arena.free(t);
                            break :blk .{ .string_array = try list.toOwnedSlice() };
                        },
                        else => return error.UnexpectedType,
                    };
                    did_set_type = true;
                }
            } else if (mem.eql(u8, prop, "documentation")) {
                kv.value.documentation = try reader.nextStringAlloc(arena);
            } else if (mem.eql(u8, prop, "builtIn")) {
                kv.value.built_in = RulesBuiltInId.of(try reader.nextStringAlloc(arena));
            } else if (mem.eql(u8, prop, "required")) {
                kv.value.required = try reader.nextBoolean();
            } else if (mem.eql(u8, prop, "deprecated")) {
                kv.value.deprecated = try parseDeprecated(arena, reader);
            } else {
                std.log.warn("Unknown Parameter property `{s}`", .{prop});
                try reader.skipValueOrScope();
            }
        }
        try reader.nextObjectEnd();

        return kv;
    }

    fn parseDeprecated(arena: Allocator, reader: *JsonReader) !Deprecated {
        var value = Deprecated{};
        try reader.nextObjectBegin();
        while (try reader.peek() != .object_end) {
            const prop = try reader.nextString();
            if (mem.eql(u8, prop, "message")) {
                value.message = try reader.nextStringAlloc(arena);
            } else if (mem.eql(u8, prop, "since")) {
                value.since = try reader.nextStringAlloc(arena);
            } else {
                std.log.warn("Unknown Deprecated property `{s}`", .{prop});
                try reader.skipValueOrScope();
            }
        }
        try reader.nextObjectEnd();
        return value;
    }

    fn parseConditions(arena: Allocator, reader: *JsonReader) ![]const Condition {
        var list = std.ArrayList(Condition).init(arena);
        errdefer list.deinit();

        try reader.nextArrayBegin();
        while (try reader.next() == .object_begin) {
            var condition = Condition{};
            while (try reader.peek() != .object_end) {
                const prop = try reader.nextString();
                if (mem.eql(u8, prop, "fn")) {
                    condition.function = try reader.nextStringAlloc(arena);
                } else if (mem.eql(u8, prop, "argv")) {
                    condition.args = try parseFunctionArgs(arena, reader);
                } else if (mem.eql(u8, prop, "assign")) {
                    condition.assign = try reader.nextStringAlloc(arena);
                } else {
                    std.log.warn("Unknown Condition property `{s}`", .{prop});
                    try reader.skipValueOrScope();
                }
            }
            try reader.nextObjectEnd();
            try list.append(condition);
        }

        return list.toOwnedSlice();
    }

    fn parseFunctionArgs(arena: Allocator, reader: *JsonReader) ![]const ArgValue {
        var list = std.ArrayList(ArgValue).init(arena);
        errdefer list.deinit();

        try reader.nextArrayBegin();
        var peek = try reader.peek();
        while (peek != .array_end) : (peek = try reader.peek()) {
            try list.append(switch (peek) {
                inline .true, .false => |g| blk: {
                    _ = try reader.next();
                    break :blk .{ .boolean = g == .true };
                },
                .string => .{ .string = try reader.nextStringAlloc(arena) },
                .array_begin => .{ .array = try parseFunctionArgs(arena, reader) },
                .object_begin => switch (try parseFuncOrRef(arena, reader)) {
                    .reference => |t| .{ .reference = t },
                    .function => |t| .{ .function = t },
                },
                else => return error.UnexpectedType,
            });
        }
        try reader.nextArrayEnd();

        return list.toOwnedSlice();
    }

    fn parseStringValue(arena: Allocator, reader: *JsonReader) !StringValue {
        return switch (try reader.peek()) {
            .string => .{ .string = try reader.nextStringAlloc(arena) },
            .object_begin => switch (try parseFuncOrRef(arena, reader)) {
                .reference => |t| .{ .reference = t },
                .function => |t| .{ .function = t },
            },
            else => error.UnexpectedType,
        };
    }

    fn parseStringValuesArray(arena: Allocator, reader: *JsonReader) ![]const StringValue {
        var list = std.ArrayList(StringValue).init(arena);
        errdefer list.deinit();

        try reader.nextArrayBegin();
        while (try reader.peek() != .array_end) {
            try list.append(try parseStringValue(arena, reader));
        }
        try reader.nextArrayEnd();

        return list.toOwnedSlice();
    }

    const FuncOrRef = union(enum) {
        function: FunctionCall,
        reference: []const u8,
    };

    fn parseFuncOrRef(arena: Allocator, reader: *JsonReader) anyerror!FuncOrRef {
        var func = FunctionCall{};
        try reader.nextObjectBegin();
        while (try reader.peek() != .object_end) {
            const prop = try reader.nextString();
            if (mem.eql(u8, prop, "ref")) {
                const value = .{ .reference = try reader.nextStringAlloc(arena) };
                try reader.nextObjectEnd();
                return value;
            } else if (mem.eql(u8, prop, "fn")) {
                func.name = RulesFunctionId.of(try reader.nextStringAlloc(arena));
            } else if (mem.eql(u8, prop, "argv")) {
                func.args = try parseFunctionArgs(arena, reader);
            } else {
                std.log.warn("Unknown Function or Reference property `{s}`", .{prop});
                try reader.skipValueOrScope();
            }
        }
        try reader.nextObjectEnd();
        return .{ .function = func };
    }

    fn parseRules(arena: Allocator, reader: *JsonReader) anyerror![]const Rule {
        var list = std.ArrayList(Rule).init(arena);
        errdefer list.deinit();

        try reader.nextArrayBegin();
        while (try reader.peek() != .array_end) {
            try list.append(try parseRule(arena, reader));
        }
        try reader.nextArrayEnd();

        return list.toOwnedSlice();
    }

    /// Sadly, at the time of writing the models position the type property at the end.
    fn parseRule(arena: Allocator, reader: *JsonReader) !Rule {
        var docs: ?[]const u8 = null;
        errdefer if (docs) |d| arena.free(d);
        var conditions: ?[]const Condition = null;
        errdefer if (conditions) |c| arena.free(c);

        try reader.nextObjectBegin();
        while (try reader.peek() != .object_end) {
            const prop = try reader.nextString();
            if (mem.eql(u8, prop, "conditions")) {
                conditions = try parseConditions(arena, reader);
            } else if (mem.eql(u8, prop, "documentation")) {
                docs = try reader.nextStringAlloc(arena);
            } else if (mem.eql(u8, prop, "error")) {
                return .{ .err = try parseErrorRule(arena, reader, docs, conditions, true) };
            } else if (mem.eql(u8, prop, "endpoint")) {
                return .{ .endpoint = try parseEndpointRule(arena, reader, docs, conditions, true) };
            } else if (mem.eql(u8, prop, "rules")) {
                return .{ .tree = try parseTreeRule(arena, reader, docs, conditions, true) };
            } else if (mem.eql(u8, prop, "type")) {
                const t = try reader.nextString();
                return if (mem.eql(u8, t, "error"))
                    .{ .err = try parseErrorRule(arena, reader, docs, conditions, false) }
                else if (mem.eql(u8, t, "endpoint"))
                    .{ .endpoint = try parseEndpointRule(arena, reader, docs, conditions, false) }
                else if (mem.eql(u8, t, "tree"))
                    .{ .tree = try parseTreeRule(arena, reader, docs, conditions, false) }
                else
                    error.UnrecognizedRule;
            } else {
                std.log.warn("Unknown Rule property `{s}`", .{prop});
                try reader.skipValueOrScope();
            }
        }
        try reader.nextObjectEnd();

        return error.UnrecognizedRule;
    }

    fn ruleBegin(reader: *JsonReader, docs: ?[]const u8, conditions: ?[]const Condition, mid_prop: ?bool) !void {
        if (docs != null or conditions != null or mid_prop != null) return;
        try reader.nextObjectBegin();
    }

    fn rulePropFirst(reader: *JsonReader, mid_prop: ?bool, term: []const u8) ![]const u8 {
        if (mid_prop) |mid| if (mid) return term;
        return rulePropNext(reader);
    }

    fn rulePropNext(reader: *JsonReader) ![]const u8 {
        return switch (try reader.next()) {
            .string => |s| s,
            .object_end => "",
            else => unreachable,
        };
    }

    fn parseErrorRule(
        arena: Allocator,
        reader: *JsonReader,
        fill_docs: ?[]const u8,
        fill_conditions: ?[]const Condition,
        mid_prop: ?bool,
    ) !ErrorRule {
        var rule = ErrorRule{
            .message = undefined,
            .conditions = fill_conditions orelse &.{},
            .documentation = fill_docs,
        };
        try ruleBegin(reader, fill_docs, fill_conditions, mid_prop);
        var prop = try rulePropFirst(reader, mid_prop, "error");
        while (prop.len > 0) : (prop = try rulePropNext(reader)) {
            if (mem.eql(u8, prop, "conditions")) {
                rule.conditions = try parseConditions(arena, reader);
            } else if (mem.eql(u8, prop, "documentation")) {
                rule.documentation = try reader.nextStringAlloc(arena);
            } else if (mem.eql(u8, prop, "error")) {
                rule.message = try parseStringValue(arena, reader);
            } else if (mem.eql(u8, prop, "type")) {
                try reader.skipValueOrScope();
            } else {
                std.log.warn("Unknown ErrorRule property `{s}`", .{prop});
                try reader.skipValueOrScope();
            }
        }
        return rule;
    }

    fn parseTreeRule(
        arena: Allocator,
        reader: *JsonReader,
        fill_docs: ?[]const u8,
        fill_conditions: ?[]const Condition,
        mid_prop: bool,
    ) !TreeRule {
        var rule = TreeRule{
            .rules = undefined,
            .conditions = fill_conditions orelse &.{},
            .documentation = fill_docs,
        };
        try ruleBegin(reader, fill_docs, fill_conditions, mid_prop);
        var prop = try rulePropFirst(reader, mid_prop, "rules");
        while (prop.len > 0) : (prop = try rulePropNext(reader)) {
            if (mem.eql(u8, prop, "conditions")) {
                rule.conditions = try parseConditions(arena, reader);
            } else if (mem.eql(u8, prop, "documentation")) {
                rule.documentation = try reader.nextStringAlloc(arena);
            } else if (mem.eql(u8, prop, "rules")) {
                rule.rules = try parseRules(arena, reader);
            } else if (mem.eql(u8, prop, "type")) {
                try reader.skipValueOrScope();
            } else {
                std.log.warn("Unknown TreeRule property `{s}`", .{prop});
                try reader.skipValueOrScope();
            }
        }
        return rule;
    }

    fn parseEndpointRule(
        arena: Allocator,
        reader: *JsonReader,
        fill_docs: ?[]const u8,
        fill_conditions: ?[]const Condition,
        mid_prop: bool,
    ) !EndpointRule {
        var rule = EndpointRule{
            .endpoint = undefined,
            .conditions = fill_conditions orelse &.{},
            .documentation = fill_docs,
        };
        try ruleBegin(reader, fill_docs, fill_conditions, mid_prop);
        var prop = try rulePropFirst(reader, mid_prop, "endpoint");
        while (prop.len > 0) : (prop = try rulePropNext(reader)) {
            if (mem.eql(u8, prop, "conditions")) {
                rule.conditions = try parseConditions(arena, reader);
            } else if (mem.eql(u8, prop, "documentation")) {
                rule.documentation = try reader.nextStringAlloc(arena);
            } else if (mem.eql(u8, prop, "endpoint")) {
                rule.endpoint = try parseEndpoint(arena, reader);
            } else if (mem.eql(u8, prop, "type")) {
                try reader.skipValueOrScope();
            } else {
                std.log.warn("Unknown EndpointRule property `{s}`", .{prop});
                try reader.skipValueOrScope();
            }
        }
        return rule;
    }

    fn parseEndpoint(arena: Allocator, reader: *JsonReader) !Endpoint {
        var endpoint = Endpoint{ .url = undefined };
        try reader.nextObjectBegin();
        while (try reader.peek() != .object_end) {
            const prop = try reader.nextString();
            if (mem.eql(u8, prop, "url")) {
                endpoint.url = try parseStringValue(arena, reader);
            } else if (mem.eql(u8, prop, "properties")) {
                endpoint.properties = (try reader.nextValueAlloc(arena)).object;
            } else if (mem.eql(u8, prop, "headers")) {
                var list = std.ArrayList(StringKV([]const StringValue)).init(arena);
                errdefer list.deinit();

                try reader.nextObjectBegin();
                while (try reader.peek() != .object_end) {
                    try list.append(.{
                        .key = try reader.nextStringAlloc(arena),
                        .value = try parseStringValuesArray(arena, reader),
                    });
                }
                try reader.nextObjectEnd();

                endpoint.headers = try list.toOwnedSlice();
            } else {
                std.log.warn("Unknown Endpoint property `{s}`", .{prop});
                try reader.skipValueOrScope();
            }
        }
        try reader.nextObjectEnd();
        return endpoint;
    }
};

test "EndpointRuleSet" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc,
        \\{
        \\  "version": "1.0",
        \\  "parameters": {
        \\    "Foo": {
        \\      "builtIn": "Foo",
        \\      "required": true,
        \\      "documentation": "Foo docs...",
        \\      "default": "Bar",
        \\      "type": "String",
        \\      "deprecated": {
        \\        "message": "Baz",
        \\        "since": "0.8"
        \\      }
        \\    }
        \\  },
        \\  "rules": [{
        \\     "conditions": [{
        \\       "fn": "foo",
        \\       "assign": "bar",
        \\       "argv": ["baz", true, [], {"ref": "qux"}, {"fn": "Bar", "argv": []}]
        \\     }],
        \\     "rules": [
        \\       {
        \\         "conditions": [],
        \\         "error": "BOOM"
        \\       },
        \\       {
        \\         "conditions": [],
        \\         "endpoint": {
        \\           "url": "http://example.com",
        \\           "properties": { "foo": null },
        \\           "headers": { "bar": [] }
        \\         }
        \\       }
        \\     ],
        \\     "documentation": "Tree docs...",
        \\     "type": "tree"
        \\  }]
        \\}
    );

    const value: *const RuleSet = @alignCast(@ptrCast(EndpointRuleSet.parse(arena_alloc, &reader) catch |e| {
        reader.deinit();
        return e;
    }));
    reader.deinit();
    try testing.expectEqualDeep(&RuleSet{
        .parameters = &.{
            .{
                .key = "Foo",
                .value = Parameter{
                    .type = .{ .string = "Bar" },
                    .built_in = RulesBuiltInId.of("Foo"),
                    .required = true,
                    .documentation = "Foo docs...",
                    .deprecated = .{
                        .message = "Baz",
                        .since = "0.8",
                    },
                },
            },
        },
        .rules = &.{.{
            .tree = TreeRule{
                .documentation = "Tree docs...",
                .conditions = &.{
                    Condition{
                        .function = "foo",
                        .assign = "bar",
                        .args = &.{
                            .{ .string = "baz" },
                            .{ .boolean = true },
                            .{ .array = &.{} },
                            .{ .reference = "qux" },
                            .{ .function = FunctionCall{
                                .name = RulesFunctionId.of("Bar"),
                                .args = &.{},
                            } },
                        },
                    },
                },
                .rules = &.{
                    .{
                        .err = ErrorRule{
                            .message = .{ .string = "BOOM" },
                        },
                    },
                    .{
                        .endpoint = EndpointRule{
                            .endpoint = .{
                                .url = .{ .string = "http://example.com" },
                                .properties = &.{
                                    .{ .key = "foo", .value = .null },
                                },
                                .headers = &.{
                                    .{ .key = "bar", .value = &.{} },
                                },
                            },
                        },
                    },
                },
            },
        }},
    }, value);
}
