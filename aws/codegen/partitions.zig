const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const smithy = @import("smithy");
const Script = smithy.Script;
const JsonReader = smithy.JsonReader;
const zig = smithy.codegen_zig;
const ExprBuild = zig.ExprBuild;
const BlockBuild = zig.BlockBuild;
const ContainerBuild = zig.ContainerBuild;

const log = std.log.scoped(.codegen_partitions);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    defer arena.deinit();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 3) return error.MissingPathsArgs;

    var src_file = try fs.cwd().openFile(args[1], .{});
    defer src_file.close();
    var reader = try JsonReader.initPersist(alloc, src_file);
    defer reader.deinit();

    var script = try Script(.zig).initPersist(.{ .arena = alloc }, fs.cwd(), args[2]);
    defer script.deinit();

    try processSource(script, &reader);
    try script.end();
}
// https://github.com/smithy-lang/smithy-rs/blob/main/rust-runtime/inlineable/src/endpoint_lib/partition.rs
fn processSource(script: Script(.zig), source: *JsonReader) !void {
    const context = .{ .arena = script.arena, .reader = source };
    try script.writeBody(context, struct {
        fn f(ctx: @TypeOf(context), bld: *ContainerBuild) !void {
            try bld.constant("std").assign(bld.x.import("std"));
            try bld.constant("Partition").assign(bld.x.import("aws_runtime").dot().raw("Endpoint.Partition"));

            try bld.public().function("resolve")
                .arg("region", bld.x.typeOf([]const u8))
                .returns(bld.x.raw("?*const Partition"))
                .body(struct {
                fn f(b: *BlockBuild) !void {
                    try b.returns().raw("partitions.get(region) orelse null").end();
                }
            }.f);

            const reader = ctx.reader;
            var regions = std.ArrayList(ExprBuild).init(ctx.arena);

            try reader.nextObjectBegin();
            while (try reader.peek() == .string) {
                const key = try reader.nextString();
                if (mem.eql(u8, "version", key)) {
                    try reader.nextStringEql("1.1");
                } else if (mem.eql(u8, "partitions", key)) {
                    try reader.nextArrayBegin();
                    while (try reader.next() != .array_end) {
                        try processPartition(ctx.arena, bld, reader, &regions);
                    }
                } else {
                    return error.UnexpectedKey;
                }
            }
            try reader.nextObjectEnd();

            try bld.constant("partitions").assign(bld.x.call(
                "std.StaticStringMap(*const Partition).initComptime",
                &.{bld.x.structLiteral(null, regions.items)},
            ));
        }
    }.f);
}

fn processPartition(
    arena: Allocator,
    bld: *ContainerBuild,
    reader: *JsonReader,
    regions: *std.ArrayList(ExprBuild),
) !void {
    var id: []u8 = "";
    var regex: []const u8 = "";
    var out_name: []const u8 = "";
    var out_dns_suffix: []const u8 = "";
    var out_dual_dns_suffix: []const u8 = "";
    var out_supports_fips: bool = false;
    var out_supports_dual_stack: bool = false;
    var out_implicit_region: []const u8 = "";

    while (try reader.peek() == .string) {
        var key = try reader.nextString();
        if (mem.eql(u8, "id", key)) {
            const raw = try reader.nextString();
            id = try std.fmt.allocPrint(arena, "prtn_{s}", .{raw});
            mem.replaceScalar(u8, id[6..id.len], '-', '_');
        } else if (mem.eql(u8, "outputs", key)) {
            try reader.nextObjectBegin();
            while (try reader.peek() == .string) {
                key = try reader.nextString();
                if (mem.eql(u8, "name", key)) {
                    out_name = try reader.nextStringAlloc(arena);
                } else if (mem.eql(u8, "dnsSuffix", key)) {
                    out_dns_suffix = try reader.nextStringAlloc(arena);
                } else if (mem.eql(u8, "dualStackDnsSuffix", key)) {
                    out_dual_dns_suffix = try reader.nextStringAlloc(arena);
                } else if (mem.eql(u8, "supportsFIPS", key)) {
                    out_supports_fips = try reader.nextBoolean();
                } else if (mem.eql(u8, "supportsDualStack", key)) {
                    out_supports_dual_stack = try reader.nextBoolean();
                } else if (mem.eql(u8, "implicitGlobalRegion", key)) {
                    out_implicit_region = try reader.nextStringAlloc(arena);
                } else {
                    return error.UnexpectedKey;
                }
            }
            try reader.nextObjectEnd();
        } else if (mem.eql(u8, "regionRegex", key)) {
            regex = try reader.nextString();
        } else if (mem.eql(u8, "regions", key)) {
            const target = bld.x.addressOf().id(id);
            try reader.nextObjectBegin();
            while (try reader.peek() != .object_end) {
                const region = bld.x.valueOf(try reader.nextStringAlloc(arena));
                const dibi = bld.x.structLiteral(null, &.{ region, target });
                try regions.append(dibi);
                try reader.skipValueOrScope();
            }
            try reader.nextObjectEnd();
        } else {
            return error.UnexpectedKey;
        }
    }
    try reader.nextObjectEnd();

    if (id.len == 0 or regex.len == 0 or out_dns_suffix.len == 0 or
        out_dual_dns_suffix.len == 0 or out_implicit_region.len == 0)
    {
        return error.MissingKey;
    }

    try bld.constant(id).assign(bld.x.structLiteral(bld.x.id("Partition"), &.{
        bld.x.structAssign("name", bld.x.valueOf(out_name)),
        bld.x.structAssign("dns_suffix", bld.x.valueOf(out_dns_suffix)),
        bld.x.structAssign("dual_stack_dns_suffix", bld.x.valueOf(out_dual_dns_suffix)),
        bld.x.structAssign("supports_fips", bld.x.valueOf(out_supports_fips)),
        bld.x.structAssign("supports_dual_stack", bld.x.valueOf(out_supports_dual_stack)),
        bld.x.structAssign("implicit_global_region", bld.x.valueOf(out_implicit_region)),
    }));
}

test "processSource" {
    const script = try Script(.zig).initEphemeral(.{ .gpa = test_alloc });
    defer script.deinit();

    var reader = try JsonReader.initFixed(script.arena, TEST_SRC);
    defer reader.deinit();

    try processSource(script, &reader);
    try script.expect(TEST_OUT);
}

const TEST_OUT: []const u8 =
    \\const std = @import("std");
    \\
    \\const Partition = @import("aws_runtime").Endpoint.Partition;
    \\
    \\pub fn resolve(region: []const u8) ?*const Partition {
    \\    return partitions.get(region) orelse null;
    \\}
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
    \\const prtn_aws_cn = Partition{
    \\    .name = "aws-cn",
    \\    .dns_suffix = "amazonaws.com.cn",
    \\    .dual_stack_dns_suffix = "api.amazonwebservices.com.cn",
    \\    .supports_fips = true,
    \\    .supports_dual_stack = true,
    \\    .implicit_global_region = "cn-northwest-1",
    \\};
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
    \\const partitions = std.StaticStringMap(*const Partition).initComptime(.{
    \\    .{ "il-central-1", &prtn_aws },
    \\    .{ "us-east-1", &prtn_aws },
    \\    .{ "aws-cn-global", &prtn_aws_cn },
    \\    .{ "cn-northwest-1", &prtn_aws_cn },
    \\    .{ "us-gov-west-1", &prtn_aws_us_gov },
    \\});
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
    \\            "description": "AWS GovCloud (US-West)"
    \\        }
    \\      }
    \\    }
    \\  ],
    \\  "version": "1.1"
    \\}
;
