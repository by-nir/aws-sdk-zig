//! Type refinement traits are traits that significantly refine, or change,
//! the type of a shape.
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/type-refinement-traits.html)

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const SmithyId = @import("../symbols/identity.zig").SmithyId;
const TraitsList = @import("../symbols/traits.zig").TraitsList;
const SmithyModel = @import("../symbols/shapes.zig").SmithyModel;
const JsonReader = @import("../utils/JsonReader.zig");

// TODO: Pending traits
// smithy.api#default
// smithy.api#addedDefault
// smithy.api#required
// smithy.api#clientOptional
// smithy.api#error
// smithy.api#input
// smithy.api#output
// smithy.api#sparse
// smithy.api#mixin
pub const traits: TraitsList = &.{
    .{ EnumValue.id, EnumValue.parse },
};

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
    errdefer reader.deinit();

    const val_int: *const EnumValue.Val = @alignCast(@ptrCast(try EnumValue.parse(allocator, &reader)));
    reader.deinit();
    try testing.expectEqualDeep(&EnumValue.Val{ .integer = 108 }, val_int);

    reader = try JsonReader.initFixed(allocator, "\"foo\"");
    const val_str: *const EnumValue.Val = @alignCast(@ptrCast(try EnumValue.parse(allocator, &reader)));
    reader.deinit();
    try testing.expectEqualDeep(&EnumValue.Val{ .string = "foo" }, val_str);
}
