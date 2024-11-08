const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const mdl = @import("model.zig");
const lib = @import("library.zig");
const JsonReader = @import("../../utils/JsonReader.zig");

const ParamKV = mdl.StringKV(mdl.Parameter);

pub fn parseRuleSet(arena: Allocator, reader: *JsonReader) !mdl.RuleSet {
    var value = mdl.RuleSet{};

    try reader.nextObjectBegin();
    while (try reader.peek() != .object_end) {
        const prop = try reader.nextString();
        if (mem.eql(u8, prop, "parameters")) {
            var list = std.ArrayList(ParamKV).init(arena);
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

// Sadly, at the time of writing the models position the type property at the end.
fn parseParameter(arena: Allocator, reader: *JsonReader) !ParamKV {
    var kv = ParamKV{
        .value = .{ .type = undefined },
        .key = try reader.nextStringAlloc(arena),
    };
    errdefer arena.free(kv.key);

    var did_set_type = false;
    try reader.nextObjectBegin();
    while (try reader.peek() != .object_end) {
        var prop = try reader.nextString();
        if (mem.eql(u8, prop, "type")) {
            if (did_set_type) {
                try reader.skipValueOrScope();
            } else {
                prop = try reader.nextString();
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
            kv.value.built_in = lib.BuiltIn.Id.of(try reader.nextStringAlloc(arena));
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

fn parseDeprecated(arena: Allocator, reader: *JsonReader) !mdl.Deprecated {
    var value = mdl.Deprecated{};
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

fn parseConditions(arena: Allocator, reader: *JsonReader) ![]const mdl.Condition {
    var list = std.ArrayList(mdl.Condition).init(arena);
    errdefer list.deinit();

    try reader.nextArrayBegin();
    while (try reader.next() == .object_begin) {
        var condition = mdl.Condition{};
        while (try reader.peek() != .object_end) {
            const prop = try reader.nextString();
            if (mem.eql(u8, prop, "fn")) {
                condition.function = lib.Function.Id.of(try reader.nextStringAlloc(arena));
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

fn parseFunctionArgs(arena: Allocator, reader: *JsonReader) ![]const mdl.ArgValue {
    var list = std.ArrayList(mdl.ArgValue).init(arena);
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

fn parseStringValue(arena: Allocator, reader: *JsonReader) !mdl.StringValue {
    return switch (try reader.peek()) {
        .string => .{ .string = try reader.nextStringAlloc(arena) },
        .object_begin => switch (try parseFuncOrRef(arena, reader)) {
            .reference => |t| .{ .reference = t },
            .function => |t| .{ .function = t },
        },
        else => error.UnexpectedType,
    };
}

fn parseStringValuesArray(arena: Allocator, reader: *JsonReader) ![]const mdl.StringValue {
    var list = std.ArrayList(mdl.StringValue).init(arena);
    errdefer list.deinit();

    try reader.nextArrayBegin();
    while (try reader.peek() != .array_end) {
        try list.append(try parseStringValue(arena, reader));
    }
    try reader.nextArrayEnd();

    return list.toOwnedSlice();
}

const FuncOrRef = union(enum) {
    function: mdl.FunctionCall,
    reference: []const u8,
};

fn parseFuncOrRef(arena: Allocator, reader: *JsonReader) anyerror!FuncOrRef {
    var func = mdl.FunctionCall{};
    try reader.nextObjectBegin();
    while (try reader.peek() != .object_end) {
        const prop = try reader.nextString();
        if (mem.eql(u8, prop, "ref")) {
            const value = FuncOrRef{ .reference = try reader.nextStringAlloc(arena) };
            try reader.nextObjectEnd();
            return value;
        } else if (mem.eql(u8, prop, "fn")) {
            func.id = lib.Function.Id.of(try reader.nextStringAlloc(arena));
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

fn parseRules(arena: Allocator, reader: *JsonReader) anyerror![]const mdl.Rule {
    var list = std.ArrayList(mdl.Rule).init(arena);
    errdefer list.deinit();

    try reader.nextArrayBegin();
    while (try reader.peek() != .array_end) {
        try list.append(try parseRule(arena, reader));
    }
    try reader.nextArrayEnd();

    return list.toOwnedSlice();
}

/// Sadly, at the time of writing the models position the type property at the end.
fn parseRule(arena: Allocator, reader: *JsonReader) !mdl.Rule {
    var docs: ?[]const u8 = null;
    errdefer if (docs) |d| arena.free(d);
    var conditions: ?[]const mdl.Condition = null;
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

fn ruleBegin(reader: *JsonReader, docs: ?[]const u8, conditions: ?[]const mdl.Condition, mid_prop: ?bool) !void {
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
    fill_conditions: ?[]const mdl.Condition,
    mid_prop: ?bool,
) !mdl.ErrorRule {
    var rule = mdl.ErrorRule{
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
    fill_conditions: ?[]const mdl.Condition,
    mid_prop: bool,
) !mdl.TreeRule {
    var rule = mdl.TreeRule{
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
    fill_conditions: ?[]const mdl.Condition,
    mid_prop: bool,
) !mdl.EndpointRule {
    var rule = mdl.EndpointRule{
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

fn parseEndpoint(arena: Allocator, reader: *JsonReader) !mdl.Endpoint {
    var endpoint = mdl.Endpoint{ .url = undefined };
    try reader.nextObjectBegin();
    while (try reader.peek() != .object_end) {
        const prop = try reader.nextString();
        if (mem.eql(u8, prop, "url")) {
            endpoint.url = try parseStringValue(arena, reader);
        } else if (mem.eql(u8, prop, "properties")) {
            endpoint.properties = (try reader.nextValueAlloc(arena)).object;
        } else if (mem.eql(u8, prop, "headers")) {
            var list = std.ArrayList(mdl.StringKV([]const mdl.StringValue)).init(arena);
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

test "parseRuleSet" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    const source = @embedFile("../../testing/rules.json");
    var reader = try JsonReader.initFixed(arena_alloc, source);
    const value = try parseRuleSet(arena_alloc, &reader);
    reader.deinit();

    try testing.expectEqualDeep(mdl.RuleSet{
        .parameters = &.{
            .{
                .key = "Foo",
                .value = mdl.Parameter{
                    .type = .{ .string = "Bar" },
                    .built_in = lib.BuiltIn.Id.of("Foo"),
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
            .tree = mdl.TreeRule{
                .documentation = "Tree docs...",
                .conditions = &.{
                    mdl.Condition{
                        .function = lib.Function.Id.of("foo"),
                        .assign = "bar",
                        .args = &.{
                            .{ .string = "baz" },
                            .{ .boolean = true },
                            .{ .array = &.{} },
                            .{ .reference = "qux" },
                            .{ .function = mdl.FunctionCall{
                                .id = lib.Function.Id.of("Bar"),
                                .args = &.{},
                            } },
                        },
                    },
                },
                .rules = &.{
                    .{
                        .err = mdl.ErrorRule{
                            .message = .{ .string = "BOOM" },
                        },
                    },
                    .{
                        .endpoint = mdl.EndpointRule{
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

pub fn parseTests(arena: Allocator, reader: *JsonReader) ![]const mdl.TestCase {
    var cases = std.ArrayList(mdl.TestCase).init(arena);

    try reader.nextObjectBegin();
    while (try reader.peek() != .object_end) {
        const prop = try reader.nextString();
        if (mem.eql(u8, prop, "testCases")) {
            try reader.nextArrayBegin();
            while (try reader.peek() != .array_end) {
                try cases.append(try parseTestCase(arena, reader));
            }
            try reader.nextArrayEnd();
        } else if (mem.eql(u8, prop, "version")) {
            try reader.nextStringEql("1.0");
        } else {
            std.log.warn("Unknown EndpointTests property `{s}`", .{prop});
            try reader.skipValueOrScope();
        }
    }
    try reader.nextObjectEnd();

    try cases.append(.{});
    return cases.toOwnedSlice();
}

fn parseTestCase(arena: Allocator, reader: *JsonReader) !mdl.TestCase {
    var value: mdl.TestCase = .{};

    try reader.nextObjectBegin();
    while (try reader.peek() != .object_end) {
        const prop = try reader.nextString();
        if (mem.eql(u8, prop, "documentation")) {
            value.documentation = try reader.nextStringAlloc(arena);
        } else if (mem.eql(u8, prop, "expect")) {
            value.expect = try parseTestCaseExpect(arena, reader);
        } else if (mem.eql(u8, prop, "params")) {
            value.params = try parseTestCaseParams(arena, reader);
        } else {
            std.log.warn("Unknown Endpoint Test Case property `{s}`", .{prop});
            try reader.skipValueOrScope();
        }
    }
    try reader.nextObjectEnd();

    return value;
}

fn parseTestCaseExpect(arena: Allocator, reader: *JsonReader) !mdl.TestCase.Expect {
    try reader.nextObjectBegin();
    const prop = try reader.nextString();
    if (mem.eql(u8, prop, "endpoint")) {
        const endpoint = try parseEndpoint(arena, reader);
        try reader.nextObjectEnd();
        return .{ .endpoint = endpoint };
    } else if (mem.eql(u8, prop, "error")) {
        const err = try reader.nextStringAlloc(arena);
        try reader.nextObjectEnd();
        return .{ .err = err };
    } else {
        std.log.err("Unknown Endpoint Test Case property `{s}`", .{prop});
        return error.UnexpectedEndpointTestExpect;
    }
}

fn parseTestCaseParams(arena: Allocator, reader: *JsonReader) ![]const mdl.StringKV(mdl.ParamValue) {
    var params = std.ArrayList(mdl.StringKV(mdl.ParamValue)).init(arena);
    errdefer params.deinit();

    try reader.nextObjectBegin();
    while (try reader.peek() != .object_end) {
        const name = try reader.nextStringAlloc(arena);
        const value: mdl.ParamValue = switch (try reader.peek()) {
            .true, .false => .{ .boolean = try reader.nextBoolean() },
            .string => .{ .string = try reader.nextStringAlloc(arena) },
            .array_begin => blk: {
                var list = std.ArrayList([]const u8).init(arena);
                errdefer {
                    for (list.items) |s| arena.free(s);
                    list.deinit();
                }

                try reader.nextArrayBegin();
                while (try reader.peek() == .string) {
                    try list.append(try reader.nextStringAlloc(arena));
                }
                try reader.nextArrayEnd();

                break :blk .{ .string_array = try list.toOwnedSlice() };
            },
            else => return error.UnexpectedEndpointTestParam,
        };
        try params.append(.{ .key = name, .value = value });
    }
    try reader.nextObjectEnd();

    return params.toOwnedSlice();
}

test "parseTests" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc, @embedFile("../../testing/rules_cases.json"));
    const value = try parseTests(arena_alloc, &reader);
    reader.deinit();

    try testing.expectEqualDeep(&[_]mdl.TestCase{
        .{
            .documentation = "Test 1",
            .expect = .{
                .endpoint = .{
                    .url = .{ .string = "https://example.com" },
                    .headers = &.{
                        .{
                            .key = "foo",
                            .value = &.{ .{ .string = "bar" }, .{ .string = "baz" } },
                        },
                    },
                    .properties = &.{
                        .{ .key = "qux", .value = .null },
                    },
                },
            },
            .params = &[_]mdl.StringKV(mdl.ParamValue){
                .{ .key = "Foo", .value = .{ .string = "bar" } },
                .{ .key = "Baz", .value = .{ .boolean = true } },
            },
        },
        .{
            .documentation = "Test 2",
            .expect = .{ .err = "Fail..." },
            .params = &[_]mdl.StringKV(mdl.ParamValue){
                .{ .key = "Foo", .value = .{ .string = "bar" } },
            },
        },
        .{
            .documentation = "Test 3",
            .expect = .{ .err = "Boom!" },
            .params = &.{},
        },
        .{},
    }, value);
}
