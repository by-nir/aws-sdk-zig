const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    if (b.lazyDependency("aws-models", .{})) |models| {
        const filter = b.option(
            []const []const u8,
            "filter",
            "Whitelist the resources to generate",
        );

        //
        // SDKs
        //

        const sdk_whitelist = [_][]const u8{"cloudcontrol"};

        const sdk_options = b.addOptions();
        sdk_options.addOptionPath("models_path", models.path("sdk"));
        sdk_options.addOption([]const u8, "install_path", b.pathFromRoot("sdk"));
        sdk_options.addOption([]const []const u8, "filter", filter orelse &sdk_whitelist);

        const codegen_sdk_steps = b.step("sdk", "Generate SDKs source code");
        const codegen_sdk = b.addExecutable(.{
            .name = "codegen-sdk",
            .target = b.host,
            .root_source_file = .{ .path = "codegen/sdk.zig" },
        });
        codegen_sdk.root_module.addOptions("codegen-options", sdk_options);
        codegen_sdk_steps.dependOn(&b.addRunArtifact(codegen_sdk).step);
    }

    //
    // Tests
    //

    const codegen_unit_tests = b.addTest(.{
        .optimize = optimize,
        .root_source_file = .{ .path = "codegen/root.zig" },
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(codegen_unit_tests).step);
}
