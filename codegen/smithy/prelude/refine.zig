//! Type refinement traits are traits that significantly refine, or change,
//! the type of a shape.
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/type-refinement-traits.html)

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const syb_id = @import("../symbols/identity.zig");
const SmithyId = syb_id.SmithyId;
const SmithyType = syb_id.SmithyType;
const TraitsList = @import("../symbols/traits.zig").TraitsRegistry;
const SmithyModel = @import("../symbols/shapes.zig").SmithyModel;
const JsonReader = @import("../utils/JsonReader.zig");

pub const traits: TraitsList = &.{
    .{ Default.id, Default.parse },
    .{ default_added_id, null },
    .{ required_id, null },
    .{ client_optional_id, null },
    .{ EnumValue.id, EnumValue.parse },
    .{ Error.id, Error.parse },
    .{ input_id, null },
    .{ output_id, null },
    .{ sparse_id, null },
    .{ mixin_id, null },
};

/// Indicates that the default trait was added to a structure member after
/// initially publishing the member.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/type-refinement-traits.html#addeddefault-trait)
pub const default_added_id = SmithyId.of("smithy.api#addedDefault");

/// Marks a structure member as required, meaning a value for the member MUST be present.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/type-refinement-traits.html#required-trait)
pub const required_id = SmithyId.of("smithy.api#required");

/// Requires that non-authoritative generators like clients treat a structure
/// member as optional regardless of if the member is also marked with the
/// _required trait_ or _default trait_.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/type-refinement-traits.html#clientoptional-trait)
pub const client_optional_id = SmithyId.of("smithy.api#clientOptional");

/// Specializes a structure for use only as the input of a single operation,
/// providing relaxed backward compatibility requirements for structure members.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/type-refinement-traits.html#input-trait)
pub const input_id = SmithyId.of("smithy.api#input");

/// Specializes a structure for use only as the output of a single operation.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/type-refinement-traits.html#output-trait)
pub const output_id = SmithyId.of("smithy.api#output");

/// Indicates that lists and maps MAY contain null values.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/type-refinement-traits.html#sparse-trait)
pub const sparse_id = SmithyId.of("smithy.api#sparse");

/// Indicates that the targeted shape is a mixin.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/type-refinement-traits.html#mixin-trait)
pub const mixin_id = SmithyId.of("mixin.api#mixin");

/// Provides a structure member with a default value.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/type-refinement-traits.html#default-trait)
pub const Default = struct {
    pub const Value = JsonReader.Value;
    pub const id = SmithyId.of("smithy.api#default");

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        const value = try arena.create(Value);
        value.* = try reader.nextValueAlloc(arena);
        return value;
    }

    pub fn get(model: *const SmithyModel, shape_id: SmithyId) ?Value {
        return model.getTrait(Value, shape_id, id);
    }
};

test "Default" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const allocator = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(allocator, "null");
    const val: *const Default.Value = @alignCast(@ptrCast(Default.parse(allocator, &reader) catch |e| {
        reader.deinit();
        return e;
    }));
    reader.deinit();
    try testing.expectEqual(.null, val.*);
}

/// Defines the value of an enum or intEnum.
/// - For `enum` shapes, a non-empty string value must be used.
/// - For `intEnum` shapes, an integer value must be used.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/type-refinement-traits.html#enumvalue-trait)
pub const EnumValue = struct {
    pub const id = SmithyId.of("smithy.api#enumValue");

    pub const Val = union(enum) {
        integer: i32,
        string: []const u8,
    };

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        const value = try arena.create(Val);
        value.* = switch (try reader.peek()) {
            .number => .{ .integer = @intCast(try reader.nextInteger()) },
            .string => .{ .string = try arena.dupe(u8, try reader.nextString()) },
            else => unreachable,
        };
        return value;
    }

    pub fn get(model: *const SmithyModel, shape_id: SmithyId) ?Val {
        return model.getTrait(Val, shape_id, id);
    }
};

test "EnumValue" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const allocator = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(allocator, "108");
    const val_int: *const EnumValue.Val = @alignCast(@ptrCast(EnumValue.parse(allocator, &reader) catch |e| {
        reader.deinit();
        return e;
    }));
    reader.deinit();
    try testing.expectEqualDeep(&EnumValue.Val{ .integer = 108 }, val_int);

    reader = try JsonReader.initFixed(allocator, "\"foo\"");
    const val_str: *const EnumValue.Val = @alignCast(@ptrCast(EnumValue.parse(allocator, &reader) catch |e| {
        reader.deinit();
        return e;
    }));
    reader.deinit();
    try testing.expectEqualDeep(&EnumValue.Val{ .string = "foo" }, val_str);
}

/// Indicates that a structure shape represents an error.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/type-refinement-traits.html#error-trait)
pub const Error = struct {
    pub const id = SmithyId.of("smithy.api#error");

    pub const Source = enum { client, server };

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        const source = try reader.nextString();
        const value = try arena.create(Source);
        value.* = if (source[0] == 'c') Source.client else Source.server;
        return value;
    }

    pub fn get(model: *const SmithyModel, shape_id: SmithyId) ?Source {
        return model.getTrait(Source, shape_id, id);
    }
};

test "Error" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const allocator = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(allocator, "\"client\"");
    const val_int: *const Error.Source = @alignCast(@ptrCast(Error.parse(allocator, &reader) catch |e| {
        reader.deinit();
        return e;
    }));
    reader.deinit();
    try testing.expectEqualDeep(&Error.Source.client, val_int);

    reader = try JsonReader.initFixed(allocator, "\"server\"");
    const val_str: *const Error.Source = @alignCast(@ptrCast(Error.parse(allocator, &reader) catch |e| {
        reader.deinit();
        return e;
    }));
    reader.deinit();
    try testing.expectEqualDeep(&Error.Source.server, val_str);
}
