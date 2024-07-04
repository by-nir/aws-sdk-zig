const std = @import("std");
const testing = std.testing;
const test_alloc = testing.allocator;
const pipez = @import("../pipeline/root.zig");
const Task = pipez.Task;
const Delegate = pipez.Delegate;
const AbstractTask = pipez.AbstractTask;
const md = @import("../codegen/md.zig");
const zig = @import("../codegen/zig/scope.zig");
const Writer = @import("../codegen/CodegenWriter.zig");

const MD_HEAD = @embedFile("../codegen/template/head.md.template");
const ZIG_HEAD = @embedFile("../codegen/template/head.zig.template");

pub const MarkdownDoc = AbstractTask("Markdown Codegen", markdownDocTask, .{
    .varyings = &.{*md.Document.Build},
});
fn markdownDocTask(
    self: *const Delegate,
    writer: std.io.AnyWriter,
    task: *const fn (struct { *md.Document.Build }) anyerror!void,
) anyerror!void {
    var codegen = Writer.init(self.alloc(), writer);
    defer codegen.deinit();

    var build = md.Document.Build{ .allocator = self.alloc() };
    task(.{&build}) catch |err| {
        build.deinit(self.alloc());
        return err;
    };

    const document = try build.consume();
    defer document.deinit(self.alloc());
    try codegen.appendFmt(MD_HEAD ++ "\n\n{}\n", .{document});
}

pub fn expectMarkdownDoc(
    comptime task: Task,
    comptime expected: []const u8,
    input: MarkdownDoc.ChildInput(task),
) !void {
    try expectCodegen(task, MD_HEAD, expected, input);
}

test "markdown document" {
    const TestDocument = MarkdownDoc.define("Test Documen", struct {
        fn f(_: *const Delegate, bld: *md.Document.Build) anyerror!void {
            try bld.heading(2, "Foo");
        }
    }.f, .{});

    try expectMarkdownDoc(TestDocument, "## Foo", .{});
}

pub const ZigScript = AbstractTask("Zig Codegen", zigScriptTask, .{
    .varyings = &.{*zig.ContainerBuild},
});
fn zigScriptTask(
    self: *const Delegate,
    writer: std.io.AnyWriter,
    task: *const fn (struct { *zig.ContainerBuild }) anyerror!void,
) anyerror!void {
    var codegen = Writer.init(self.alloc(), writer);
    defer codegen.deinit();

    var build = zig.ContainerBuild.init(self.alloc());
    task(.{&build}) catch |err| {
        build.deinit();
        return err;
    };

    const container = try build.consume();
    defer container.deinit(self.alloc());
    try codegen.appendFmt(ZIG_HEAD ++ "\n\n{}\n", .{container});
}

pub fn expectZigScript(
    comptime task: Task,
    comptime expected: []const u8,
    input: ZigScript.ChildInput(task),
) !void {
    try expectCodegen(task, ZIG_HEAD, expected, input);
}

test "zig script" {
    const TestScript = ZigScript.define("Test Script", struct {
        fn f(_: *const Delegate, bld: *zig.ContainerBuild) anyerror!void {
            try bld.constant("foo").assign(bld.x.raw("undefined"));
        }
    }.f, .{});

    try expectZigScript(TestScript, "const foo = undefined;", .{});
}

fn expectCodegen(
    comptime task: Task,
    comptime head: []const u8,
    comptime expected: []const u8,
    input: anytype,
) !void {
    var tester = try pipez.PipelineTester.init(.{});
    defer tester.deinit();

    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    try tester.evaluateSync(task, .{buffer.writer().any()} ++ input);
    try testing.expectEqualStrings(head ++ "\n\n" ++ expected ++ "\n", buffer.items);
}
