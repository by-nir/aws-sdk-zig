const std = @import("std");
const testing = std.testing;
const test_alloc = testing.allocator;
const pipez = @import("pipez");
const Task = pipez.Task;
const Delegate = pipez.Delegate;
const AbstractTask = pipez.AbstractTask;
const AbstractEval = pipez.AbstractEval;
const cdgn = @import("codegen");
const md = cdgn.md;
const zig = cdgn.zig;
const Writer = cdgn.CodegenWriter;

const MD_HEAD = @embedFile("../template/head.md.template");
const ZIG_HEAD = @embedFile("../template/head.zig.template");

pub const MarkdownDoc = AbstractTask.Define("Markdown Codegen", markdownDocTask, .{
    .varyings = &.{*md.DocumentAuthor},
});
fn markdownDocTask(
    self: *const Delegate,
    writer: std.io.AnyWriter,
    task: AbstractEval(&.{*md.DocumentAuthor}, anyerror!void),
) anyerror!void {
    var codegen = Writer.init(self.alloc(), writer);
    defer codegen.deinit();

    var build = try md.DocumentAuthor.init(self.alloc());
    task.evaluate(.{&build}) catch |err| {
        build.deinit();
        return err;
    };

    const document = try build.consume();
    defer document.deinit(self.alloc());
    try codegen.appendFmt(MD_HEAD ++ "\n\n{}\n", .{document});
}

pub fn evaluateMarkdownDoc(
    allocator: std.mem.Allocator,
    pipeline: *pipez.Pipeline,
    comptime task: Task,
    input: AbstractTask.ExtractChildInput(task),
) ![]const u8 {
    return evaluateCodegen(allocator, pipeline, task, input);
}

pub fn expectEqualMarkdownDoc(comptime expected: []const u8, actual: []const u8) !void {
    try expectEqualCodegen(MD_HEAD, expected, actual);
}

test "markdown document" {
    const TestDocument = MarkdownDoc.Task("Test Documen", struct {
        fn f(_: *const Delegate, bld: *md.DocumentAuthor) anyerror!void {
            try bld.heading(2, "Foo");
        }
    }.f, .{});

    var tester = try pipez.PipelineTester.init(.{});
    defer tester.deinit();

    const output = try evaluateMarkdownDoc(test_alloc, tester.pipeline, TestDocument, .{});
    defer test_alloc.free(output);
    try expectEqualMarkdownDoc("## Foo", output);
}

pub const ZigScript = AbstractTask.Define("Zig Codegen", zigScriptTask, .{
    .varyings = &.{*zig.ContainerBuild},
});
fn zigScriptTask(
    self: *const Delegate,
    writer: std.io.AnyWriter,
    task: AbstractEval(&.{*zig.ContainerBuild}, anyerror!void),
) anyerror!void {
    var codegen = Writer.init(self.alloc(), writer);
    defer codegen.deinit();

    var build = zig.ContainerBuild.init(self.alloc());
    task.evaluate(.{&build}) catch |err| {
        build.deinit();
        return err;
    };

    const container = try build.consume();
    defer container.deinit(self.alloc());
    try codegen.appendFmt(ZIG_HEAD ++ "\n\n{}\n", .{container});
}

pub fn evaluateZigScript(
    allocator: std.mem.Allocator,
    pipeline: *pipez.Pipeline,
    comptime task: Task,
    input: AbstractTask.ExtractChildInput(task),
) ![]const u8 {
    return evaluateCodegen(allocator, pipeline, task, input);
}

pub fn expectEqualZigScript(comptime expected: []const u8, actual: []const u8) !void {
    try expectEqualCodegen(ZIG_HEAD, expected, actual);
}

test "zig script" {
    const TestScript = ZigScript.Task("Test Script", struct {
        fn f(_: *const Delegate, bld: *zig.ContainerBuild) anyerror!void {
            try bld.constant("foo").assign(bld.x.raw("undefined"));
        }
    }.f, .{});

    var tester = try pipez.PipelineTester.init(.{});
    defer tester.deinit();

    const output = try evaluateZigScript(test_alloc, tester.pipeline, TestScript, .{});
    defer test_alloc.free(output);
    try expectEqualZigScript("const foo = undefined;", output);
}

fn evaluateCodegen(
    allocator: std.mem.Allocator,
    pipeline: *pipez.Pipeline,
    comptime task: Task,
    input: anytype,
) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();

    try pipeline.runTask(task, .{buffer.writer().any()} ++ input);
    return buffer.toOwnedSlice();
}

fn expectEqualCodegen(comptime head: []const u8, comptime expected: []const u8, actual: []const u8) !void {
    try testing.expectEqualStrings(head ++ "\n\n" ++ expected ++ "\n", actual);
}
