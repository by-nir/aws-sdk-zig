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

// TODO: Remainig traits
pub const traits: TraitsList = &.{
    .{ Default.id, Default.parse },
    .{ default_added_id, null },
    .{ required_id, null },
    .{ client_optional_id, null },
    .{ EnumValue.id, EnumValue.parse },
    // smithy.api#error
    .{ input_id, null },
    .{ output_id, null },
    .{ sparse_id, null },
    .{ mixin_id, null },
};

pub const default_added_id = SmithyId.of("smithy.api#addedDefault");
pub const required_id = SmithyId.of("smithy.api#required");
pub const client_optional_id = SmithyId.of("smithy.api#clientOptional");
pub const input_id = SmithyId.of("smithy.api#input");
pub const output_id = SmithyId.of("smithy.api#output");
pub const sparse_id = SmithyId.of("smithy.api#sparse");
pub const mixin_id = SmithyId.of("mixin.api#mixin");

pub const Default = struct {
    pub const Value = JsonReader.Value;
    pub const id = SmithyId.of("smithy.api#default");

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        const value = try arena.create(Value);
        value.* = try reader.nextValueAlloc(arena);
        return value;
    }

    pub fn get(model: *const SmithyModel, shape_id: SmithyId) ?Value {
        return model.getTrait(shape_id, id, Value);
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
        return model.getTrait(shape_id, id, Val);
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
