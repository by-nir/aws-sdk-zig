const std = @import("std");
const fmt = std.fmt;
const builtin = std.builtin;
const ZigType = builtin.Type;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;

const Self = @This();
const ScriptOptions = struct {
};

container: Container,
options: ScriptOptions,

pub fn init(name: Identifier, options: ScriptOptions) Self {
    return .{
        .container = .{
            .identifier = name,
        },
        .options = options,
    };
}

pub const Block = struct {
    label: ?Identifier = null,
    stetements: []const Expression,

    pub fn format(self: Block, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        switch (self.stetements.len) {
            0 => {
                std.debug.assert(self.label == null);
                try writer.writeAll("{}");
            },
            1 => {
                std.debug.assert(self.label == null);
                try writer.writeAll(self.stetements[0]);
            },
            else => {
                if (self.label) |l| try writer.print("{}: ", .{l});
                try writer.writeByte('{');
                for (self.stetements) |s| {
                    // TODO: indent from options
                    try writer.print("\n    {s}", .{s});
                }
                try writer.writeAll("\n}");
            },
        }
    }
};

test "Block" {
    try testing.expectFmt("{}", "{}", .{
        Block{ .stetements = &.{} },
    });

    try testing.expectFmt("_ = foo();", "{}", .{
        Block{ .stetements = &.{"_ = foo();"} },
    });

    try testing.expectFmt(
        \\{
        \\    _ = foo();
        \\    const i = 1 + 1;
        \\}
    , "{}", .{
        Block{ .stetements = &.{ "_ = foo();", "const i = 1 + 1;" } },
    });

    try testing.expectFmt(
        \\blk: {
        \\    const i = 1 + 1;
        \\    break :blk i;
        \\}
    , "{}", .{
        Block{
            .label = Identifier{ .name = "blk" },
            .stetements = &.{ "const i = 1 + 1;", "break :blk i;" },
        },
    });
}

const Expression = []const u8;

pub const Type = struct {
    primary: Primary,
    prefix: []const Prefix = &.{},
    suffix: []const Suffix = &.{},

    pub fn format(self: Type, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        for (self.prefix) |t| try writer.print("{}", .{t});
        try writer.print("{}", .{self.primary});
        for (self.suffix) |t| try writer.print("{}", .{t});
    }

    pub const Primary = union(enum) {
        void,
        bool,
        type,
        anyerror,
        anyopaque,
        comptime_int,
        comptime_float,
        int: ?u16,
        uint: ?u16,
        string: struct { is_mutable: bool = false },
        float: ZigType.Float,
        identifier: Identifier,

        pub fn format(self: Primary, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            switch (self) {
                inline .void,
                .bool,
                .type,
                .anyerror,
                .anyopaque,
                .comptime_int,
                .comptime_float,
                => |_, t| try writer.writeAll(@tagName(t)),
                .int => |t| {
                    if (t) |b| {
                        try writer.print("i{}", .{b});
                    } else {
                        try writer.writeAll("isize");
                    }
                },
                .uint => |t| {
                    if (t) |b| {
                        try writer.print("u{}", .{b});
                    } else {
                        try writer.writeAll("usize");
                    }
                },
                .float => |t| try writer.print("f{}", .{t.bits}),
                .identifier => |t| try writer.print("{@}", .{t}),
                .string => |t| try writer.writeAll(if (t.is_mutable) "[]u8" else "[]const u8"),
            }
        }
    };

    pub const Prefix = union(enum) {
        optional,
        @"error": Expression,
        array: struct {
            len: ?Expression,
            sentinal: ?Expression = null,
        },
        pointer: struct {
            size: ZigType.Pointer.Size,
            is_const: bool = false,
            sentinal: ?Expression = null,
            alignment: ?Expression = null,
        },

        pub fn format(self: Prefix, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            switch (self) {
                .optional => try writer.writeByte('?'),
                .@"error" => |t| try writer.print("{s}!", .{t}),
                .array => |t| {
                    const expr = t.len orelse "_";
                    if (t.sentinal) |s| {
                        try writer.print("[{s}:{s}]", .{ expr, s });
                    } else {
                        try writer.print("[{s}]", .{expr});
                    }
                },
                .pointer => |t| {
                    if (t.size == .C) {
                        unreachable;
                    } else if (t.size == .One) {
                        std.debug.assert(t.sentinal == null);
                        try writer.writeByte('*');
                    } else {
                        try writer.writeByte('[');
                        if (t.size == .Many) try writer.writeByte('*');
                        if (t.sentinal) |s| try writer.print(":{s}", .{s});
                        try writer.writeByte(']');
                    }
                    if (t.is_const) try writer.writeAll("const ");
                    if (t.alignment) |a| try writer.print("align({s}) ", .{a});
                },
            }
        }
    };

    pub const Suffix = union(enum) {
        unwrap,
        dereference,
        child: Identifier,
        call: []const Expression,
        index: Expression,
        slice: struct {
            start: Expression,
            end: ?Expression = null,
            sentinal: ?Expression = null,
        },

        pub fn format(self: Suffix, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            switch (self) {
                .unwrap => try writer.writeAll(".?"),
                .dereference => try writer.writeAll(".*"),
                .child => |t| try writer.print(".{}", .{t}),
                .index => |t| try writer.print("[{s}]", .{t}),
                .slice => |t| {
                    try writer.print("[{s}..", .{t.start});
                    if (t.end) |e| try writer.writeAll(e);
                    if (t.sentinal) |s| try writer.print(":{s}", .{s});
                    try writer.writeByte(']');
                },
                .call => |t| {
                    try writer.writeByte('(');
                    for (t, 0..) |a, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.writeAll(a);
                    }
                    try writer.writeByte(')');
                },
            }
        }
    };
};

test "Type" {
    try testing.expectFmt("void", "{}", .{Type.Primary{ .void = {} }});
    try testing.expectFmt("bool", "{}", .{Type.Primary{ .bool = {} }});
    try testing.expectFmt("type", "{}", .{Type.Primary{ .type = {} }});
    try testing.expectFmt("[]const u8", "{}", .{Type.Primary{ .string = .{} }});
    try testing.expectFmt("[]u8", "{}", .{Type.Primary{ .string = .{ .is_mutable = true } }});
    try testing.expectFmt("anyerror", "{}", .{Type.Primary{ .anyerror = {} }});
    try testing.expectFmt("anyopaque", "{}", .{Type.Primary{ .anyopaque = {} }});
    try testing.expectFmt("comptime_int", "{}", .{
        Type.Primary{ .comptime_int = {} },
    });
    try testing.expectFmt("comptime_float", "{}", .{
        Type.Primary{ .comptime_float = {} },
    });
    try testing.expectFmt("i16", "{}", .{
        Type.Primary{ .int = 16 },
    });
    try testing.expectFmt("isize", "{}", .{
        Type.Primary{ .int = null },
    });
    try testing.expectFmt("u8", "{}", .{
        Type.Primary{ .uint = 8 },
    });
    try testing.expectFmt("usize", "{}", .{
        Type.Primary{ .uint = null },
    });
    try testing.expectFmt("f32", "{}", .{
        Type.Primary{ .float = .{ .bits = 32 } },
    });
    try testing.expectFmt("Foo", "{}", .{
        Type.Primary{ .identifier = Identifier{ .name = "Foo" } },
    });

    try testing.expectFmt("?", "{}", .{Type.Prefix{ .optional = {} }});
    try testing.expectFmt("anyerror!", "{}", .{Type.Prefix{ .@"error" = "anyerror" }});
    try testing.expectFmt("[8]", "{}", .{
        Type.Prefix{ .array = .{ .len = "8" } },
    });
    try testing.expectFmt("[_]", "{}", .{
        Type.Prefix{ .array = .{ .len = null } },
    });
    try testing.expectFmt("[_:0]", "{}", .{
        Type.Prefix{ .array = .{ .len = null, .sentinal = "0" } },
    });
    try testing.expectFmt("[8:0]", "{}", .{
        Type.Prefix{ .array = .{ .len = "8", .sentinal = "0" } },
    });
    try testing.expectFmt("*", "{}", .{
        Type.Prefix{ .pointer = .{ .size = .One } },
    });
    try testing.expectFmt("*const ", "{}", .{
        Type.Prefix{ .pointer = .{ .size = .One, .is_const = true } },
    });
    try testing.expectFmt("*const align(4) ", "{}", .{
        Type.Prefix{ .pointer = .{ .size = .One, .is_const = true, .alignment = "4" } },
    });
    try testing.expectFmt("[*]", "{}", .{
        Type.Prefix{ .pointer = .{ .size = .Many } },
    });
    try testing.expectFmt("[*:0]", "{}", .{
        Type.Prefix{ .pointer = .{ .size = .Many, .sentinal = "0" } },
    });
    try testing.expectFmt("[]", "{}", .{
        Type.Prefix{ .pointer = .{ .size = .Slice } },
    });
    try testing.expectFmt("[:0]", "{}", .{
        Type.Prefix{ .pointer = .{ .size = .Slice, .sentinal = "0" } },
    });

    try testing.expectFmt(".?", "{}", .{Type.Suffix{ .unwrap = {} }});
    try testing.expectFmt(".*", "{}", .{Type.Suffix{ .dereference = {} }});
    try testing.expectFmt(".foo", "{}", .{
        Type.Suffix{ .child = Identifier{ .name = "foo" } },
    });
    try testing.expectFmt("[8]", "{}", .{Type.Suffix{ .index = "8" }});
    try testing.expectFmt("[0..]", "{}", .{
        Type.Suffix{ .slice = .{ .start = "0" } },
    });
    try testing.expectFmt("[0..:0]", "{}", .{
        Type.Suffix{ .slice = .{ .start = "0", .sentinal = "0" } },
    });
    try testing.expectFmt("[0..8]", "{}", .{
        Type.Suffix{ .slice = .{ .start = "0", .end = "8" } },
    });
    try testing.expectFmt("(foo, bar)", "{}", .{
        Type.Suffix{ .call = &.{ "foo", "bar" } },
    });

    try testing.expectFmt("?[8]@This().bar.?", "{}", .{
        Type{
            .prefix = &.{ .optional, .{ .array = .{ .len = "8" } } },
            .primary = .{ .identifier = Identifier{ .name = "@This" } },
            .suffix = &.{ .{ .call = &.{} }, .{ .child = Identifier{ .name = "bar" } }, .unwrap },
        },
    });
}

pub const Identifier = union(enum) {
    name: []const u8,
    lazy: *const LazyIdentifier,

    pub fn resolve(self: Identifier, allow_builtin: bool) ![]const u8 {
        const name = switch (self) {
            .name => |val| val,
            .lazy => |idn| try idn.resolve(),
        };
        try validate(name, allow_builtin);
        return name;
    }

    pub fn format(self: Identifier, comptime fmt_str: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        const name = self.resolve(fmt_str.len == 1 and fmt_str[0] == '@') catch unreachable;
        try writer.writeAll(name);
    }

    /// regex: `@?[A-Za-z_][A-Za-z0-9_]*`
    fn validate(value: []const u8, allow_builtin: bool) !void {
        if (value.len == 0) return error.EmptyIdentifier;

        const i: u8 = if (allow_builtin and value[0] == '@') 1 else 0;
        switch (value[i]) {
            '_', 'A'...'Z', 'a'...'z' => {},
            else => return error.InvalidIdentifier,
        }

        for (value[i + 1 .. value.len]) |c| {
            switch (c) {
                '_', '0'...'9', 'A'...'Z', 'a'...'z' => {},
                else => return error.InvalidIdentifier,
            }
        }

        if (zig_keywords.has(value)) {
            return error.ReservedIdentifier;
        }
    }
};

test "Identifier.validate" {
    try testing.expectError(error.EmptyIdentifier, Identifier.validate("", false));
    try testing.expectError(error.InvalidIdentifier, Identifier.validate("0foo", false));
    try testing.expectError(error.InvalidIdentifier, Identifier.validate("foo!", false));
    try testing.expectError(error.InvalidIdentifier, Identifier.validate("@foo", false));
    try testing.expectError(error.InvalidIdentifier, Identifier.validate("@0foo", true));
    try testing.expectError(error.ReservedIdentifier, Identifier.validate("return", false));
    try testing.expectEqual({}, Identifier.validate("foo0", false));
    try testing.expectEqual({}, Identifier.validate("@foo", true));
}

test "Identifier" {
    var id = Identifier{ .name = "" };
    try testing.expectError(error.EmptyIdentifier, id.resolve(false));
    id = Identifier{ .name = "@foo" };
    try testing.expectError(error.InvalidIdentifier, id.resolve(false));
    id = Identifier{ .name = "return" };
    try testing.expectError(error.ReservedIdentifier, id.resolve(false));
    id = Identifier{ .name = "foo" };
    try testing.expectEqualDeep("foo", id.resolve(false));
    id = Identifier{ .name = "@foo" };
    try testing.expectEqualDeep("@foo", id.resolve(true));

    const lazy = LazyIdentifier{ .name = "bar" };
    id = lazy.identifier();
    try testing.expectEqualDeep("bar", id.resolve(false));

    try testing.expectFmt("foo", "{}", .{Identifier{ .name = "foo" }});
    try testing.expectFmt("@foo", "{@}", .{Identifier{ .name = "@foo" }});
}

pub const LazyIdentifier = struct {
    pub const empty = LazyIdentifier{ .name = null };

    name: ?[]const u8,

    pub fn identifier(self: *const LazyIdentifier) Identifier {
        return .{ .lazy = self };
    }

    pub fn declare(self: *LazyIdentifier, name: []const u8) !void {
        if (self.name == null) {
            self.name = name;
        } else {
            return error.RedeclaredIdentifier;
        }
    }

    pub fn redeclare(self: *LazyIdentifier, name: []const u8) void {
        self.name = name;
    }

    pub fn resolve(self: LazyIdentifier) ![]const u8 {
        return self.name orelse error.UndeclaredIdentifier;
    }
};

test "LazyIdentifier" {
    var lazy = LazyIdentifier.empty;
    try testing.expectError(error.UndeclaredIdentifier, lazy.resolve());

    try lazy.declare("foo");
    try testing.expectEqualDeep("foo", lazy.resolve());

    try testing.expectError(error.RedeclaredIdentifier, lazy.declare("bar"));
    try testing.expectEqualDeep("foo", lazy.resolve());

    const id = lazy.identifier();

    lazy.redeclare("bar");
    try testing.expectEqualDeep("bar", lazy.resolve());
    try testing.expectEqualDeep("bar", id.lazy.resolve());
}

pub const Comment = struct {
    level: Level = .normal,
    content: []const Content,

    pub const Level = enum { normal, doc, doc_top };

    pub const Content = union(enum) {
        paragraph: []const u8,
    };

    // TODO: To respect soft/hard wrap and indention, we need out own writer to keep track after config and state;
    // we need to test if the writer is SmithyWriter otherwise wrap it in a new one

    pub fn format(self: Comment, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        const prefix = switch (self.level) {
            .normal => "",
            .doc => "/",
            .doc_top => "!",
        };
        for (self.content, 0..) |content, i| {
            if (i > 0) try writer.writeByte('\n');
            switch (content) {
                .paragraph => |t| try writer.print("//{s} {s}", .{ prefix, t }),
            }
        }
    }

    test "format" {
        try testing.expectFmt("// foo", "{}", .{
            Comment{ .level = .normal, .content = &.{.{ .paragraph = "foo" }} },
        });
        try testing.expectFmt("/// foo", "{}", .{
            Comment{ .level = .doc, .content = &.{.{ .paragraph = "foo" }} },
        });
        try testing.expectFmt("//! foo", "{}", .{
            Comment{ .level = .doc_top, .content = &.{.{ .paragraph = "foo" }} },
        });

        try testing.expectFmt("// foo\n// bar", "{}", .{
            Comment{ .content = &.{ .{ .paragraph = "foo" }, .{ .paragraph = "bar" } } },
        });
    }

    // pub const Builder {
    //     // TODO: paragraph, inline text styling, code block, list, table, link, headers, etc.
    // }
};

test {
    _ = Comment;
}

const zig_keywords = std.ComptimeStringMap(void, .{
    .{ "addrspace", {} },   .{ "align", {} },          .{ "allowzero", {} }, .{ "and", {} },
    .{ "anyframe", {} },    .{ "anytype", {} },        .{ "asm", {} },       .{ "async", {} },
    .{ "await", {} },       .{ "break", {} },          .{ "callconv", {} },  .{ "catch", {} },
    .{ "comptime", {} },    .{ "const", {} },          .{ "continue", {} },  .{ "defer", {} },
    .{ "else", {} },        .{ "enum", {} },           .{ "errdefer", {} },  .{ "error", {} },
    .{ "export", {} },      .{ "extern", {} },         .{ "fn", {} },        .{ "for", {} },
    .{ "if", {} },          .{ "inline", {} },         .{ "noalias", {} },   .{ "nosuspend", {} },
    .{ "noinline", {} },    .{ "opaque", {} },         .{ "or", {} },        .{ "orelse", {} },
    .{ "packed", {} },      .{ "pub", {} },            .{ "resume", {} },    .{ "return", {} },
    .{ "linksection", {} }, .{ "struct", {} },         .{ "suspend", {} },   .{ "switch", {} },
    .{ "test", {} },        .{ "threadlocal", {} },    .{ "try", {} },       .{ "union", {} },
    .{ "unreachable", {} }, .{ "usingnamespace", {} }, .{ "var", {} },       .{ "volatile", {} },
    .{ "while", {} },
});
