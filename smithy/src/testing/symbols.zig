const std = @import("std");
const test_alloc = std.testing.allocator;
const Model = @import("../tasks/smithy_parse.zig").Model;
const symbols = @import("../systems/symbols.zig");
const SmithyId = symbols.SmithyId;
const SmithyType = symbols.SmithyType;
const SmithyMeta = symbols.SmithyMeta;
const SmithyService = symbols.SmithyService;
const SmithyResource = symbols.SmithyResource;
const SmithyOperation = symbols.SmithyOperation;
const TaggedValue = symbols.SmithyTaggedValue;
const SymbolsProvider = symbols.SymbolsProvider;
const rls = @import("../systems/rules.zig");
const trt_behave = @import("../traits/behavior.zig");
const trt_constr = @import("../traits/constraint.zig");
const trt_http = @import("../traits/http.zig");
const trt_refine = @import("../traits/refine.zig");
const trt_rules = @import("../traits/rules.zig");

pub fn setup(arena: std.mem.Allocator, cases: []const Case) !SymbolsProvider {
    var model = Model.init(test_alloc);
    errdefer model.deinit();

    for (cases) |s| switch (s) {
        .unit => try setupUnit(&model),
        .root_child => try setupRootAndChild(&model),
        .list => try setupList(&model),
        .map => try setupMap(&model),
        .enums_str => try setupEnums(&model),
        .enum_int => try setupIntEnum(&model),
        .union_str => try setupUnion(&model),
        .structure => try setupStruct(&model),
        .err => try setupError(&model),
        .service => try setupServiceAndDeps(&model),
        .rules => try setupRulesEngine(&model),
    };

    return model.consume(arena);
}

pub const Case = enum {
    unit,
    root_child,
    list,
    map,
    enums_str,
    enum_int,
    union_str,
    structure,
    err,
    service,
    rules,
};

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
        .map = .{ .integer, .integer },
    });
    try model.traits.put(test_alloc, SmithyId.of("test#Map"), &.{
        .{ .id = trt_refine.sparse_id, .value = null },
    });
}

const ENUM_TRT: trt_constr.Enum.Sentinel = &.{ .{ .value = "FOO_BAR" }, .{ .value = "baz$qux", .name = "BAZ_QUX" } };
const ENUM_STR = &.{ SmithyId.of("test#Enum$FOO_BAR"), SmithyId.of("test#Enum$BAZ_QUX") };
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
    try model.shapes.put(test_alloc, SmithyId.of("test#EnumTrt"), .string);
    try model.traits.put(test_alloc, SmithyId.of("test#EnumTrt"), &.{.{
        .id = trt_constr.Enum.id,
        .value = ENUM_TRT,
    }});
}

fn setupIntEnum(model: *Model) !void {
    const Static = struct {
        const shape = &.{ SmithyId.of("test#IntEnum$FOO_BAR"), SmithyId.of("test#IntEnum$BAZ_QUX") };
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

const UNION = &.{
    SmithyId.of("test#Union$FOO"),
    SmithyId.of("test#Union$BAR"),
    SmithyId.of("test#Union$BAZ"),
};
fn setupUnion(model: *Model) !void {
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

fn setupStruct(model: *Model) !void {
    const Static = struct {
        const structure = &.{ SmithyId.of("test#Struct$fooBar"), SmithyId.of("test#Struct$bazQux") };
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
    try model.shapes.put(test_alloc, SmithyId.of("test#Struct$fooBar"), .integer);
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

const ERROR_CODE: u10 = 429;
const ERROR_SOURCE = trt_refine.Error.Source.client;
fn setupError(model: *Model) !void {
    try model.names.put(test_alloc, SmithyId.of("test#Error"), "Error");
    try model.shapes.put(test_alloc, SmithyId.of("test#Error"), .{
        .structure = &.{},
    });
    try model.traits.put(test_alloc, SmithyId.of("test#Error"), &.{
        .{ .id = trt_refine.Error.id, .value = &ERROR_SOURCE },
        .{ .id = trt_behave.retryable_id, .value = null },
        .{ .id = trt_http.HttpError.id, .value = &ERROR_CODE },
    });
}

fn setupServiceAndDeps(model: *Model) !void {
    const Static = struct {
        const service = SmithyService{
            .version = "2017-02-11",
            .operations = &.{SmithyId.of("test.serve#Operation")},
            .resources = &.{SmithyId.of("test.serve#Resource")},
            .errors = &.{SmithyId.of("test.error#ServiceError")},
        };
        const service_doc: []const u8 = "<p>Some <i>service</i>...</p>";
        const service_traits = &.{.{
            .id = SmithyId.of("smithy.api#documentation"),
            .value = @as(*const anyopaque, @ptrCast(&service_doc)),
        }};
        const resource = SmithyResource{
            .identifiers = &.{
                .{ .name = "forecastId", .shape = SmithyId.of("smithy.api#String") },
            },
            .operations = &.{SmithyId.of("test.serve#Operation")},
            .resources = &.{},
        };
        const operation = SmithyOperation{
            .input = SmithyId.of("test.serve#OperationInput"),
            .output = SmithyId.of("test.serve#OperationOutput"),
            .errors = &.{SmithyId.of("test.error#NotFound")},
        };
    };

    model.service_id = SmithyId.of("test.serve#Service");
    try model.names.put(test_alloc, SmithyId.of("test.serve#Service"), "Service");
    try model.shapes.put(test_alloc, SmithyId.of("test.serve#Service"), .{
        .service = &Static.service,
    });
    try model.traits.put(test_alloc, SmithyId.of("test.serve#Service"), Static.service_traits);

    try model.names.put(test_alloc, SmithyId.of("test.error#ServiceError"), "ServiceError");
    try model.shapes.put(test_alloc, SmithyId.of("test.error#ServiceError"), .{
        .structure = &.{},
    });

    try model.names.put(test_alloc, SmithyId.of("test.serve#Resource"), "Resource");
    try model.shapes.put(test_alloc, SmithyId.of("test.serve#Resource"), .{
        .resource = &Static.resource,
    });

    try model.names.put(test_alloc, SmithyId.of("test.serve#Operation"), "Operation");
    try model.shapes.put(test_alloc, SmithyId.of("test.serve#Operation"), .{
        .operation = &Static.operation,
    });

    try model.names.put(test_alloc, SmithyId.of("test.serve#OperationInput"), "OperationInput");
    try model.shapes.put(test_alloc, SmithyId.of("test.serve#OperationInput"), .{
        .structure = &.{},
    });

    try model.names.put(test_alloc, SmithyId.of("test.serve#OperationOutput"), "OperationOutput");
    try model.shapes.put(test_alloc, SmithyId.of("test.serve#OperationOutput"), .{
        .structure = &.{},
    });

    try model.names.put(test_alloc, SmithyId.of("test.error#NotFound"), "NotFound");
    try model.shapes.put(test_alloc, SmithyId.of("test.error#NotFound"), .{
        .structure = &.{},
    });
    try model.traits.put(test_alloc, SmithyId.of("test.error#NotFound"), &.{
        .{ .id = SmithyId.of("smithy.api#error"), .value = "client" },
    });
}

fn setupRulesEngine(model: *Model) !void {
    const rule_set: rls.RuleSet = .{
        .parameters = &[_]rls.StringKV(rls.Parameter){.{
            .key = "foo",
            .value = rls.Parameter{ .type = .{ .boolean = null } },
        }},
        .rules = &[_]rls.Rule{
            .{ .err = .{ .message = .{ .string = "baz" } } },
        },
    };

    try model.traits.put(test_alloc, SmithyId.of("test#Root"), &.{
        .{ .id = trt_rules.EndpointRuleSet.id, .value = &rule_set },
    });
}
