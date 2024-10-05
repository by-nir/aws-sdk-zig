const std = @import("std");
const test_alloc = std.testing.allocator;
const mdl = @import("../model.zig");
const SmithyId = mdl.SmithyId;
const SmithyType = mdl.SmithyType;
const SmithyMeta = mdl.SmithyMeta;
const SmithyService = mdl.SmithyService;
const SmithyResource = mdl.SmithyResource;
const SmithyOperation = mdl.SmithyOperation;
const TaggedValue = mdl.SmithyTaggedValue;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const rls = @import("../systems/rules.zig");
const Model = @import("../parse/Model.zig");
const trt_http = @import("../traits/http.zig");
const trt_rules = @import("../traits/rules.zig");
const trt_refine = @import("../traits/refine.zig");
const trt_behave = @import("../traits/behavior.zig");
const trt_constr = @import("../traits/constraint.zig");

pub const Part = enum { unit, root_child, list, map, enums_str, enum_int, union_str, structure, service };

pub fn setup(arena: std.mem.Allocator, part: Part) !SymbolsProvider {
    var model = Model.init(test_alloc);
    errdefer model.deinit();

    switch (part) {
        .unit => try setupUnit(&model),
        .root_child => try setupRootAndChild(&model),
        .list => try setupList(&model),
        .map => try setupMap(&model),
        .enums_str => try setupEnums(&model),
        .enum_int => try setupIntEnum(&model),
        .union_str => try setupUnion(&model),
        .structure => try setupStruct(&model),
        .service => {
            try setupService(&model);
            model.service_id = SmithyId.of("test.serve#Service");
        },
    }

    return SymbolsProvider.consumeModel(arena, &model);
}

fn setupUnit(model: *Model) !void {
    try model.shapes.put(test_alloc, SmithyId.of("test#Unit"), .unit);
}

fn setupRootAndChild(model: *Model) !void {
    try model.names.put(test_alloc, SmithyId.of("test#Root"), "Root");
    try model.shapes.put(test_alloc, SmithyId.of("test#Root"), .{
        .list = SmithyId.of("test#Root$child"),
    });

    try model.shapes.put(test_alloc, SmithyId.of("test#Root$child"), .{
        .target = SmithyId.of("test#Child"),
    });

    try model.names.put(test_alloc, SmithyId.of("test#Child"), "Child");
    try model.shapes.put(test_alloc, SmithyId.of("test#Child"), .{
        .list = .integer,
    });
}

fn setupList(model: *Model) !void {
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

fn setupMap(model: *Model) !void {
    try model.names.put(test_alloc, SmithyId.of("test#Map"), "Map");
    try model.shapes.put(test_alloc, SmithyId.of("test#Map"), .{
        .map = .{ .string, .integer },
    });
    try model.traits.put(test_alloc, SmithyId.of("test#Map"), &.{
        .{ .id = trt_refine.sparse_id, .value = null },
    });
}

const ENUM_TRT: []const trt_constr.Enum.Member = &.{
    .{ .value = "FOO_BAR" },
    .{ .value = "baz$qux", .name = "BAZ_QUX" },
    .{ .value = "" },
};
const en1 = SmithyId.of("test#Enum$BAZ_QUX");
const ENUM_STR = &.{ SmithyId.of("test#Enum$FOO_BAR"), en1 };
fn setupEnums(model: *Model) !void {
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
    try model.shapes.put(test_alloc, SmithyId.of("test#EnumTrt"), .trt_enum);
    try model.traits.put(test_alloc, SmithyId.of("test#EnumTrt"), &.{.{
        .id = trt_constr.Enum.id,
        .value = ENUM_TRT.ptr,
    }});
}

fn setupIntEnum(model: *Model) !void {
    const Static = struct {
        const ie1 = SmithyId.of("test#IntEnum$BAZ_QUX");
        const shape = &.{ SmithyId.of("test#IntEnum$FOO_BAR"), ie1 };
        const doc: []const u8 = "<p>An <b>integer-based</b> enumeration.</p>";
        const traits = &.{.{
            .id = SmithyId.of("smithy.api#documentation"),
            .value = @as(*const anyopaque, @ptrCast(&doc)),
        }};
    };
    try model.names.put(test_alloc, SmithyId.of("test#IntEnum"), "IntEnum");
    try model.shapes.put(test_alloc, SmithyId.of("test#IntEnum"), .{
        .int_enum = Static.shape,
    });
    try model.traits.put(test_alloc, SmithyId.of("test#IntEnum"), Static.traits);

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

const un0 = SmithyId.of("test#Union$FOO");
const un1 = SmithyId.of("test#Union$BAR");
const un2 = SmithyId.of("test#Union$BAZ");
const UNION = &.{ un0, un1, un2 };
fn setupUnion(model: *Model) !void {
    try model.names.put(test_alloc, SmithyId.of("test#Union"), "Union");
    try model.shapes.put(test_alloc, SmithyId.of("test#Union"), .{ .tagged_union = UNION });
    try model.names.put(test_alloc, SmithyId.of("test#Union$FOO"), "FOO");
    try model.shapes.put(test_alloc, SmithyId.of("test#Union$FOO"), .unit);
    try model.names.put(test_alloc, SmithyId.of("test#Union$BAR"), "BAR");
    try model.shapes.put(test_alloc, SmithyId.of("test#Union$BAR"), .integer);
    try model.names.put(test_alloc, SmithyId.of("test#Union$BAZ"), "BAZ");
    try model.shapes.put(test_alloc, SmithyId.of("test#Union$BAZ"), .string);
}

fn setupStruct(model: *Model) !void {
    const Static = struct {
        const ff = SmithyId.of("test#Struct$bazQux");
        const structure = &.{ SmithyId.of("test#Struct$fooBar"), ff };
        const mixins = &.{SmithyId.of("test#Mixin")};
        const mixed = &.{SmithyId.of("test#Mixin$mixed")};
        const member_doc: []const u8 = "<p>A <b>struct</b> member.</p>";
        const member_traits = .{
            .{ .id = trt_refine.required_id, .value = null },
            .{
                .id = SmithyId.of("smithy.api#documentation"),
                .value = @as(*const anyopaque, @ptrCast(&member_doc)),
            },
        };
    };

    try setupIntEnum(model);

    try model.names.put(test_alloc, SmithyId.of("test#Struct"), "Struct");
    try model.shapes.put(test_alloc, SmithyId.of("test#Struct"), .{
        .structure = Static.structure,
    });
    try model.mixins.put(test_alloc, SmithyId.of("test#Struct"), Static.mixins);

    try model.names.put(test_alloc, SmithyId.of("test#Struct$fooBar"), "fooBar");
    try model.shapes.put(test_alloc, SmithyId.of("test#Struct$fooBar"), .string);
    try model.traits.put(test_alloc, SmithyId.of("test#Struct$fooBar"), &Static.member_traits);

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
        .structure = Static.mixed,
    });
    try model.traits.put(test_alloc, SmithyId.of("test#Mixin"), &.{
        .{ .id = trt_refine.mixin_id, .value = null },
    });
    try model.names.put(test_alloc, SmithyId.of("test#Mixin$mixed"), "mixed");
    try model.shapes.put(test_alloc, SmithyId.of("test#Mixin$mixed"), .boolean);
}

fn setupService(model: *Model) !void {
    const Static = struct {
        const sd0 = SmithyId.of("test.serve#MyOperation");
        const sd1 = SmithyId.of("test.serve#Resource");
        const sd2 = SmithyId.of("test#ServiceError");
        const service = SmithyService{
            .version = "2017-02-11",
            .operations = &.{sd0},
            .resources = &.{sd1},
            .errors = &.{sd2},
        };
        const service_doc: []const u8 = "<p>Some <i>service</i>...</p>";
        const service_traits = &.{
            .{
                .id = SmithyId.of("smithy.api#documentation"),
                .value = @as(*const anyopaque, @ptrCast(&service_doc)),
            },
            .{ .id = trt_rules.EndpointRuleSet.id, .value = &rule_set },
            .{ .id = trt_rules.EndpointTests.id, .value = rule_test_cases.ptr },
        };
        const rd0 = SmithyId.of("test.serve#MyOperation");
        const resource = SmithyResource{
            .identifiers = &.{
                .{ .name = "forecastId", .shape = SmithyId.of("smithy.api#String") },
            },
            .operations = &.{rd0},
            .resources = &.{},
        };
        const od0 = SmithyId.of("test.serve#MyOperationOutput");
        const od1 = SmithyId.of("test.error#NotFound");
        const operation = SmithyOperation{
            .input = SmithyId.of("test.serve#MyOperationInput"),
            .output = od0,
            .errors = &.{od1},
        };
        const n1 = SmithyId.of("test.serve#MyOperationInput$Bar");
        const operation_input: []const SmithyId = &.{ SmithyId.of("test.serve#MyOperationInput$Foo"), n1 };
        const operation_Output: []const SmithyId = &.{SmithyId.of("test.serve#MyOperationOutput$Qux")};
        const rule_set: rls.RuleSet = .{
            .parameters = &[_]rls.StringKV(rls.Parameter){.{
                .key = "foo",
                .value = rls.Parameter{ .type = .{ .boolean = null } },
            }},
            .rules = &[_]rls.Rule{
                .{ .err = .{ .message = .{ .string = "baz" } } },
            },
        };
        const rule_test_cases = &[_]rls.TestCase{
            .{
                .documentation = "Foo",
                .expect = .{ .err = "Boom!" },
                .params = &.{},
            },
            .{},
        };
        const error_source = trt_refine.ErrorSource.client;
        const error_code: std.http.Status = .too_many_requests;
    };

    model.service_id = SmithyId.of("test.serve#Service");
    try model.names.put(test_alloc, SmithyId.of("test.serve#Service"), "Service");
    try model.shapes.put(test_alloc, SmithyId.of("test.serve#Service"), .{
        .service = &Static.service,
    });
    try model.traits.put(test_alloc, SmithyId.of("test.serve#Service"), Static.service_traits);

    try model.names.put(test_alloc, SmithyId.of("test.serve#Resource"), "Resource");
    try model.shapes.put(test_alloc, SmithyId.of("test.serve#Resource"), .{
        .resource = &Static.resource,
    });

    try model.names.put(test_alloc, SmithyId.of("test.serve#MyOperation"), "MyOperation");
    try model.shapes.put(test_alloc, SmithyId.of("test.serve#MyOperation"), .{
        .operation = &Static.operation,
    });

    try model.names.put(test_alloc, SmithyId.of("test.serve#MyOperationInput"), "MyOperationInput");
    try model.shapes.put(test_alloc, SmithyId.of("test.serve#MyOperationInput"), .{
        .structure = Static.operation_input,
    });

    try model.names.put(test_alloc, SmithyId.of("test.serve#MyOperationInput$Foo"), "Foo");
    try model.shapes.put(test_alloc, SmithyId.of("test.serve#MyOperationInput$Foo"), .{ .structure = &.{} });
    try model.traits.put(test_alloc, SmithyId.of("test.serve#MyOperationInput$Foo"), &.{
        .{ .id = trt_refine.required_id, .value = null },
    });

    try model.names.put(test_alloc, SmithyId.of("test.serve#MyOperationInput$Bar"), "Bar");
    try model.shapes.put(test_alloc, SmithyId.of("test.serve#MyOperationInput$Bar"), .string);
    try model.traits.put(test_alloc, SmithyId.of("test.serve#MyOperationInput$Bar"), &.{
        .{ .id = trt_constr.Length.id, .value = &trt_constr.Length.Val{ .max = 128 } },
    });

    try model.names.put(test_alloc, SmithyId.of("test.serve#MyOperationOutput"), "MyOperationOutput");
    try model.shapes.put(test_alloc, SmithyId.of("test.serve#MyOperationOutput"), .{
        .structure = Static.operation_Output,
    });

    try model.names.put(test_alloc, SmithyId.of("test.serve#MyOperationOutput$Qux"), "Qux");
    try model.shapes.put(test_alloc, SmithyId.of("test.serve#MyOperationOutput$Qux"), .string);

    try model.names.put(test_alloc, SmithyId.of("test.error#NotFound"), "NotFound");
    try model.shapes.put(test_alloc, SmithyId.of("test.error#NotFound"), .{
        .structure = &.{},
    });
    try model.traits.put(test_alloc, SmithyId.of("test.error#NotFound"), &.{
        .{ .id = trt_refine.Error.id, .value = "server" },
    });

    try model.names.put(test_alloc, SmithyId.of("test#ServiceError"), "ServiceError");
    try model.shapes.put(test_alloc, SmithyId.of("test#ServiceError"), .{
        .structure = &.{},
    });
    try model.traits.put(test_alloc, SmithyId.of("test#ServiceError"), &.{
        .{ .id = trt_refine.Error.id, .value = &Static.error_source },
        .{ .id = trt_behave.retryable_id, .value = null },
        .{ .id = trt_http.HttpError.id, .value = &Static.error_code },
    });
}
