// https://github.com/awslabs/aws-c-sdkutils/blob/main/source/partitions.c

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const smithy = @import("smithy");
const pipez = smithy.pipez;
const Delegate = pipez.Delegate;
const files_tasks = smithy.files_tasks;
const codegen_tasks = smithy.codegen_tasks;
const JsonReader = smithy.JsonReader;
const zig = smithy.codegen_zig;
const PascalCase = smithy.name_util.PascalCase;
const RegionDef = @import("config_region.zig").RegionDef;

const Matcher = struct {
    func: []const u8,
    partition: zig.Expr,
};

pub const Partitions = files_tasks.WriteFile.Task("AWS Config Partitions", partitionsTask, .{});
fn partitionsTask(
    self: *const Delegate,
    writer: std.io.AnyWriter,
    src_dir: std.fs.Dir,
    region_defs: *std.ArrayList(RegionDef),
) anyerror!void {
    const src_file = try src_dir.openFile("sdk-partitions.json", .{});
    defer src_file.close();

    var reader = try JsonReader.initPersist(self.alloc(), src_file);
    defer reader.deinit();

    return self.evaluate(PartitionsCodegen, .{ writer, &reader, region_defs });
}

const PartitionsCodegen = codegen_tasks.ZigScript.Task("Partitions Codegen", partitionsCodegenTask, .{});
fn partitionsCodegenTask(
    self: *const Delegate,
    bld: *zig.ContainerBuild,
    reader: *JsonReader,
    region_defs: *std.ArrayList(RegionDef),
) anyerror!void {
    try bld.constant("std").assign(bld.x.import("std"));
    try bld.constant("Partition").assign(bld.x.import("aws-runtime").dot().raw("Partition"));

    var matchers = std.ArrayList(Matcher).init(self.alloc());
    var region_parts = std.ArrayList(zig.ExprBuild).init(self.alloc());

    try reader.nextObjectBegin();
    while (try reader.peek() == .string) {
        const key = try reader.nextString();
        if (mem.eql(u8, "version", key)) {
            try reader.nextStringEql("1.1");
        } else if (mem.eql(u8, "partitions", key)) {
            try reader.nextArrayBegin();
            while (try reader.next() != .array_end) {
                try processPartition(self.alloc(), bld, reader, region_defs, &region_parts, &matchers);
            }
        } else {
            return error.UnexpectedKey;
        }
    }
    try reader.nextObjectEnd();

    try bld.constant("partitions").assign(bld.x.call(
        "std.StaticStringMap(*const Partition).initComptime",
        &.{bld.x.structLiteral(null, region_parts.items)},
    ));

    try bld.public().function("resolve")
        .arg("region", bld.x.typeOf([]const u8))
        .returns(bld.x.raw("?*const Partition"))
        .bodyWith(matchers.items, struct {
        fn f(prts: []const Matcher, b: *zig.BlockBuild) !void {
            try b.raw("if (partitions.get(region)) |p| return p");

            var default: ?zig.Expr = null;
            for (prts) |matcher| {
                if (mem.eql(u8, "matchAws", matcher.func)) default = matcher.partition;
                try b.@"if"(b.x.call(matcher.func, &.{b.x.id("region")}))
                    .body(b.x.returns().fromExpr(matcher.partition)).end();
            }

            if (default) |partition| {
                try b.returns().fromExpr(partition).end();
            } else {
                try b.returns().valueOf(null).end();
            }
        }
    }.f);

    try writeRegexUtils(bld);
}

fn processPartition(
    arena: Allocator,
    bld: *zig.ContainerBuild,
    reader: *JsonReader,
    region_defs: *std.ArrayList(RegionDef),
    region_parts: *std.ArrayList(zig.ExprBuild),
    matchers: *std.ArrayList(Matcher),
) !void {
    var id: []u8 = "";
    var matcher: []u8 = "";
    var regex: []const u8 = "";
    var outputs: Partition = .{};

    while (try reader.peek() == .string) {
        const key = try reader.nextString();
        if (mem.eql(u8, "id", key)) {
            const raw = try reader.nextString();

            id = try std.fmt.allocPrint(arena, "prtn_{s}", .{raw});
            mem.replaceScalar(u8, id[6..id.len], '-', '_');

            matcher = try std.fmt.allocPrint(arena, "match{s}", .{PascalCase{ .value = raw }});
            try matchers.append(
                .{ .func = matcher, .partition = try bld.x.addressOf().id(id).consume() },
            );
        } else if (mem.eql(u8, "outputs", key)) {
            outputs = try Partition.parse(arena, region_defs.allocator, reader);
            if (!outputs.isValid()) return error.InvalidOutputs;
        } else if (mem.eql(u8, "regionRegex", key)) {
            regex = try reader.nextString();
        } else if (mem.eql(u8, "regions", key)) {
            if (id.len == 0) return error.MissingId;
            if (outputs.is_empty) return error.MissingOutputs;
            const prtn_target = bld.x.addressOf().id(id);
            try reader.nextObjectBegin();
            while (try reader.peek() != .object_end) {
                const code = try reader.nextStringAlloc(arena);
                const override = try Partition.parse(arena, region_defs.allocator, reader);

                try region_defs.append(.{
                    .code = code,
                    .description = override.region_description,
                });

                const value = if (override.is_empty) prtn_target else outputs.mergeFrom(override).consume(bld);
                const region = bld.x.valueOf(code);
                const pair = bld.x.structLiteral(null, &.{ region, value });
                try region_parts.append(pair);
            }
            try reader.nextObjectEnd();
        } else {
            return error.UnexpectedKey;
        }
    }
    try reader.nextObjectEnd();
    if (regex.len == 0 or matcher.len == 0) return error.MissingKeys;

    try bld.constant(id).assign(outputs.consume(bld));

    try bld.function(matcher).arg("code", bld.x.typeOf([]const u8)).returns(bld.x.typeOf(bool))
        .bodyWith(regex, writeRegexMatcher);
}

test "PartitionsCodegen" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var tester = try pipez.PipelineTester.init(.{});
    defer tester.deinit();

    var reader = try JsonReader.initFixed(arena_alloc, TEST_SRC);
    defer reader.deinit();

    var region_defs = std.ArrayList(RegionDef).init(arena_alloc);
    defer region_defs.deinit();

    const output = try codegen_tasks.evaluateZigScript(
        arena_alloc,
        tester.pipeline,
        PartitionsCodegen,
        .{ &reader, &region_defs },
    );
    try codegen_tasks.expectEqualZigScript(TEST_OUT, output);

    try testing.expectEqualDeep(&[_]RegionDef{
        .{ .code = "il-central-1", .description = "Israel (Tel Aviv)" },
        .{ .code = "us-east-1", .description = "US East (N. Virginia)" },
        .{ .code = "aws-cn-global", .description = "AWS China global region" },
        .{ .code = "cn-northwest-1", .description = "China (Ningxia)" },
        .{ .code = "us-gov-west-1", .description = "AWS GovCloud (US-West)" },
    }, region_defs.items);
}

const Partition = struct {
    is_empty: bool = true,
    name: ?[]const u8 = null,
    dns_suffix: ?[]const u8 = null,
    dual_stack_dns_suffix: ?[]const u8 = null,
    supports_fips: ?bool = null,
    supports_dual_stack: ?bool = null,
    implicit_global_region: ?[]const u8 = null,
    region_description: ?[]const u8 = null,

    const fields = .{ "name", "dns_suffix", "dual_stack_dns_suffix", "supports_fips", "supports_dual_stack", "implicit_global_region" };

    pub fn isValid(self: Partition) bool {
        if (self.is_empty) return false;
        inline for (fields) |field| {
            if (@field(self, field) == null) return false;
        }
        return true;
    }

    pub fn mergeFrom(self: Partition, override: Partition) Partition {
        var merged = self;
        inline for (fields) |field| {
            if (@field(override, field)) |val| @field(merged, field) = val;
        }
        return merged;
    }

    pub fn parse(part_alloc: Allocator, region_alloc: Allocator, reader: *JsonReader) !Partition {
        var value: Partition = .{};
        try reader.nextObjectBegin();
        while (try reader.peek() == .string) {
            const key = try reader.nextString();
            if (mem.eql(u8, "name", key)) {
                value.is_empty = false;
                value.name = try reader.nextStringAlloc(part_alloc);
            } else if (mem.eql(u8, "dnsSuffix", key)) {
                value.is_empty = false;
                value.dns_suffix = try reader.nextStringAlloc(part_alloc);
            } else if (mem.eql(u8, "dualStackDnsSuffix", key)) {
                value.is_empty = false;
                value.dual_stack_dns_suffix = try reader.nextStringAlloc(part_alloc);
            } else if (mem.eql(u8, "supportsFIPS", key)) {
                value.is_empty = false;
                value.supports_fips = try reader.nextBoolean();
            } else if (mem.eql(u8, "supportsDualStack", key)) {
                value.is_empty = false;
                value.supports_dual_stack = try reader.nextBoolean();
            } else if (mem.eql(u8, "implicitGlobalRegion", key)) {
                value.is_empty = false;
                value.implicit_global_region = try reader.nextStringAlloc(part_alloc);
            } else if (mem.eql(u8, "description", key)) {
                value.region_description = try reader.nextStringAlloc(region_alloc);
            } else {
                return error.UnexpectedKey;
            }
        }
        try reader.nextObjectEnd();
        return value;
    }

    pub fn consume(self: Partition, bld: *zig.ContainerBuild) zig.ExprBuild {
        return bld.x.structLiteral(bld.x.id("Partition"), &.{
            bld.x.structAssign("name", bld.x.valueOf(self.name)),
            bld.x.structAssign("dns_suffix", bld.x.valueOf(self.dns_suffix)),
            bld.x.structAssign("dual_stack_dns_suffix", bld.x.valueOf(self.dual_stack_dns_suffix)),
            bld.x.structAssign("supports_fips", bld.x.valueOf(self.supports_fips)),
            bld.x.structAssign("supports_dual_stack", bld.x.valueOf(self.supports_dual_stack)),
            bld.x.structAssign("implicit_global_region", bld.x.valueOf(self.implicit_global_region)),
        });
    }
};

test "Partition parse" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc, TEST_OUTPUTS);
    defer reader.deinit();

    var output = try Partition.parse(arena_alloc, arena_alloc, &reader);
    try testing.expectEqualDeep(Partition{
        .is_empty = false,
        .name = "aws",
        .dns_suffix = "amazonaws.com",
        .dual_stack_dns_suffix = "api.aws",
        .supports_fips = true,
        .supports_dual_stack = true,
        .implicit_global_region = "us-east-1",
    }, output);

    try testing.expectEqual(true, output.isValid());
    output.dns_suffix = null;
    try testing.expectEqual(false, output.isValid());
}

test "Partition parse – empty" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc, "{\"description\":\"foo\"}");
    defer reader.deinit();

    const output = try Partition.parse(arena_alloc, arena_alloc, &reader);
    try testing.expectEqualDeep(Partition{
        .is_empty = true,
        .region_description = "foo",
    }, output);
    try testing.expectEqual(false, output.isValid());
}

fn writeRegexMatcher(regex: []const u8, bld: *zig.BlockBuild) !void {
    if (regex.len == 0 or regex[0] != '^' or regex[regex.len - 1] != '$') {
        return error.InvalidRegex;
    }

    try bld.variable("rest").assign(bld.x.raw("code[1 .. code.len - 1]"));

    var it = std.mem.tokenizeSequence(u8, regex[1 .. regex.len - 1], "\\-");
    while (it.next()) |part| {
        if (part[0] == '(' and part[part.len - 1] == ')') {
            var list = std.ArrayList(zig.ExprBuild).init(bld.allocator);
            errdefer list.deinit();

            var items = std.mem.tokenizeSequence(u8, part[1 .. part.len - 1], "|");
            while (items.next()) |item| {
                try list.append(bld.x.structLiteral(null, &.{bld.x.valueOf(item)}));
            }

            try bld.@"if"(
                bld.x.op(.not).call("matchAny", &.{
                    bld.x.addressOf().id("rest"),
                    bld.x.structLiteral(null, try list.toOwnedSlice()),
                }),
            ).body(bld.x.returns().valueOf(false)).end();
        } else if (mem.eql(u8, "\\w+", part)) {
            try bld.raw("if (!matchWord(&rest)) return false");
        } else if (mem.eql(u8, "\\d+", part)) {
            try bld.raw("if (!matchNumber(&rest)) return false");
        } else {
            try bld.@"if"(
                bld.x.op(.not).call("matchString", &.{
                    bld.x.addressOf().id("rest"),
                    bld.x.valueOf(part),
                }),
            ).body(bld.x.returns().valueOf(false)).end();
        }

        if (it.rest().len > 0) try bld.raw("if (!matchDash(&rest)) return false");
    }

    try bld.returns().valueOf(true).end();
}

fn writeRegexUtils(bld: *zig.ContainerBuild) !void {
    try bld.function("matchAny")
        .arg("rest", bld.x.typeOf(*[]const u8))
        .arg("values", null)
        .returns(bld.x.typeOf(bool))
        .body(struct {
        fn f(b: *zig.BlockBuild) !void {
            try b.raw("const set = std.StaticStringMap(void).initComptime(values)");
            try b.raw("const i = std.mem.indexOfScalar(u8, rest.*, '-') orelse rest.len");
            try b.raw("if (!set.has(rest[0..i])) return false");
            try b.raw("rest.* = rest[i..rest.len]");
            try b.raw("return true");
        }
    }.f);

    try bld.function("matchWord")
        .arg("rest", bld.x.typeOf(*[]const u8))
        .returns(bld.x.typeOf(bool))
        .body(struct {
        fn f(b: *zig.BlockBuild) !void {
            try b.raw("const i = std.mem.indexOfScalar(u8, rest.*, '-') orelse rest.len");
            try b.raw("for (rest[0..i]) |c| if (!std.ascii.isAlphabetic(c)) return false");
            try b.raw("rest.* = rest[i..rest.len]");
            try b.raw("return true");
        }
    }.f);

    try bld.function("matchNumber")
        .arg("rest", bld.x.typeOf(*[]const u8))
        .returns(bld.x.typeOf(bool))
        .body(struct {
        fn f(b: *zig.BlockBuild) !void {
            try b.raw("const i = std.mem.indexOfScalar(u8, rest.*, '-') orelse rest.len");
            try b.raw("for (rest[0..i]) |c| if (!std.ascii.isDigit(c)) return false");
            try b.raw("rest.* = rest[i..rest.len]");
            try b.raw("return true");
        }
    }.f);

    try bld.function("matchString")
        .arg("rest", bld.x.typeOf(*[]const u8))
        .arg("str", bld.x.typeOf([]const u8))
        .returns(bld.x.typeOf(bool))
        .body(struct {
        fn f(b: *zig.BlockBuild) !void {
            try b.raw("if (!std.mem.startsWith(u8, rest.*, str)) return false");
            try b.raw("rest.* = rest[str.len..rest.len]");
            try b.raw("return true");
        }
    }.f);

    try bld.function("matchDash")
        .arg("rest", bld.x.typeOf(*[]const u8))
        .returns(bld.x.typeOf(bool))
        .body(struct {
        fn f(b: *zig.BlockBuild) !void {
            try b.raw("if (rest.len == 0 or rest[0] != '-') return false");
            try b.raw("rest.* = rest[1..rest.len]");
            try b.raw("return true");
        }
    }.f);
}

const TEST_OUT: []const u8 =
    \\const std = @import("std");
    \\
    \\const Partition = @import("aws-runtime").Partition;
    \\
    \\const prtn_aws = Partition{
    \\    .name = "aws",
    \\    .dns_suffix = "amazonaws.com",
    \\    .dual_stack_dns_suffix = "api.aws",
    \\    .supports_fips = true,
    \\    .supports_dual_stack = true,
    \\    .implicit_global_region = "us-east-1",
    \\};
    \\
    \\fn matchAws(code: []const u8) bool {
    \\    var rest = code[1 .. code.len - 1];
    \\
    \\    if (!matchAny(&rest, .{ .{"us"}, .{"il"} })) return false;
    \\
    \\    if (!matchDash(&rest)) return false;
    \\
    \\    if (!matchWord(&rest)) return false;
    \\
    \\    if (!matchDash(&rest)) return false;
    \\
    \\    if (!matchNumber(&rest)) return false;
    \\
    \\    return true;
    \\}
    \\
    \\const prtn_aws_cn = Partition{
    \\    .name = "aws-cn",
    \\    .dns_suffix = "amazonaws.com.cn",
    \\    .dual_stack_dns_suffix = "api.amazonwebservices.com.cn",
    \\    .supports_fips = true,
    \\    .supports_dual_stack = true,
    \\    .implicit_global_region = "cn-northwest-1",
    \\};
    \\
    \\fn matchAwsCn(code: []const u8) bool {
    \\    var rest = code[1 .. code.len - 1];
    \\
    \\    if (!matchString(&rest, "cn")) return false;
    \\
    \\    if (!matchDash(&rest)) return false;
    \\
    \\    if (!matchWord(&rest)) return false;
    \\
    \\    if (!matchDash(&rest)) return false;
    \\
    \\    if (!matchNumber(&rest)) return false;
    \\
    \\    return true;
    \\}
    \\
    \\const prtn_aws_us_gov = Partition{
    \\    .name = "aws-us-gov",
    \\    .dns_suffix = "amazonaws.com",
    \\    .dual_stack_dns_suffix = "api.aws",
    \\    .supports_fips = true,
    \\    .supports_dual_stack = true,
    \\    .implicit_global_region = "us-gov-west-1",
    \\};
    \\
    \\fn matchAwsUsGov(code: []const u8) bool {
    \\    var rest = code[1 .. code.len - 1];
    \\
    \\    if (!matchString(&rest, "us")) return false;
    \\
    \\    if (!matchDash(&rest)) return false;
    \\
    \\    if (!matchString(&rest, "gov")) return false;
    \\
    \\    if (!matchDash(&rest)) return false;
    \\
    \\    if (!matchWord(&rest)) return false;
    \\
    \\    if (!matchDash(&rest)) return false;
    \\
    \\    if (!matchNumber(&rest)) return false;
    \\
    \\    return true;
    \\}
    \\
    \\const partitions = std.StaticStringMap(*const Partition).initComptime(.{
    \\    .{ "il-central-1", &prtn_aws },
    \\    .{ "us-east-1", &prtn_aws },
    \\    .{ "aws-cn-global", &prtn_aws_cn },
    \\    .{ "cn-northwest-1", &prtn_aws_cn },
    \\    .{ "us-gov-west-1", Partition{
    \\        .name = "aws-us-gov",
    \\        .dns_suffix = "amazonaws.com",
    \\        .dual_stack_dns_suffix = "api.aws",
    \\        .supports_fips = false,
    \\        .supports_dual_stack = true,
    \\        .implicit_global_region = "us-gov-west-1",
    \\    } },
    \\});
    \\
    \\pub fn resolve(region: []const u8) ?*const Partition {
    \\    if (partitions.get(region)) |p| return p;
    \\
    \\    if (matchAws(region)) return &prtn_aws;
    \\
    \\    if (matchAwsCn(region)) return &prtn_aws_cn;
    \\
    \\    if (matchAwsUsGov(region)) return &prtn_aws_us_gov;
    \\
    \\    return &prtn_aws;
    \\}
    \\
    \\fn matchAny(rest: *[]const u8, values: anytype) bool {
    \\    const set = std.StaticStringMap(void).initComptime(values);
    \\
    \\    const i = std.mem.indexOfScalar(u8, rest.*, '-') orelse rest.len;
    \\
    \\    if (!set.has(rest[0..i])) return false;
    \\
    \\    rest.* = rest[i..rest.len];
    \\
    \\    return true;
    \\}
    \\
    \\fn matchWord(rest: *[]const u8) bool {
    \\    const i = std.mem.indexOfScalar(u8, rest.*, '-') orelse rest.len;
    \\
    \\    for (rest[0..i]) |c| if (!std.ascii.isAlphabetic(c)) return false;
    \\
    \\    rest.* = rest[i..rest.len];
    \\
    \\    return true;
    \\}
    \\
    \\fn matchNumber(rest: *[]const u8) bool {
    \\    const i = std.mem.indexOfScalar(u8, rest.*, '-') orelse rest.len;
    \\
    \\    for (rest[0..i]) |c| if (!std.ascii.isDigit(c)) return false;
    \\
    \\    rest.* = rest[i..rest.len];
    \\
    \\    return true;
    \\}
    \\
    \\fn matchString(rest: *[]const u8, str: []const u8) bool {
    \\    if (!std.mem.startsWith(u8, rest.*, str)) return false;
    \\
    \\    rest.* = rest[str.len..rest.len];
    \\
    \\    return true;
    \\}
    \\
    \\fn matchDash(rest: *[]const u8) bool {
    \\    if (rest.len == 0 or rest[0] != '-') return false;
    \\
    \\    rest.* = rest[1..rest.len];
    \\
    \\    return true;
    \\}
;

const TEST_OUTPUTS: []const u8 =
    \\{
    \\    "dnsSuffix": "amazonaws.com",
    \\    "dualStackDnsSuffix": "api.aws",
    \\    "implicitGlobalRegion": "us-east-1",
    \\    "name": "aws",
    \\    "supportsDualStack": true,
    \\    "supportsFIPS": true
    \\}
;

const TEST_SRC: []const u8 =
    \\{
    \\  "partitions": [
    \\    {
    \\      "id": "aws",
    \\      "outputs": {
    \\          "dnsSuffix": "amazonaws.com",
    \\          "dualStackDnsSuffix": "api.aws",
    \\          "implicitGlobalRegion": "us-east-1",
    \\          "name": "aws",
    \\          "supportsDualStack": true,
    \\          "supportsFIPS": true
    \\      },
    \\      "regionRegex": "^(us|il)\\-\\w+\\-\\d+$",
    \\      "regions": {
    \\        "il-central-1": {
    \\            "description": "Israel (Tel Aviv)"
    \\        },
    \\        "us-east-1": {
    \\            "description": "US East (N. Virginia)"
    \\        }
    \\      }
    \\    },
    \\    {
    \\      "id": "aws-cn",
    \\      "outputs": {
    \\        "dnsSuffix": "amazonaws.com.cn",
    \\        "dualStackDnsSuffix": "api.amazonwebservices.com.cn",
    \\        "implicitGlobalRegion": "cn-northwest-1",
    \\        "name": "aws-cn",
    \\        "supportsDualStack": true,
    \\        "supportsFIPS": true
    \\      },
    \\      "regionRegex": "^cn\\-\\w+\\-\\d+$",
    \\      "regions": {
    \\        "aws-cn-global": {
    \\            "description": "AWS China global region"
    \\        },
    \\        "cn-northwest-1": {
    \\            "description": "China (Ningxia)"
    \\        }
    \\      }
    \\    },
    \\    {
    \\      "id": "aws-us-gov",
    \\      "outputs": {
    \\        "dnsSuffix": "amazonaws.com",
    \\        "dualStackDnsSuffix": "api.aws",
    \\        "implicitGlobalRegion": "us-gov-west-1",
    \\        "name": "aws-us-gov",
    \\        "supportsDualStack": true,
    \\        "supportsFIPS": true
    \\      },
    \\      "regionRegex": "^us\\-gov\\-\\w+\\-\\d+$",
    \\      "regions": {
    \\        "us-gov-west-1": {
    \\            "description": "AWS GovCloud (US-West)",
    \\            "supportsFIPS": false
    \\        }
    \\      }
    \\    }
    \\  ],
    \\  "version": "1.1"
    \\}
;
