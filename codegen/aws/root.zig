const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const smithy = @import("smithy");
const Script = smithy.Script;
const SmithyModel = smithy.SmithyModel;
const GenerateHooks = smithy.GenerateHooks;
const options = @import("options");
const whitelist: []const []const u8 = options.filter;
const models_path: []const u8 = options.models_path;
const install_path: []const u8 = options.install_path;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_alloc = gpa.allocator();
    defer _ = gpa.deinit();

    var pipeline = try smithy.Pipeline.init(gpa_alloc, std.heap.page_allocator, .{
        .src_dir_absolute = models_path,
        .out_dir_relative = install_path,
        .parse_policy = .{ .property = .abort, .trait = .skip },
    }, .{
        .writeScriptHead = writeScriptHead,
        .uniqueListType = uniqueListType,
        .writeErrorShape = writeErrorShape,
        .operationReturnType = operationReturnType,
        .writeOperationBody = writeOperationBody,
    }, null);
    defer pipeline.deinit();

    if (whitelist.len == 0) {
        _ = try pipeline.processAll(filterSourceModel);
    } else {
        var files = try std.ArrayList([]const u8).initCapacity(gpa_alloc, whitelist.len);
        defer {
            for (files.items) |file| {
                gpa_alloc.free(file);
            }
            files.deinit();
        }
        for (whitelist) |filename| {
            try files.append(try std.fmt.allocPrint(gpa_alloc, "{s}.json", .{filename}));
        }
        _ = try pipeline.processFiles(files.items);
    }
}

fn filterSourceModel(filename: []const u8) bool {
    return !std.mem.startsWith(u8, filename, "sdk-");
}

fn writeScriptHead(arena: Allocator, script: *Script) !void {
    _ = try script.import("std");

    const types = try script.import("aws-types");
    _ = try script.variable(.{}, .{
        .identifier = .{ .name = "ErrorSource" },
        .type = null,
    }, .{ .raw = try types.child(arena, "ErrorSource") });
    _ = try script.variable(.{}, .{
        .identifier = .{ .name = "Failable" },
        .type = null,
    }, .{ .raw = try types.child(arena, "Failable") });
}

fn uniqueListType(arena: Allocator, item: Script.Expr) !Script.Expr {
    const args = try arena.alloc(Script.Expr, 1);
    args[0] = item;
    return Script.Expr.call("*const _aws_types.Set", &args);
}

fn writeErrorShape(_: Allocator, script: *Script, _: *const SmithyModel, shape: GenerateHooks.ErrorShape) !void {
    _ = try script.variable(.{ .is_public = true }, .{
        .identifier = .{ .name = "source" },
        .type = .{ .raw = "ErrorSource" },
    }, Script.Expr.val(shape.source));

    _ = try script.variable(.{ .is_public = true }, .{
        .identifier = .{ .name = "code" },
        .type = Script.Expr.typ(u10),
    }, Script.Expr.val(shape.code));

    _ = try script.variable(.{ .is_public = true }, .{
        .identifier = .{ .name = "retryable" },
    }, Script.Expr.val(shape.retryable));
}

fn operationReturnType(arena: Allocator, _: *const SmithyModel, shape: GenerateHooks.OperationShape) !?Script.Expr {
    return if (shape.errors_type) |errors| blk: {
        const args = try arena.alloc(Script.Expr, 2);
        args[0] = shape.output_type orelse Script.Expr.typ(void);
        args[1] = errors;
        break :blk Script.Expr.call("Failable", args);
    } else shape.output_type;
}

fn writeOperationBody(_: Allocator, body: *Script.Scope, model: *const SmithyModel, shape: GenerateHooks.OperationShape) !void {
    const action = try model.tryGetName(shape.id);
    _ = action; // autofix

    try body.expr(.{ .raw = "_ = self" });
    try body.expr(.{ .raw = "_ = input" });
    try body.prefix(.ret).expr(.{ .raw = "undefined" });
}
