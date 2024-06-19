const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const rls = @import("model.zig");
const lib = @import("library.zig");
const JsonReader = @import("../../utils/JsonReader.zig");

const ParamKV = rls.StringKV(rls.Parameter);

pub fn parse(arena: Allocator, reader: *JsonReader) !rls.RuleSet {
    var value = rls.RuleSet{};

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

fn parseDeprecated(arena: Allocator, reader: *JsonReader) !rls.Deprecated {
    var value = rls.Deprecated{};
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

fn parseConditions(arena: Allocator, reader: *JsonReader) ![]const rls.Condition {
    var list = std.ArrayList(rls.Condition).init(arena);
    errdefer list.deinit();

    try reader.nextArrayBegin();
    while (try reader.next() == .object_begin) {
        var condition = rls.Condition{};
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

fn parseFunctionArgs(arena: Allocator, reader: *JsonReader) ![]const rls.ArgValue {
    var list = std.ArrayList(rls.ArgValue).init(arena);
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

fn parseStringValue(arena: Allocator, reader: *JsonReader) !rls.StringValue {
    return switch (try reader.peek()) {
        .string => .{ .string = try reader.nextStringAlloc(arena) },
        .object_begin => switch (try parseFuncOrRef(arena, reader)) {
            .reference => |t| .{ .reference = t },
            .function => |t| .{ .function = t },
        },
        else => error.UnexpectedType,
    };
}

fn parseStringValuesArray(arena: Allocator, reader: *JsonReader) ![]const rls.StringValue {
    var list = std.ArrayList(rls.StringValue).init(arena);
    errdefer list.deinit();

    try reader.nextArrayBegin();
    while (try reader.peek() != .array_end) {
        try list.append(try parseStringValue(arena, reader));
    }
    try reader.nextArrayEnd();

    return list.toOwnedSlice();
}

const FuncOrRef = union(enum) {
    function: rls.FunctionCall,
    reference: []const u8,
};

fn parseFuncOrRef(arena: Allocator, reader: *JsonReader) anyerror!FuncOrRef {
    var func = rls.FunctionCall{};
    try reader.nextObjectBegin();
    while (try reader.peek() != .object_end) {
        const prop = try reader.nextString();
        if (mem.eql(u8, prop, "ref")) {
            const value = .{ .reference = try reader.nextStringAlloc(arena) };
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

fn parseRules(arena: Allocator, reader: *JsonReader) anyerror![]const rls.Rule {
    var list = std.ArrayList(rls.Rule).init(arena);
    errdefer list.deinit();

    try reader.nextArrayBegin();
    while (try reader.peek() != .array_end) {
        try list.append(try parseRule(arena, reader));
    }
    try reader.nextArrayEnd();

    return list.toOwnedSlice();
}

/// Sadly, at the time of writing the models position the type property at the end.
fn parseRule(arena: Allocator, reader: *JsonReader) !rls.Rule {
    var docs: ?[]const u8 = null;
    errdefer if (docs) |d| arena.free(d);
    var conditions: ?[]const rls.Condition = null;
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

fn ruleBegin(reader: *JsonReader, docs: ?[]const u8, conditions: ?[]const rls.Condition, mid_prop: ?bool) !void {
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
    fill_conditions: ?[]const rls.Condition,
    mid_prop: ?bool,
) !rls.ErrorRule {
    var rule = rls.ErrorRule{
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
    fill_conditions: ?[]const rls.Condition,
    mid_prop: bool,
) !rls.TreeRule {
    var rule = rls.TreeRule{
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
    fill_conditions: ?[]const rls.Condition,
    mid_prop: bool,
) !rls.EndpointRule {
    var rule = rls.EndpointRule{
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

fn parseEndpoint(arena: Allocator, reader: *JsonReader) !rls.Endpoint {
    var endpoint = rls.Endpoint{ .url = undefined };
    try reader.nextObjectBegin();
    while (try reader.peek() != .object_end) {
        const prop = try reader.nextString();
        if (mem.eql(u8, prop, "url")) {
            endpoint.url = try parseStringValue(arena, reader);
        } else if (mem.eql(u8, prop, "properties")) {
            endpoint.properties = (try reader.nextValueAlloc(arena)).object;
        } else if (mem.eql(u8, prop, "headers")) {
            var list = std.ArrayList(rls.StringKV([]const rls.StringValue)).init(arena);
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

test {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    const source = @embedFile("../../testing/rules.json");
    var reader = try JsonReader.initFixed(arena_alloc, source);
    const value = try parse(arena_alloc, &reader);
    reader.deinit();

    try testing.expectEqualDeep(rls.RuleSet{
        .parameters = &.{
            .{
                .key = "Foo",
                .value = rls.Parameter{
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
            .tree = rls.TreeRule{
                .documentation = "Tree docs...",
                .conditions = &.{
                    rls.Condition{
                        .function = lib.Function.Id.of("foo"),
                        .assign = "bar",
                        .args = &.{
                            .{ .string = "baz" },
                            .{ .boolean = true },
                            .{ .array = &.{} },
                            .{ .reference = "qux" },
                            .{ .function = rls.FunctionCall{
                                .id = lib.Function.Id.of("Bar"),
                                .args = &.{},
                            } },
                        },
                    },
                },
                .rules = &.{
                    .{
                        .err = rls.ErrorRule{
                            .message = .{ .string = "BOOM" },
                        },
                    },
                    .{
                        .endpoint = rls.EndpointRule{
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
