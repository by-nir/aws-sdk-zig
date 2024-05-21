const std = @import("std");
const sdk_whitelist = [_][]const u8{"cloudcontrol"};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const tests_step = b.step("test", "Run codegen unit tests");

    //
    // Smithy
    //

    const smithy = b.createModule(.{
        .optimize = optimize,
        .root_source_file = b.path("codegen/smithy/root.zig"),
    });

    const smithy_test_step = b.addTest(.{
        .name = "smithy",
        .optimize = optimize,
        .root_source_file = b.path("codegen/smithy/root.zig"),
    });
    tests_step.dependOn(&b.addRunArtifact(smithy_test_step).step);

    //
    // AWS
    //

    if (b.lazyDependency("aws-models", .{})) |models| {
        const aws_filter = b.option(
            []const []const u8,
            "filter",
            "Whitelist the resources to generate",
        );

        const aws_config = b.addOptions();
        aws_config.addOption([]const []const u8, "filter", aws_filter orelse &sdk_whitelist);

        const aws_codegen = b.addExecutable(.{
            .name = "codegen-sdk",
            .target = b.host,
            .root_source_file = b.path("codegen/aws/root.zig"),
        });
        aws_codegen.root_module.addImport("smithy", smithy);
        aws_codegen.root_module.addOptions("aws-config", aws_config);
        const aws_codegen_run = b.addRunArtifact(aws_codegen);
        aws_codegen_run.addDirectoryArg(models.path("sdk"));
        const aws_out_dir = aws_codegen_run.addOutputDirectoryArg("sdk");
        b.getInstallStep().dependOn(&aws_codegen_run.step);

        const aws_install = b.addInstallDirectory(.{
            .source_dir = aws_out_dir,
            .install_dir = .prefix,
            .install_subdir = "../sdk",
        });
        b.getInstallStep().dependOn(&aws_install.step);

        const aws_fmt = b.addFmt(.{ .paths = &.{"sdk"} });
        b.getInstallStep().dependOn(&aws_fmt.step);
    }

    const aws_test_step = b.addTest(.{
        .name = "aws",
        .optimize = optimize,
        .root_source_file = b.path("codegen/aws/root.zig"),
    });
    aws_test_step.root_module.addImport("smithy", smithy);
    tests_step.dependOn(&b.addRunArtifact(aws_test_step).step);
}
