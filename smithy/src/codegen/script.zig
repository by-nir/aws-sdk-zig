const std = @import("std");
const fs = std.fs;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Writer = @import("CodegenWriter.zig");
const md = @import("md.zig");
const zig = @import("zig/scope.zig");
const Closure = @import("../utils/declarative.zig").Closure;

pub const ScriptLang = enum { zig, md };

const Components = struct {
    head: []const u8,
    Composer: type,
    Closure: type,
};

pub const ScriptAlloc = union(enum) {
    gpa: Allocator,
    arena: Allocator,

    pub fn any(self: ScriptAlloc) Allocator {
        return switch (self) {
            inline else => |t| t,
        };
    }
};

pub fn Script(lang: ScriptLang) type {
    const comps: Components = switch (lang) {
        .zig => .{
            .head = @embedFile("template/head.zig.template") ++ "\n\n",
            .Composer = zig.Container,
            .Closure = zig.ContainerClosure,
        },
        .md => .{
            .head = @embedFile("template/head.md.template") ++ "\n\n",
            .Composer = md.Document,
            .Closure = md.DocumentClosure,
        },
    };

    return struct {
        arena: Allocator,
        managed_arena: ?*std.heap.ArenaAllocator,
        output: Output,
        success: bool = false,

        const Self = @This();

        /// Memory storage is mostly intended for testing:
        ///
        /// ```zig
        /// const script = try Script(.zig).initEphemeral(.{ .gpa = test_alloc });
        /// defer script.deinit();
        /// // Generate content...
        /// // Use `script.arena` for temporary allocations.
        /// try script.expect("expected script output");
        /// ```
        pub fn initEphemeral(allocator: ScriptAlloc) !Self {
            const alloc = allocator.any();
            const output = try Output.initEphemeral(alloc);
            errdefer output.deinit(alloc, false);
            return init(allocator, output);
        }

        /// Generate a script file.
        ///
        /// The `allocator` argument accepts a gpa or an existing arena, either
        /// way an arena allocator is accessible through the `arena` field.
        ///
        /// ```zig
        /// var script = try Script(.zig).initPersist(.{ .arena = arena });
        /// defer script.deinit();
        /// // Generate content...
        /// try script.end();
        /// ```
        pub fn initPersist(allocator: ScriptAlloc, dir: fs.Dir, sub_path: []const u8) !Self {
            const alloc = allocator.any();
            const output = try Output.initPersist(alloc, dir, sub_path);
            errdefer output.deinit(alloc, true);
            return init(allocator, output);
        }

        fn init(allocator: ScriptAlloc, output: Output) !Self {
            var managed_arena: ?*std.heap.ArenaAllocator = null;
            errdefer if (managed_arena) |arena| {
                arena.child_allocator.destroy(arena);
                arena.deinit();
            };

            const arena_alloc: Allocator = switch (allocator) {
                .gpa => |alloc| blk: {
                    const arena = try alloc.create(std.heap.ArenaAllocator);
                    arena.* = std.heap.ArenaAllocator.init(alloc);
                    managed_arena = arena;
                    break :blk arena.allocator();
                },
                .arena => |a| a,
            };

            try output.writer().writeAll(comps.head);

            return .{
                .arena = arena_alloc,
                .managed_arena = managed_arena,
                .output = output,
            };
        }

        pub fn deinit(self: Self) void {
            const alloc = if (self.managed_arena) |arena| blk: {
                const gpa = arena.child_allocator;
                arena.deinit();
                gpa.destroy(arena);
                break :blk gpa;
            } else self.arena;

            self.output.deinit(alloc, !self.success);
        }

        pub fn writer(self: Self) std.io.AnyWriter {
            return self.output.writer();
        }

        pub fn writeBody(
            self: Self,
            ctx: anytype,
            closure: Closure(@TypeOf(ctx), comps.Closure),
        ) !void {
            var codegen = Writer.init(self.arena, self.writer());
            defer codegen.deinit();

            const composer = try comps.Composer.init(self.arena, ctx, closure);
            defer composer.deinit(self.arena);
            try composer.write(&codegen);
        }

        /// Complete the script and deinit.
        pub fn end(self: *Self) !void {
            try self.writer().writeByte('\n');
            try self.output.flush();
            self.success = true;
        }

        pub fn expect(self: Self, comptime expected: []const u8) !void {
            const output = switch (self.output) {
                .ephemeral => |t| t.buffer.items,
                else => unreachable,
            };
            try testing.expectEqualStrings(comptime comps.head ++ expected, output);
        }
    };
}

const Output = union(enum) {
    ephemeral: *const Ephemeral,
    persist: *Persist,

    const Ephemeral = struct {
        buffer: std.ArrayList(u8),
        writer: std.ArrayList(u8).Writer,
    };

    const Persist = struct {
        dir: fs.Dir,
        file: fs.File,
        sub_path: []const u8,
        buffer: FileBuffer,
        writer: FileBuffer.Writer,

        const FileBuffer = std.io.BufferedWriter(4096, fs.File.Writer);
    };

    pub fn writer(self: Output) std.io.AnyWriter {
        return switch (self) {
            inline else => |t| t.writer.any(),
        };
    }

    pub fn flush(self: Output) !void {
        switch (self) {
            .persist => |t| try t.buffer.flush(),
            else => {},
        }
    }

    pub fn initEphemeral(allocator: Allocator) !Output {
        const output = try allocator.create(Ephemeral);
        output.*.buffer = std.ArrayList(u8).init(allocator);
        output.*.writer = output.buffer.writer();
        return .{ .ephemeral = output };
    }

    pub fn initPersist(allocator: Allocator, dir: fs.Dir, sub_path: []const u8) !Output {
        const output = try allocator.create(Persist);
        errdefer allocator.destroy(output);

        const file = try dir.createFile(sub_path, .{});
        output.* = .{
            .dir = dir,
            .file = file,
            .sub_path = sub_path,
            .buffer = std.io.bufferedWriter(file.writer()),
            .writer = undefined,
        };
        output.*.writer = output.buffer.writer();
        return .{ .persist = output };
    }

    pub fn deinit(self: Output, allocator: Allocator, delete: bool) void {
        switch (self) {
            .ephemeral => |out| {
                out.buffer.deinit();
                allocator.destroy(out);
            },
            .persist => |out| {
                out.file.close();
                if (delete) out.dir.deleteFile(out.sub_path) catch |err| {
                    std.log.err("Deleting output file failed: {s}", .{@errorName(err)});
                };
                allocator.destroy(out);
            },
        }
    }
};
