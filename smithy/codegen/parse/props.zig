const std = @import("std");
const testing = std.testing;

/// All known Smithy properties.
// NOTICE: If adding more properties, make sure their first 8 characters are unique.
pub const SmithyProperty = enum(u64) {
    collection_ops = parse("collectionOperations"),
    create = parse("create"),
    delete = parse("delete"),
    errors = parse("errors"),
    identifiers = parse("identifiers"),
    input = parse("input"),
    key = parse("key"),
    list = parse("list"),
    member = parse("member"),
    members = parse("members"),
    metadata = parse("metadata"),
    mixins = parse("mixins"),
    operations = parse("operations"),
    output = parse("output"),
    properties = parse("properties"),
    put = parse("put"),
    read = parse("read"),
    rename = parse("rename"),
    resources = parse("resources"),
    shapes = parse("shapes"),
    smithy = parse("smithy"),
    target = parse("target"),
    traits = parse("traits"),
    type = parse("type"),
    update = parse("update"),
    value = parse("value"),
    version = parse("version"),
    _,

    fn parse(str: []const u8) u64 {
        var code: u64 = 0;
        const len = @min(8, str.len);
        @memcpy(std.mem.asBytes(&code)[0..len], str[0..len]);
        return code;
    }

    pub fn of(str: []const u8) SmithyProperty {
        return @enumFromInt(parse(str));
    }
};

test SmithyProperty {
    try testing.expectEqual(.collection_ops, SmithyProperty.of("collectionOperations"));
    try testing.expectEqual(.create, SmithyProperty.of("create"));
    try testing.expectEqual(.delete, SmithyProperty.of("delete"));
    try testing.expectEqual(.errors, SmithyProperty.of("errors"));
    try testing.expectEqual(.identifiers, SmithyProperty.of("identifiers"));
    try testing.expectEqual(.input, SmithyProperty.of("input"));
    try testing.expectEqual(.key, SmithyProperty.of("key"));
    try testing.expectEqual(.list, SmithyProperty.of("list"));
    try testing.expectEqual(.member, SmithyProperty.of("member"));
    try testing.expectEqual(.members, SmithyProperty.of("members"));
    try testing.expectEqual(.metadata, SmithyProperty.of("metadata"));
    try testing.expectEqual(.mixins, SmithyProperty.of("mixins"));
    try testing.expectEqual(.operations, SmithyProperty.of("operations"));
    try testing.expectEqual(.output, SmithyProperty.of("output"));
    try testing.expectEqual(.properties, SmithyProperty.of("properties"));
    try testing.expectEqual(.put, SmithyProperty.of("put"));
    try testing.expectEqual(.read, SmithyProperty.of("read"));
    try testing.expectEqual(.rename, SmithyProperty.of("rename"));
    try testing.expectEqual(.resources, SmithyProperty.of("resources"));
    try testing.expectEqual(.shapes, SmithyProperty.of("shapes"));
    try testing.expectEqual(.smithy, SmithyProperty.of("smithy"));
    try testing.expectEqual(.target, SmithyProperty.of("target"));
    try testing.expectEqual(.traits, SmithyProperty.of("traits"));
    try testing.expectEqual(.type, SmithyProperty.of("type"));
    try testing.expectEqual(.update, SmithyProperty.of("update"));
    try testing.expectEqual(.value, SmithyProperty.of("value"));
    try testing.expectEqual(.version, SmithyProperty.of("version"));
    try testing.expectEqual(
        SmithyProperty.parse("U4K4OW4"),
        @intFromEnum(SmithyProperty.of("U4K4OW4")),
    );
}
