const std = @import("std");
const default_whitelist = [_][]const u8{"cloudcontrol"};

pub fn build(b: *std.Build) void {
    const aws = b.dependency("aws-zig", .{
        .target = b.graph.host,
    });

    const whitelist = b.option(
        []const []const u8,
        "filter",
        "Whitelist the services to generate",
    );

    const sdk_codegen = b.addRunArtifact(aws.artifact("codegen-sdk"));
    if (b.lazyDependency("aws-models", .{})) |models| {
        sdk_codegen.addDirectoryArg(models.path("sdk"));
    }
    const sdk_codegen_output = sdk_codegen.addOutputDirectoryArg("sdk");
    sdk_codegen.addArgs(whitelist orelse &default_whitelist);
    b.getInstallStep().dependOn(&sdk_codegen.step);

    b.installDirectory(.{
        .source_dir = sdk_codegen_output,
        .install_dir = .prefix,
        .install_subdir = "../sdk",
    });
}
