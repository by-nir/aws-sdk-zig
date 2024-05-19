const std = @import("std");
const sdk_whitelist = [_][]const u8{"cloudcontrol"};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    //
    // Smithy
    //

    const smithy = b.createModule(.{
        .optimize = optimize,
        .root_source_file = b.path("codegen/smithy/root.zig"),
    });

    // Tests
    const smithy_unit_tests = b.addTest(.{
        .optimize = optimize,
        .root_source_file = b.path("codegen/smithy/root.zig"),
    });
    const smithy_unit_tests_step = b.step("test:smithy", "Run Smithy unit tests");
    smithy_unit_tests_step.dependOn(&b.addRunArtifact(smithy_unit_tests).step);

    //
    // AWS
    //

    if (b.lazyDependency("aws-models", .{})) |models| {
        const filter = b.option(
            []const []const u8,
            "filter",
            "Whitelist the resources to generate",
        );

        const sdk_options = b.addOptions();
        sdk_options.addOptionPath("models_path", models.path("sdk"));
        sdk_options.addOption([]const u8, "install_path", b.pathFromRoot("sdk"));
        sdk_options.addOption([]const []const u8, "filter", filter orelse &sdk_whitelist);

        const codegen_sdk_steps = b.step("aws", "Generate SDKs source code");
        const codegen_sdk = b.addExecutable(.{
            .name = "codegen-sdk",
            .target = b.host,
            .root_source_file = b.path("codegen/aws/root.zig"),
        });
        codegen_sdk.root_module.addOptions("options", sdk_options);
        codegen_sdk.root_module.addImport("smithy", smithy);
        codegen_sdk_steps.dependOn(&b.addRunArtifact(codegen_sdk).step);
    }

    // Tests
    const codegen_sdk_tests = b.addTest(.{
        .optimize = optimize,
        .root_source_file = b.path("codegen/aws/root.zig"),
    });
    codegen_sdk_tests.root_module.addImport("smithy", smithy);
    const acodegen_sdk_tests_step = b.step("test:aws", "Run AWS source generation unit tests");
    acodegen_sdk_tests_step.dependOn(&b.addRunArtifact(codegen_sdk_tests).step);
}
