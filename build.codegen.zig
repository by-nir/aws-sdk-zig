const std = @import("std");
const default_whitelist = [_][]const u8{ "cloudcontrol", "cloudfront" };

pub fn build(b: *std.Build) void {
    const aws = b.dependency("aws", .{ .target = b.graph.host });

    const whitelist = b.option(
        []const []const u8,
        "filter",
        "Whitelist the services to generate",
    );

    const aws_codegen = b.addRunArtifact(aws.artifact("aws-codegen"));
    if (b.lazyDependency("aws-models", .{})) |models| {
        const src_dir = models.path("sdk");
        aws_codegen.addDirectoryArg(src_dir);
    }

    const aws_out_dir = aws_codegen.addOutputDirectoryArg("aws");
    const sdk_out_dir = aws_codegen.addOutputDirectoryArg("sdk");
    aws_codegen.addArgs(whitelist orelse &default_whitelist);
    b.getInstallStep().dependOn(&aws_codegen.step);
    b.installDirectory(.{
        .source_dir = aws_out_dir,
        .install_dir = .prefix,
        .install_subdir = "../aws/runtime/infra",
    });
    b.installDirectory(.{
        .source_dir = sdk_out_dir,
        .install_dir = .prefix,
        .install_subdir = "../sdk",
    });
}
