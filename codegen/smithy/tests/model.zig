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

pub fn createEmpty() !*SmithyModel {
    const model = test_alloc.create(SmithyModel) catch unreachable;
    model.* = SmithyModel{
        .service = SmithyId.of("test.serve#Service"),
        .meta = .{},
        .shapes = .{},
        .traits = .{},
        .mixins = .{},
        .names = .{},
    };
    return model;
}

pub fn createAggragates() !*SmithyModel {
    const Static = struct {
        const enum_trt: trt_constr.Enum.Sentinel = &.{
            .{ .value = "FOO_BAR" },
            .{ .value = "baz$qux", .name = "BAZ_QUX" },
        };
        const str_enum = &.{ SmithyId.of("test#Enum$FOO_BAR"), SmithyId.of("test#Enum$BAZ_QUX") };
        const int_enum = &.{ SmithyId.of("test#IntEnum$FOO_BAR"), SmithyId.of("test#IntEnum$BAZ_QUX") };
        const tagged_union = &.{
            SmithyId.of("test#Union$FOO"),
            SmithyId.of("test#Union$BAR"),
            SmithyId.of("test#Union$BAZ"),
        };
        const structure = &.{ SmithyId.of("test#Struct$fooBar"), SmithyId.of("test#Struct$bazQux") };
    };

    const model = try createEmpty();

    try model.shapes.put(test_alloc, SmithyId.of("test#Unit"), .unit);

    try model.names.put(test_alloc, SmithyId.of("test#List"), "List");
    try model.shapes.put(test_alloc, SmithyId.of("test#List"), .{
        .list = .integer,
    });

    try model.names.put(test_alloc, SmithyId.of("test#Map"), "Map");
    try model.shapes.put(test_alloc, SmithyId.of("test#Map"), .{
        .map = .{ .integer, .integer },
    });

    try model.names.put(test_alloc, SmithyId.of("test#Enum"), "Enum");
    try model.shapes.put(test_alloc, SmithyId.of("test#Enum"), .{
        .str_enum = Static.str_enum,
    });
    try model.names.put(test_alloc, SmithyId.of("test#Enum$FOO_BAR"), "FOO_BAR");
    try model.shapes.put(test_alloc, SmithyId.of("test#Enum$FOO_BAR"), .unit);
    try model.names.put(test_alloc, SmithyId.of("test#Enum$BAZ_QUX"), "BAZ_QUX");
    try model.shapes.put(test_alloc, SmithyId.of("test#Enum$BAZ_QUX"), .unit);
    try model.traits.put(test_alloc, SmithyId.of("test#Enum$BAZ_QUX"), &.{
        .{
            .id = trt_refine.EnumValue.id,
            .value = &trt_refine.EnumValue.Val{ .string = "baz$qux" },
        },
    });

    try model.names.put(test_alloc, SmithyId.of("test#IntEnum"), "IntEnum");
    try model.shapes.put(test_alloc, SmithyId.of("test#IntEnum"), .{
        .int_enum = Static.int_enum,
    });
    try model.names.put(test_alloc, SmithyId.of("test#IntEnum$FOO_BAR"), "FOO_BAR");
    try model.shapes.put(test_alloc, SmithyId.of("test#IntEnum$FOO_BAR"), .unit);
    try model.traits.put(test_alloc, SmithyId.of("test#IntEnum$FOO_BAR"), &.{
        .{
            .id = trt_refine.EnumValue.id,
            .value = &trt_refine.EnumValue.Val{ .integer = 8 },
        },
    });
    try model.names.put(test_alloc, SmithyId.of("test#IntEnum$BAZ_QUX"), "BAZ_QUX");
    try model.shapes.put(test_alloc, SmithyId.of("test#IntEnum$BAZ_QUX"), .unit);
    try model.traits.put(test_alloc, SmithyId.of("test#IntEnum$BAZ_QUX"), &.{
        .{
            .id = trt_refine.EnumValue.id,
            .value = &trt_refine.EnumValue.Val{ .integer = 9 },
        },
    });

    try model.names.put(test_alloc, SmithyId.of("test#EnumTrt"), "EnumTrt");
    try model.shapes.put(test_alloc, SmithyId.of("test#EnumTrt"), .string);
    try model.traits.put(test_alloc, SmithyId.of("test#EnumTrt"), &.{
        .{
            .id = trt_constr.Enum.id,
            .value = Static.enum_trt,
        },
    });

    try model.names.put(test_alloc, SmithyId.of("test#Union"), "Union");
    try model.shapes.put(test_alloc, SmithyId.of("test#Union"), .{
        .tagged_uinon = Static.tagged_union,
    });
    try model.names.put(test_alloc, SmithyId.of("test#Union$FOO"), "FOO");
    try model.shapes.put(test_alloc, SmithyId.of("test#Union$FOO"), .unit);
    try model.names.put(test_alloc, SmithyId.of("test#Union$BAR"), "BAR");
    try model.shapes.put(test_alloc, SmithyId.of("test#Union$BAR"), .integer);
    try model.names.put(test_alloc, SmithyId.of("test#Union$BAZ"), "BAZ");
    try model.shapes.put(test_alloc, SmithyId.of("test#Union$BAZ"), .string);

    try model.names.put(test_alloc, SmithyId.of("test#Struct"), "Struct");
    try model.shapes.put(test_alloc, SmithyId.of("test#Struct"), .{
        .structure = Static.structure,
    });
    try model.names.put(test_alloc, SmithyId.of("test#Struct$fooBar"), "fooBar");
    try model.shapes.put(test_alloc, SmithyId.of("test#Struct$fooBar"), .integer);
    try model.names.put(test_alloc, SmithyId.of("test#Struct$bazQux"), "bazQux");
    try model.shapes.put(test_alloc, SmithyId.of("test#Struct$bazQux"), .{
        .target = SmithyId.of("test#IntEnum"),
    });

    return model;
}

pub fn createService() !*SmithyModel {
    const model = try createEmpty();

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

    return model;
}

pub fn deinitModel(model: *SmithyModel) void {
    model.meta.deinit(test_alloc);
    model.shapes.deinit(test_alloc);
    model.traits.deinit(test_alloc);
    model.mixins.deinit(test_alloc);
    model.names.deinit(test_alloc);
    test_alloc.destroy(model);
}
