const std = @import("std");
const default_whitelist = [_][]const u8{"cloudcontrol"};

pub fn build(b: *std.Build) void {
    const aws = b.dependency("aws-runtime", .{
        .target = b.graph.host,
    });

    const whitelist = b.option(
        []const []const u8,
        "filter",
        "Whitelist the services to generate",
    );

    const sdk_codegen = b.addRunArtifact(aws.artifact("codegen-sdk"));
    const partitions_codegen = b.addRunArtifact(aws.artifact("codegen-partitions"));
    if (b.lazyDependency("aws-models", .{})) |models| {
        const src_dir = models.path("sdk");
        sdk_codegen.addDirectoryArg(src_dir);
        partitions_codegen.addFileArg(src_dir.path(b, "sdk-partitions.json"));
    }

    const partitions_out_file = partitions_codegen.addOutputFileArg("partitions.zig");
    b.getInstallStep().dependOn(&partitions_codegen.step);
    const partition_install_step = b.addInstallFile(partitions_out_file, "../sdk/partitions.zig");
    b.getInstallStep().dependOn(&partition_install_step.step);

    const sdk_out_dir = sdk_codegen.addOutputDirectoryArg("sdk");
    sdk_codegen.addArgs(whitelist orelse &default_whitelist);
    b.getInstallStep().dependOn(&sdk_codegen.step);
    b.installDirectory(.{
        .source_dir = sdk_out_dir,
        .install_dir = .prefix,
        .install_subdir = "../sdk",
    });
}
