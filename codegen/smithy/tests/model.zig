const std = @import("std");
const test_alloc = std.testing.allocator;
const syb_id = @import("../symbols/identity.zig");
const SmithyId = syb_id.SmithyId;
const SmithyType = syb_id.SmithyType;
const TaggedValue = syb_id.SmithyTaggedValue;
const syb_shapes = @import("../symbols/shapes.zig");
const SmithyMeta = syb_shapes.SmithyMeta;
const SmithyModel = syb_shapes.SmithyModel;
const SmithyService = syb_shapes.SmithyService;
const SmithyOperation = syb_shapes.SmithyOperation;
const SmithyResource = syb_shapes.SmithyResource;
const trt_refine = @import("../prelude/refine.zig");
const trt_constr = @import("../prelude/constraint.zig");

pub fn setupUnit(model: *SmithyModel) !void {
    try model.shapes.put(test_alloc, SmithyId.of("test#Unit"), .unit);
}

pub fn setupList(model: *SmithyModel) !void {
    try model.names.put(test_alloc, SmithyId.of("test#List"), "List");
    try model.shapes.put(test_alloc, SmithyId.of("test#List"), .{
        .list = .integer,
    });
    try model.traits.put(test_alloc, SmithyId.of("test#List"), &.{
        .{ .id = trt_refine.sparse_id, .value = null },
    });

    try model.names.put(test_alloc, SmithyId.of("test#Set"), "Set");
    try model.shapes.put(test_alloc, SmithyId.of("test#Set"), .{
        .list = .integer,
    });
    try model.traits.put(test_alloc, SmithyId.of("test#Set"), &.{
        .{ .id = trt_constr.unique_items_id, .value = null },
    });
}

pub fn setupMap(model: *SmithyModel) !void {
    try model.names.put(test_alloc, SmithyId.of("test#Map"), "Map");
    try model.shapes.put(test_alloc, SmithyId.of("test#Map"), .{
        .map = .{ .integer, .integer },
    });
    try model.traits.put(test_alloc, SmithyId.of("test#Map"), &.{
        .{ .id = trt_refine.sparse_id, .value = null },
    });
}

const ENUM_TRT: trt_constr.Enum.Sentinel = &.{ .{ .value = "FOO_BAR" }, .{ .value = "baz$qux", .name = "BAZ_QUX" } };
const ENUM_STR = &.{ SmithyId.of("test#Enum$FOO_BAR"), SmithyId.of("test#Enum$BAZ_QUX") };
pub fn setupEnum(model: *SmithyModel) !void {
    try model.names.put(test_alloc, SmithyId.of("test#Enum"), "Enum");
    try model.shapes.put(test_alloc, SmithyId.of("test#Enum"), .{
        .str_enum = ENUM_STR,
    });
    try model.names.put(test_alloc, SmithyId.of("test#Enum$FOO_BAR"), "FOO_BAR");
    try model.shapes.put(test_alloc, SmithyId.of("test#Enum$FOO_BAR"), .unit);
    try model.names.put(test_alloc, SmithyId.of("test#Enum$BAZ_QUX"), "BAZ_QUX");
    try model.shapes.put(test_alloc, SmithyId.of("test#Enum$BAZ_QUX"), .unit);
    try model.traits.put(test_alloc, SmithyId.of("test#Enum$BAZ_QUX"), &.{.{
        .id = trt_refine.EnumValue.id,
        .value = &trt_refine.EnumValue.Val{ .string = "baz$qux" },
    }});

    try model.names.put(test_alloc, SmithyId.of("test#EnumTrt"), "EnumTrt");
    try model.shapes.put(test_alloc, SmithyId.of("test#EnumTrt"), .string);
    try model.traits.put(test_alloc, SmithyId.of("test#EnumTrt"), &.{.{
        .id = trt_constr.Enum.id,
        .value = ENUM_TRT,
    }});
}

const INT_ENUM = &.{ SmithyId.of("test#IntEnum$FOO_BAR"), SmithyId.of("test#IntEnum$BAZ_QUX") };
pub fn setupIntEnum(model: *SmithyModel) !void {
    try model.names.put(test_alloc, SmithyId.of("test#IntEnum"), "IntEnum");
    try model.shapes.put(test_alloc, SmithyId.of("test#IntEnum"), .{
        .int_enum = INT_ENUM,
    });
    try model.names.put(test_alloc, SmithyId.of("test#IntEnum$FOO_BAR"), "FOO_BAR");
    try model.shapes.put(test_alloc, SmithyId.of("test#IntEnum$FOO_BAR"), .unit);
    try model.traits.put(test_alloc, SmithyId.of("test#IntEnum$FOO_BAR"), &.{.{
        .id = trt_refine.EnumValue.id,
        .value = &trt_refine.EnumValue.Val{ .integer = 8 },
    }});
    try model.names.put(test_alloc, SmithyId.of("test#IntEnum$BAZ_QUX"), "BAZ_QUX");
    try model.shapes.put(test_alloc, SmithyId.of("test#IntEnum$BAZ_QUX"), .unit);
    try model.traits.put(test_alloc, SmithyId.of("test#IntEnum$BAZ_QUX"), &.{.{
        .id = trt_refine.EnumValue.id,
        .value = &trt_refine.EnumValue.Val{ .integer = 9 },
    }});
}

const UNION = &.{
    SmithyId.of("test#Union$FOO"),
    SmithyId.of("test#Union$BAR"),
    SmithyId.of("test#Union$BAZ"),
};
pub fn setupUnion(model: *SmithyModel) !void {
    try model.names.put(test_alloc, SmithyId.of("test#Union"), "Union");
    try model.shapes.put(test_alloc, SmithyId.of("test#Union"), .{
        .tagged_uinon = UNION,
    });
    try model.names.put(test_alloc, SmithyId.of("test#Union$FOO"), "FOO");
    try model.shapes.put(test_alloc, SmithyId.of("test#Union$FOO"), .unit);
    try model.names.put(test_alloc, SmithyId.of("test#Union$BAR"), "BAR");
    try model.shapes.put(test_alloc, SmithyId.of("test#Union$BAR"), .integer);
    try model.names.put(test_alloc, SmithyId.of("test#Union$BAZ"), "BAZ");
    try model.shapes.put(test_alloc, SmithyId.of("test#Union$BAZ"), .string);
}

const STRUCUT = &.{ SmithyId.of("test#Struct$fooBar"), SmithyId.of("test#Struct$bazQux") };
const STRUCUT_MIXINS = &.{SmithyId.of("test#Mixin")};
const STRUCUT_MIXED = &.{SmithyId.of("test#Mixin$mixed")};
pub fn setupStruct(model: *SmithyModel) !void {
    try setupIntEnum(model);

    try model.names.put(test_alloc, SmithyId.of("test#Struct"), "Struct");
    try model.shapes.put(test_alloc, SmithyId.of("test#Struct"), .{
        .structure = STRUCUT,
    });
    try model.mixins.put(test_alloc, SmithyId.of("test#Struct"), STRUCUT_MIXINS);
    try model.names.put(test_alloc, SmithyId.of("test#Struct$fooBar"), "fooBar");
    try model.shapes.put(test_alloc, SmithyId.of("test#Struct$fooBar"), .integer);
    try model.traits.put(test_alloc, SmithyId.of("test#Struct$fooBar"), &.{
        .{ .id = trt_refine.required_id, .value = null },
    });
    try model.names.put(test_alloc, SmithyId.of("test#Struct$bazQux"), "bazQux");
    try model.shapes.put(test_alloc, SmithyId.of("test#Struct$bazQux"), .{
        .target = SmithyId.of("test#IntEnum"),
    });
    try model.traits.put(test_alloc, SmithyId.of("test#Struct$bazQux"), &.{.{
        .id = trt_refine.Default.id,
        .value = &trt_refine.Default.Value{ .integer = 8 },
    }});

    try model.names.put(test_alloc, SmithyId.of("test#Mixin"), "Mixin");
    try model.shapes.put(test_alloc, SmithyId.of("test#Mixin"), .{
        .structure = STRUCUT_MIXED,
    });
    try model.traits.put(test_alloc, SmithyId.of("test#Mixin"), &.{
        .{ .id = trt_refine.mixin_id, .value = null },
    });
    try model.names.put(test_alloc, SmithyId.of("test#Mixin$mixed"), "mixed");
    try model.shapes.put(test_alloc, SmithyId.of("test#Mixin$mixed"), .boolean);
}

pub fn setupService(model: *SmithyModel) !void {
    try model.shapes.put(test_alloc, SmithyId.of("test.operation#Input$Foo"), .{
        .structure = &.{},
    });
    try model.traits.put(test_alloc, SmithyId.of("test.operation#Input$Foo"), &.{
        .{ .id = SmithyId.of("smithy.api#property"), .value = "test.resource#prop" },
    });
    try model.shapes.put(test_alloc, SmithyId.of("test.operation#Input"), .{
        .structure = &.{SmithyId.of("test.operation#Input$Foo")},
    });
    try model.shapes.put(test_alloc, SmithyId.of("test.operation#Output"), .{
        .structure = &.{},
    });
    try model.shapes.put(test_alloc, SmithyId.of("test.error#NotFound"), .{
        .structure = &.{},
    });
    try model.traits.put(test_alloc, SmithyId.of("test.error#NotFound"), &.{
        .{ .id = SmithyId.of("smithy.api#error"), .value = "client" },
    });
    try model.shapes.put(test_alloc, SmithyId.of("test.serve#Operation"), .{
        .operation = &SmithyOperation{
            .input = SmithyId.of("test.operation#Input"),
            .output = SmithyId.of("test.operation#Output"),
            .errors = &.{SmithyId.of("test.error#NotFound")},
        },
    });

    try model.shapes.put(test_alloc, SmithyId.of("test.resource#prop"), .string);
    try model.shapes.put(test_alloc, SmithyId.of("test.serve#Resource"), .{
        .resource = &SmithyResource{
            .identifiers = &.{
                .{ .name = "forecastId", .shape = SmithyId.of("smithy.api#String") },
            },
            .properties = &.{
                .{ .name = "prop", .shape = SmithyId.of("test.resource#prop") },
            },
            .create = SmithyId.of("test.serve#Operation"),
            .put = SmithyId.of("test.serve#Operation"),
            .read = SmithyId.of("test.serve#Operation"),
            .update = SmithyId.of("test.serve#Operation"),
            .delete = SmithyId.of("test.serve#Operation"),
            .list = SmithyId.of("test.serve#Operation"),
            .operations = &.{SmithyId.of("test.serve#Operation")},
            .collection_ops = &.{SmithyId.of("test.serve#Operation")},
            .resources = &.{},
        },
    });

    try model.shapes.put(test_alloc, SmithyId.of("test.serve#Error"), .{
        .structure = &.{},
    });
    try model.traits.put(test_alloc, SmithyId.of("test.serve#Service"), &.{
        .{
            .id = SmithyId.of("smithy.api#documentation"),
            .value = "Foo bar baz.",
        },
    });
    try model.shapes.put(test_alloc, SmithyId.of("test.serve#Service"), .{
        .service = &SmithyService{
            .version = "2017-02-11",
            .operations = &.{SmithyId.of("test.serve#Operation")},
            .resources = &.{SmithyId.of("test.serve#Resource")},
            .errors = &.{SmithyId.of("test.serve#Error")},
        },
    });
}
