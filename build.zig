const std = @import("std");
const Build = std.Build;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const aws_types = b.addModule("aws-types", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/types/root.zig"),
    });

    // See runtime client for more information
    const https12 = b.dependency("https12", .{
        .target = target,
        .optimize = optimize,
    });

    const runtime = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/runtime/root.zig"),
        .imports = &.{
            .{ .name = "aws-types", .module = aws_types },
            .{ .name = "https12", .module = https12.module("zig-tls12") },
        },
    });

    //
    // Tests
    //

    const test_step = b.step("test", "Run core unit tests");

    const types_unit_tests = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/types/root.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(types_unit_tests).step);

    const runtime_unit_tests = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/runtime/root.zig"),
    });
    runtime_unit_tests.root_module.addImport("aws-types", aws_types);
    runtime_unit_tests.root_module.addImport("https12", https12.module("zig-tls12"));
    test_step.dependOn(&b.addRunArtifact(runtime_unit_tests).step);

    //
    // Generated modules
    //

    const generated = AddGenerated.init(b, .{
        .target = target,
        .optimize = optimize,
    });
    generated.sdks("sdk", aws_types, runtime) catch |e| {
        std.debug.print("Failed adding generated SDKs modules: {}\n", .{e});
    };
}

const AddGenerated = struct {
    pub const Options = struct {
        target: Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    };

    b: *Build,
    options: Options,

    pub fn init(b: *std.Build, options: Options) AddGenerated {
        return .{ .b = b, .options = options };
    }

    pub fn sdks(self: AddGenerated, install_path: []const u8, aws_types: *Build.Module, runtime: *Build.Module) !void {
        const root = self.b.pathFromRoot(install_path);
        var dir = try std.fs.openDirAbsolute(root, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterateAssumeFirstIteration();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            self.sdk(install_path, entry.name, aws_types, runtime);
        }
    }

    pub fn sdk(
        self: AddGenerated,
        install_path: []const u8,
        name: []const u8,
        aws_types: *Build.Module,
        runtime: *Build.Module,
    ) void {
        const path = self.b.path(self.b.fmt("{s}/{s}/client.zig", .{ install_path, name }));
        _ = self.b.addModule(
            self.b.fmt("aws-{s}", .{name}),
            .{
                .target = self.options.target,
                .optimize = self.options.optimize,
                .root_source_file = path,
                .imports = &.{
                    .{ .name = "aws-types", .module = aws_types },
                    .{ .name = "aws-runtime", .module = runtime },
                },
            },
        );

        const test_step = self.b.step(
            self.b.fmt("test:{s}", .{name}),
            self.b.fmt("Run `{s}` SDK tests", .{name}),
        );
        const unit_tests = self.b.addTest(.{
            .target = self.options.target,
            .optimize = self.options.optimize,
            .root_source_file = path,
        });
        unit_tests.root_module.addImport("aws-types", aws_types);
        unit_tests.root_module.addImport("aws-runtime", runtime);
        test_step.dependOn(&self.b.addRunArtifact(unit_tests).step);
    }
};
