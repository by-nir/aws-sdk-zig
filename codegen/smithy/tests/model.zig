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

pub fn getTestModel() !*SmithyModel {
    const model = try test_alloc.create(SmithyModel);
    model.* = SmithyModel{
        .service = SmithyId.of("test.serve#Service"),
        .meta = std.AutoHashMapUnmanaged(SmithyId, SmithyMeta){},
        .shapes = std.AutoHashMapUnmanaged(SmithyId, SmithyType){},
        .traits = std.AutoHashMapUnmanaged(SmithyId, []const TaggedValue){},
        .mixins = std.AutoHashMapUnmanaged(SmithyId, []const SmithyId){},
    };

    model.shapes.put(test_alloc, SmithyId.of("test.operation#InputFoo"), .{ .structure = &.{} });
    model.traits.put(test_alloc, SmithyId.of("test.operation#InputFoo"), &.{
        .{ .id = SmithyId.of("smithy.api#property"), .value = "test.resource#prop" },
    });
    model.shapes.put(test_alloc, SmithyId.of("test.operation#Input"), .{
        .structure = &.{SmithyId.of("test.operation#InputFoo")},
    });
    model.shapes.put(test_alloc, SmithyId.of("test.operation#Output"), .{ .structure = &.{} });
    model.shapes.put(test_alloc, SmithyId.of("test.error#NotFound"), .{ .structure = &.{} });
    model.traits.put(test_alloc, SmithyId.of("test.error#NotFound"), &.{
        .{ .id = SmithyId.of("smithy.api#error"), .value = "client" },
    });
    model.shapes.put(test_alloc, SmithyId.of("test.serve#Operation"), .{
        .operation = SmithyOperation{
            .input = SmithyId.of("test.operation#Input"),
            .output = SmithyId.of("test.operation#Output"),
            .errors = &.{SmithyId.of("test.error#NotFound")},
        },
    });

    model.shapes.put(test_alloc, SmithyId.of("test.resource#prop"), .{
        .string = "foo",
    });
    model.shapes.put(test_alloc, SmithyId.of("test.serve#Resource"), .{
        .resource = SmithyResource{
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

    model.shapes.put(test_alloc, SmithyId.of("test.serve#Error"), .{ .structure = &.{} });
    model.traits.put(test_alloc, SmithyId.of("test.serve#Service"), &.{
        .{
            .id = SmithyId.of("smithy.api#documentation"),
            .value = "Foo bar baz.",
        },
    });
    model.shapes.put(test_alloc, SmithyId.of("test.serve#Service"), .{
        .resource = SmithyService{
            .version = "2017-02-11",
            .operations = &.{SmithyId.of("test.serve#Operation")},
            .resources = &.{SmithyId.of("test.serve#Resource")},
            .errors = &.{SmithyId.of("test.serve#Error")},
        },
    });

    return model;
}

pub fn deinitTestModel(model: *SmithyModel) void {
    model.meta.deinit(test_alloc);
    model.shapes.deinit(test_alloc);
    model.traits.deinit(test_alloc);
    model.mixins.deinit(test_alloc);
    test_alloc.destroy(model);
}
