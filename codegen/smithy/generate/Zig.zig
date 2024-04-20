//! Generate Zig source code for a single file.
const std = @import("std");
const fmt = std.fmt;
const builtin = std.builtin;
const ZigType = builtin.Type;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const StackWriter = @import("../utils/StackWriter.zig");
const List = StackWriter.List;
const Markdown = @import("Markdown.zig");

// In general, a better approach would be to incorporate more of the Zig’s AST
// capabilities directly; but it seems to have expectaions and assumptions for
// an actual source. For now will stick with the current approach, but it’s
// worth looking into in the futrure.

const Container = @This();
pub const CommentLevel = enum { normal, doc, doc_top };
const INDENT = "    ";

writer: *StackWriter,
parent: ?*const Container,
section: Section = .none,
previous: Statements = .comptime_block,
imports: std.StringArrayHashMapUnmanaged(Identifier) = .{},

const Section = enum { none, fields, funcs };
const Statements = enum { comment, doc, test_block, comptime_block, field, variable, function, using };

/// Call `end()` to complete the declaration and deinit.
pub fn init(writer: *StackWriter, parent: ?*const Container) !Container {
    return .{
        .parent = parent,
        .writer = if (parent != null) blk: {
            try writer.writeAll("{\n");
            const scope = try writer.appendPrefix(INDENT);
            try scope.deferLineAll(.parent, "}");
            break :blk scope;
        } else writer,
    };
}

/// Complete the declaration and deinit.
pub fn end(self: *Container) !void {
    const allocator = self.writer.allocator;
    for (self.imports.values()) |id| {
        allocator.free(id.name);
    }
    self.imports.deinit(allocator);

    try self.writer.deinit();
    self.* = undefined;
}

// Root <- skip container_doc_comment? ContainerMembers eof
// ContainerMembers <- ContainerDeclaration* (ContainerField COMMA)* (ContainerField / ContainerDeclaration*)
// ContainerField <- doc_comment? KEYWORD_comptime? !KEYWORD_fn (IDENTIFIER COLON)? TypeExpr ByteAlign? (EQUAL Expr)?
// ContainerDeclaration <- TestDecl / ComptimeDecl / doc_comment? KEYWORD_pub? Decl
// Decl
//     <- (KEYWORD_export / KEYWORD_extern STRINGLITERALSINGLE? / KEYWORD_inline / KEYWORD_noinline)? FnProto (SEMICOLON / Block)
//      / (KEYWORD_export / KEYWORD_extern STRINGLITERALSINGLE?)? KEYWORD_threadlocal? GlobalVarDecl
//      / KEYWORD_usingnamespace Expr SEMICOLON
// GlobalVarDecl <- VarDeclProto (EQUAL Expr)? SEMICOLON
// TestDecl <- KEYWORD_test (STRINGLITERALSINGLE / IDENTIFIER)? Block
// ComptimeDecl <- KEYWORD_comptime Block

fn importFromHierarchy(self: *const Container, rel_path: []const u8) ?Identifier {
    if (self.imports.get(rel_path)) |id| return id;
    if (self.parent) |p| return p.importFromHierarchy(rel_path);
    return null;
}

pub fn import(self: *Container, rel_path: []const u8) !Identifier {
    if (self.importFromHierarchy(rel_path)) |id| return id;

    const allocator = self.writer.allocator;
    const id_name = try allocator.alloc(u8, "_imp_".len + rel_path.len);
    @memcpy(id_name[0..5], "_imp_");
    errdefer allocator.free(id_name);
    const output = id_name["_imp_".len..][0..rel_path.len];
    _ = std.mem.replace(u8, rel_path, "../", "xx_", output);
    std.mem.replaceScalar(u8, output, '.', '_');
    std.mem.replaceScalar(u8, output, '/', '_');

    if (self.parent == null and self.imports.count() == 0) {
        try self.writer.deferLineAll(.self, "");
    }
    try self.writer.deferLineFmt(.self, "{}", .{Variable{
        .decl = .{
            .assign = Expr{ .temp_import = rel_path },
        },
        .proto = .{
            .identifier = id_name,
            .type = null,
        },
    }});
    const id = Identifier{ .name = id_name };
    try self.imports.put(allocator, rel_path, id);
    return id;
}

test "import" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    var scope = try init(&writer, null);

    try testing.expectEqualDeep(Identifier{ .name = "_imp_std" }, scope.import("std"));
    try testing.expectEqualDeep(Identifier{ .name = "_imp_xx_foo_bar_zig" }, scope.import("../foo/bar.zig"));
    try testing.expectEqualDeep(Identifier{ .name = "_imp_std" }, scope.import("std"));

    var child = try init(&writer, &scope);
    try testing.expectEqualDeep(Identifier{ .name = "_imp_xx_baz_zig" }, child.import("../baz.zig"));
    try testing.expectEqualDeep(Identifier{ .name = "_imp_std" }, child.import("std"));
    try child.end();

    try scope.end();
    try testing.expectEqualStrings(
        \\{
        \\
        \\    const _imp_xx_baz_zig = @import("../baz.zig");
        \\}
        \\
        \\const _imp_std = @import("std");
        \\const _imp_xx_foo_bar_zig = @import("../foo/bar.zig");
    , buffer.items);
}

pub fn field(self: *Container, f: Field) !?Identifier {
    if (self.section == .none) {
        self.section = .fields;
    } else if (self.section == .funcs) {
        return error.FieldAfterFunction;
    } else switch (self.previous) {
        .doc, .comment, .field => try self.writer.lineBreak(1),
        else => try self.writer.lineBreak(2),
    }
    self.previous = .field;
    try self.writer.prefixedFmt("{},", .{f});
    return if (f.identifier) |id| Identifier{ .name = id } else null;
}

test "field" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    var scope = try init(&writer, null);

    const fld = Field{
        .identifier = "foo",
        .type = TypeExpr{ .temp = "u8" },
    };
    try testing.expectEqualDeep(Identifier{ .name = "foo" }, scope.field(fld));
    try testing.expectEqual(.fields, scope.section);

    _ = try scope.field(fld);
    scope.previous = .doc;
    _ = try scope.field(fld);
    scope.previous = .comment;
    _ = try scope.field(fld);

    scope.previous = .comptime_block;
    _ = try scope.field(fld);

    scope.section = .funcs;
    try testing.expectError(error.FieldAfterFunction, scope.field(fld));

    try scope.end();
    try testing.expectEqualStrings(
        "foo: u8,\nfoo: u8,\nfoo: u8,\nfoo: u8,\n\nfoo: u8,",
        buffer.items,
    );
}

pub fn variable(self: *Container, decl: Variable.Declaration, proto: Variable.Prototype) !Identifier {
    if (self.section == .none) {
        self.section = .fields;
    } else switch (self.previous) {
        .doc, .comment, .variable, .using => try self.writer.lineBreak(1),
        else => try self.writer.lineBreak(2),
    }
    self.previous = .variable;
    try self.writer.prefixedFmt("{}", .{Variable{
        .decl = decl,
        .proto = proto,
    }});
    return Identifier{ .name = proto.identifier };
}

test "variable" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    var scope = try init(&writer, null);

    const proto = Variable.Prototype{
        .identifier = "foo",
        .type = TypeExpr{ .temp = "bool" },
    };
    try testing.expectEqualDeep(
        Identifier{ .name = "foo" },
        scope.variable(.{}, proto),
    );
    try testing.expectEqual(.fields, scope.section);

    _ = try scope.variable(.{}, proto);
    scope.previous = .doc;
    _ = try scope.variable(.{}, proto);
    scope.previous = .comment;
    _ = try scope.variable(.{}, proto);
    scope.previous = .using;
    _ = try scope.variable(.{}, proto);

    scope.previous = .comptime_block;
    _ = try scope.variable(.{}, proto);

    try scope.end();
    try testing.expectEqualStrings(
        \\const foo: bool;
        \\const foo: bool;
        \\const foo: bool;
        \\const foo: bool;
        \\const foo: bool;
        \\
        \\const foo: bool;
    , buffer.items);
}

pub fn using(self: *Container, decl: Using) !void {
    if (self.section == .none) {
        self.section = .fields;
    } else switch (self.previous) {
        .doc, .comment, .variable, .using => try self.writer.lineBreak(1),
        else => try self.writer.lineBreak(2),
    }
    self.previous = .using;
    try self.writer.prefixedFmt("{}", .{decl});
}

test "using" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    var scope = try init(&writer, null);

    try scope.using(Using{ .expr = Expr{ .raw = "foo" } });
    try testing.expectEqual(.fields, scope.section);

    try scope.using(Using{ .expr = Expr{ .raw = "bar" } });
    scope.previous = .doc;
    try scope.using(Using{ .expr = Expr{ .raw = "baz" } });
    scope.previous = .comment;
    try scope.using(Using{ .expr = Expr{ .raw = "qux" } });
    scope.previous = .variable;
    try scope.using(Using{ .expr = Expr{ .raw = "quux" } });

    scope.section = .funcs;
    scope.previous = .comptime_block;
    try scope.using(Using{ .expr = Expr{ .raw = "quuz" } });

    try scope.end();
    try testing.expectEqualStrings(
        \\usingnamespace foo;
        \\usingnamespace bar;
        \\usingnamespace baz;
        \\usingnamespace qux;
        \\usingnamespace quux;
        \\
        \\usingnamespace quuz;
    , buffer.items);
}

pub fn function(self: *Container, decl: Function.Declaration, proto: Function.Prototype) !Scope {
    if (self.section != .none) {
        switch (self.previous) {
            .doc, .comment => try self.writer.lineBreak(1),
            else => try self.writer.lineBreak(2),
        }
    }
    try self.writer.prefixedFmt("{}{} ", .{ decl, proto });
    self.section = .funcs;
    return Scope.init(self.writer, .{}, .{ .form = .block });
}

test "function" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    var scope = try init(&writer, null);

    scope.previous = .doc;
    var func = try scope.function(.{
        .is_public = true,
    }, .{
        .identifier = Identifier{ .name = "foo" },
        .parameters = &.{},
        .return_type = null,
    });
    try testing.expectEqual(.funcs, scope.section);
    try func.expression(.{ .raw = "bar()" });
    try func.end();

    try scope.end();
    try testing.expectEqualStrings("pub fn foo() void {\n    bar();\n}", buffer.items);
}

// TestDecl <- KEYWORD_test (STRINGLITERALSINGLE / IDENTIFIER)? Block
/// Call `end()` to complete the declaration.
pub fn testBlock(self: *Container, name: []const u8) !Scope {
    if (self.section == .none) {
        self.section = .fields;
    } else switch (self.previous) {
        .doc => return error.InvalidBlockAfterDoc,
        .comment => try self.writer.lineBreak(1),
        else => try self.writer.lineBreak(2),
    }
    self.previous = .test_block;
    if (name.len > 0) {
        try self.writer.prefixedFmt("test \"{s}\" ", .{name});
    } else {
        try self.writer.prefixedAll("test ");
    }
    return Scope.init(self.writer, .{}, .{ .form = .block });
}

test "testBlock" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    var scope = try init(&writer, null);

    var block = try scope.testBlock("foo");
    try testing.expectEqual(.fields, scope.section);
    try block.expression(.{ .raw = "bar()" });
    try block.end();

    block = try scope.testBlock("");
    try block.expression(.{ .raw = "bar()" });
    try block.end();

    scope.previous = .comment;
    block = try scope.testBlock("foo");
    try block.expression(.{ .raw = "bar()" });
    try block.end();

    scope.previous = .doc;
    try testing.expectError(error.InvalidBlockAfterDoc, scope.testBlock(""));

    try scope.end();
    try testing.expectEqualStrings(
        \\test "foo" {
        \\    bar();
        \\}
        \\
        \\test {
        \\    bar();
        \\}
        \\test "foo" {
        \\    bar();
        \\}
    , buffer.items);
}

// ComptimeDecl <- KEYWORD_comptime Block
/// Call `end()` to complete the declaration.
pub fn comptimeBlock(self: *Container) !Scope {
    if (self.section == .none) {
        self.section = .fields;
    } else switch (self.previous) {
        .doc => return error.InvalidBlockAfterDoc,
        .comment, .variable => try self.writer.lineBreak(1),
        else => try self.writer.lineBreak(2),
    }
    self.previous = .comptime_block;
    try self.writer.prefixedAll("comptime ");
    return Scope.init(self.writer, .{}, .{ .form = .block });
}

test "comptimeBlock" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    var scope = try init(&writer, null);

    var block = try scope.comptimeBlock();
    try testing.expectEqual(.fields, scope.section);
    try block.expression(.{ .raw = "foo()" });
    try block.end();

    block = try scope.comptimeBlock();
    try block.expression(.{ .raw = "foo()" });
    try block.end();

    scope.previous = .comment;
    block = try scope.comptimeBlock();
    try block.expression(.{ .raw = "foo()" });
    try block.end();

    scope.previous = .doc;
    try testing.expectError(error.InvalidBlockAfterDoc, scope.comptimeBlock());

    try scope.end();
    try testing.expectEqualStrings(
        \\comptime {
        \\    foo();
        \\}
        \\
        \\comptime {
        \\    foo();
        \\}
        \\comptime {
        \\    foo();
        \\}
    , buffer.items);
}

/// Call `end()` to complete the comment.
pub fn comment(self: *Container, level: CommentLevel) !Markdown {
    if (self.section != .none) {
        if (level == .doc_top) return error.TopDocAfterStatements;
        const br: u8 = switch (self.previous) {
            .doc, .comment => 1,
            else => 2,
        };
        try self.writer.lineBreak(br);
    } else {
        self.section = .fields;
    }

    const scope = try self.writer.appendPrefix(switch (level) {
        .normal => blk: {
            self.previous = .comment;
            break :blk "// ";
        },
        .doc => blk: {
            self.previous = .doc;
            break :blk "/// ";
        },
        .doc_top => "//! ",
    });
    return Markdown.init(scope);
}

test "comment" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    var scope = try init(&writer, null);

    var c = try scope.comment(.doc_top);
    try testing.expectEqual(.fields, scope.section);
    try c.paragraph("foo");
    try c.end();

    c = try scope.comment(.normal);
    try c.paragraph("bar");
    try c.end();

    c = try scope.comment(.doc);
    try c.paragraph("baz");
    try c.end();

    c = try scope.comment(.normal);
    try c.paragraph("qux");
    try c.end();

    try testing.expectError(error.TopDocAfterStatements, scope.comment(.doc_top));

    try scope.end();
    try testing.expectEqualStrings(
        \\//! foo
        \\
        \\// bar
        \\/// baz
        \\// qux
    , buffer.items);
}

test {
    _ = LazyIdentifier;
    _ = Identifier;
    _ = ByteAlign;
    _ = Extern;

    _ = Field;
    _ = Using;
    _ = Variable;
    _ = Function;

    _ = IfPrefix;
    _ = ForPrefix;
    _ = WhilePrefix;
    _ = SwitchExpr;

    _ = Scope;
}

// doc_comment? KEYWORD_pub? KEYWORD_usingnamespace Expr SEMICOLON
pub const Using = struct {
    is_public: bool = false,
    expr: Expr,

    pub fn format(self: Using, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.is_public) try writer.writeAll("pub ");
        try writer.print("usingnamespace {};", .{self.expr});
    }

    test {
        try testing.expectFmt("usingnamespace foo;", "{}", .{Using{
            .expr = Expr{ .raw = "foo" },
        }});
        try testing.expectFmt("pub usingnamespace foo;", "{}", .{Using{
            .is_public = true,
            .expr = Expr{ .raw = "foo" },
        }});
    }
};

// ContainerField <- doc_comment? KEYWORD_comptime? (IDENTIFIER COLON)? TypeExpr ByteAlign? (EQUAL Expr)?
pub const Field = struct {
    is_comptime: bool = false,
    /// Set `null` when inside a tuple.
    identifier: ?[]const u8,
    type: TypeExpr,
    alignment: ?Expr = null,
    assign: ?Expr = null,

    pub fn format(self: Field, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.is_comptime) try writer.writeAll("comptime ");
        if (self.identifier) |t| try writer.print("{s}: ", .{t});
        try writer.print("{}", .{self.type});
        if (self.alignment) |a| try writer.print(" {}", .{ByteAlign{ .expr = a }});
        if (self.assign) |t| try writer.print(" = {}", .{t});
    }

    test {
        try testing.expectFmt("comptime foo: bool = true", "{}", .{Field{
            .is_comptime = true,
            .identifier = "foo",
            .type = TypeExpr{ .temp = "bool" },
            .assign = Expr{ .raw = "true" },
        }});
        try testing.expectFmt("u8 align(4)", "{}", .{Field{
            .identifier = null,
            .type = TypeExpr{ .temp = "u8" },
            .alignment = Expr{ .raw = "4" },
        }});
    }
};

pub const Variable = struct {
    decl: Declaration,
    proto: Prototype,

    /// GlobalVarDecl <- VarDeclProto (EQUAL Expr)? SEMICOLON
    pub fn format(self: Variable, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.decl.assign) |t| {
            try writer.print("{}{} = {};", .{ self.decl, self.proto, t });
        } else {
            try writer.print("{}{};", .{ self.decl, self.proto });
        }
    }

    test {
        try testing.expectFmt("pub var foo: bool;", "{}", .{Variable{
            .decl = .{
                .is_public = true,
            },
            .proto = .{
                .is_mutable = true,
                .identifier = "foo",
                .type = TypeExpr{ .temp = "bool" },
            },
        }});
        try testing.expectFmt("const foo: bool = true;", "{}", .{Variable{
            .decl = .{
                .assign = Expr{ .raw = "true" },
            },
            .proto = .{
                .identifier = "foo",
                .type = TypeExpr{ .temp = "bool" },
            },
        }});
    }

    // doc_comment? KEYWORD_pub?
    // (KEYWORD_export / KEYWORD_extern STRINGLITERALSINGLE?)? KEYWORD_threadlocal? GlobalVarDecl
    pub const Declaration = struct {
        is_public: bool = false,
        specifier: ?Specifier = null,
        /// Thread local.
        is_local: bool = false,
        assign: ?Expr = null,

        pub const Specifier = union(enum) {
            @"export",
            @"extern": ?[]const u8,
        };

        pub fn format(self: Declaration, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            if (self.is_public) try writer.writeAll("pub ");
            if (self.specifier) |spec| switch (spec) {
                .@"export" => try writer.writeAll("export "),
                .@"extern" => |s| try writer.print("{} ", .{Extern{ .source = s }}),
            };
            if (self.is_local) try writer.writeAll("threadlocal ");
        }
    };

    test "Declaration" {
        try testing.expectFmt("pub export threadlocal ", "{}", .{Declaration{
            .is_public = true,
            .specifier = .@"export",
            .is_local = true,
        }});
    }

    // VarDeclProto <- (KEYWORD_const / KEYWORD_var) IDENTIFIER (COLON TypeExpr)? ByteAlign?
    pub const Prototype = struct {
        is_mutable: bool = false,
        identifier: []const u8,
        type: ?TypeExpr,
        alignment: ?Expr = null,

        pub fn format(self: Prototype, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            if (self.is_mutable) {
                try writer.print("var {s}", .{self.identifier});
            } else {
                try writer.print("const {s}", .{self.identifier});
            }
            if (self.type) |t| try writer.print(": {}", .{t});
            if (self.alignment) |a| try writer.print(" {}", .{ByteAlign{ .expr = a }});
        }
    };

    test "Prototype" {
        try testing.expectFmt("const foo", "{}", .{Prototype{
            .identifier = "foo",
            .type = null,
        }});

        try testing.expectFmt("var foo: Foo align(4)", "{}", .{Prototype{
            .is_mutable = true,
            .identifier = "foo",
            .type = TypeExpr{ .temp = "Foo" },
            .alignment = Expr{ .raw = "4" },
        }});
    }
};

pub const Function = struct {
    // doc_comment? KEYWORD_pub?
    // (KEYWORD_export / KEYWORD_extern STRINGLITERALSINGLE? / KEYWORD_inline / KEYWORD_noinline)?
    pub const Declaration = struct {
        is_public: bool = false,
        specifier: ?Specifier = null,

        pub const Specifier = union(enum) {
            @"export",
            @"extern": ?[]const u8,
            @"inline",
            @"noinline",
        };

        pub fn format(self: Declaration, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            if (self.is_public) try writer.writeAll("pub ");
            if (self.specifier) |spec| switch (spec) {
                .@"export" => try writer.writeAll("export "),
                .@"extern" => |s| try writer.print("{} ", .{Extern{ .source = s }}),
                .@"inline" => try writer.writeAll("inline "),
                .@"noinline" => try writer.writeAll("noinline "),
            };
        }
    };

    test "Declaration" {
        try testing.expectFmt("pub export ", "{}", .{Declaration{
            .is_public = true,
            .specifier = .@"export",
        }});
    }

    // FnProto <- KEYWORD_fn IDENTIFIER? LPAREN ParamDeclList RPAREN ByteAlign? CallConv? EXCLAMATIONMARK? TypeExpr
    // ParamDeclList <- (ParamDecl COMMA)* ParamDecl?
    // CallConv <- KEYWORD_callconv LPAREN Expr RPAREN
    // ParamDecl
    //     <- doc_comment? (KEYWORD_noalias / KEYWORD_comptime)? (IDENTIFIER COLON)? ParamType
    //      / DOT3
    // ParamType
    //     <- KEYWORD_anytype
    //      / TypeExpr
    pub const Prototype = struct {
        identifier: Identifier,
        parameters: []const Parameter,
        return_type: ?TypeExpr,
        alignment: ?Expr = null,
        call_conv: ?builtin.CallingConvention = null,

        pub fn format(self: Prototype, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            try writer.print("fn {}({}) ", .{ self.identifier, List(Parameter){ .items = self.parameters } });

            if (self.alignment) |a| try writer.print("{} ", .{ByteAlign{ .expr = a }});
            if (self.call_conv) |c| switch (c) {
                .Unspecified => {},
                inline else => |g| try writer.print("callconv(.{s}) ", .{@tagName(g)}),
            };

            if (self.return_type) |t| {
                try writer.print("{}", .{t});
            } else {
                try writer.writeAll("void");
            }
        }

        pub const Specifier = enum { none, @"noalias", @"comptime" };

        pub const Parameter = struct {
            specifier: Specifier = .none,
            identifier: ?Identifier,
            type: ?TypeExpr,

            pub fn format(self: Parameter, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
                switch (self.specifier) {
                    .none => {},
                    inline else => |g| try writer.print("{s} ", .{@tagName(g)}),
                }

                if (self.identifier) |i| {
                    try writer.print("{}: ", .{i});
                } else if (self.type == null) {
                    // C variadic functions
                    assert(self.specifier == .none);
                    return try writer.writeAll("...");
                } else {
                    try writer.writeAll("_: ");
                }

                if (self.type) |t| {
                    try writer.print("{}", .{t});
                } else {
                    try writer.writeAll("anytype");
                }
            }
        };
    };

    test "Prototype" {
        try testing.expectFmt("fn foo() void", "{}", .{Prototype{
            .identifier = Identifier{ .name = "foo" },
            .parameters = &.{},
            .return_type = null,
        }});
        try testing.expectFmt("fn foo(bar: bool, baz: anytype, _: bool) void", "{}", .{Prototype{
            .identifier = Identifier{ .name = "foo" },
            .parameters = &.{ .{
                .identifier = Identifier{ .name = "bar" },
                .type = TypeExpr{ .temp = "bool" },
            }, .{
                .identifier = Identifier{ .name = "baz" },
                .type = null,
            }, .{
                .identifier = null,
                .type = TypeExpr{ .temp = "bool" },
            } },
            .return_type = null,
        }});
        try testing.expectFmt("fn foo(...) callconv(.C) void", "{}", .{Prototype{
            .identifier = Identifier{ .name = "foo" },
            .parameters = &.{.{ .identifier = null, .type = null }},
            .call_conv = .C,
            .return_type = null,
        }});
        try testing.expectFmt("fn foo() align(4) void", "{}", .{Prototype{
            .identifier = Identifier{ .name = "foo" },
            .parameters = &.{},
            .alignment = Expr{ .raw = "4" },
            .return_type = null,
        }});
    }
};

pub const Scope = struct {
    writer: *StackWriter,
    options: Options,
    prfx: ?Prefix = null,
    consumed: bool = false,

    pub const Form = enum { block, inlined };

    pub const Decor = struct {
        label: ?Identifier = null,
        payload: []const Identifier = &.{},
    };

    pub const Prefix = union(enum) {
        comp,
        deferred,
        errdeferred: ?Identifier,
    };

    const Options = struct {
        form: Form,
        branching: bool = false,
        suffix: ?[]const u8 = null,
    };

    fn init(writer: *StackWriter, decor: Decor, options: Options) !Scope {
        const scope = try createSubWriter(writer, decor, options.form);
        return .{ .writer = scope, .options = options };
    }

    pub fn branch(self: *Scope, form: Form, decor: Decor, cond: ?Expr) !void {
        assert(self.options.branching);
        try self.writer.applyDeferred();
        const root_writer = self.writer.parent orelse unreachable;
        if (cond) |s| {
            try root_writer.writeFmt(" else if ({}) ", .{s});
        } else {
            try root_writer.writeAll(" else ");
            self.options.branching = false;
        }
        try writeDecor(root_writer, decor, form);
        switch (form) {
            .block => try writeBlock(self.writer),
            .inlined => self.consumed = false,
        }
        self.options.form = form;
    }

    pub fn end(self: Scope) !void {
        // We use defer in case other content deferred as well.
        if (self.options.form == .inlined) {
            assert(self.consumed);
            try self.writer.deferAll(.parent, self.options.suffix orelse ";");
        } else if (self.options.suffix) |s| {
            try self.writer.deferAll(.parent, s);
        }
        try self.writer.deinit();
    }

    fn createSubWriter(writer: *StackWriter, decor: Decor, form: Form) !*StackWriter {
        try writeDecor(writer, decor, form);
        const scope = try writer.appendPrefix(INDENT);
        if (form == .block) try writeBlock(scope);
        return scope;
    }

    fn writeDecor(root_writer: *StackWriter, decor: Decor, form: Form) !void {
        switch (decor.payload.len) {
            0 => {},
            1 => try root_writer.writeFmt("|{pre*}| ", .{decor.payload[0]}),
            else => try root_writer.writeFmt("|{pre*}| ", .{
                List(Identifier){ .items = decor.payload },
            }),
        }
        if (decor.label) |s| {
            assert(form == .block);
            try root_writer.writeFmt("{}: ", .{s});
        }
    }

    fn writeBlock(scope_writer: *StackWriter) !void {
        try scope_writer.parent.?.writeAll("{");
        try scope_writer.deferLineAll(.parent, "}");
    }

    fn preStatement(self: *Scope) !void {
        switch (self.options.form) {
            .block => try self.writer.lineBreak(1),
            .inlined => {
                assert(!self.consumed);
                self.consumed = true;
            },
        }

        if (self.prfx) |p| {
            switch (p) {
                .comp => try self.writer.writeAll("comptime "),
                .deferred => try self.writer.writeAll("defer "),
                .errdeferred => |t| if (t) |s| {
                    try self.writer.writeFmt("errdefer |{}| ", .{s});
                } else {
                    try self.writer.writeAll("errdefer ");
                },
            }
            self.prfx = null;
        }
    }

    fn postStatement(self: *Scope) !void {
        if (self.options.form == .block) try self.writer.writeByte(';');
    }

    fn postStatemntScope(self: *Scope, form: Form, decor: Decor) !Scope {
        return Scope.init(self.writer, decor, .{
            .form = form,
            .branching = true,
        });
    }

    fn statementAll(self: *Scope, bytes: []const u8) !void {
        try self.preStatement();
        try self.writer.writeAll(bytes);
        try self.postStatement();
    }

    fn statementFmt(self: *Scope, comptime format: []const u8, args: anytype) !void {
        try self.preStatement();
        try self.writer.writeFmt(format, args);
        try self.postStatement();
    }

    test {
        var buffer = std.ArrayList(u8).init(test_alloc);
        var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
        errdefer buffer.deinit();

        var scope = try Scope.init(&writer, .{
            .payload = &.{Identifier{ .name = "p8" }},
        }, .{
            .branching = true,
            .form = .inlined,
        });
        try scope.statementAll("foo()");
        try scope.branch(.block, .{
            .label = Identifier{ .name = "blk" },
        }, Expr{ .raw = "true" });
        try scope.statementFmt("bar0x{X}()", .{16});
        try scope.branch(.inlined, .{
            .payload = &.{
                Identifier{ .name = "p8" },
                Identifier{ .name = "p9" },
            },
        }, null);
        try scope.statementAll("baz()");
        try scope.end();

        try testing.expectEqualStrings(
            \\|p8| foo() else if (true) blk: {
            \\    bar0x10();
            \\} else |p8, p9| baz();
        , buffer.items);
        buffer.clearAndFree();

        scope = try Scope.init(&writer, .{}, .{
            .form = .block,
            .suffix = " // SUFFIX",
        });
        try scope.statementAll("foo()");
        try scope.end();
        try testing.expectEqualStrings(
            \\{
            \\    foo();
            \\} // SUFFIX
        , buffer.items);
        buffer.clearAndFree();

        scope = try Scope.init(&writer, .{}, .{
            .form = .inlined,
            .suffix = ",",
        });
        try scope.statementAll("foo()");
        try scope.end();
        try testing.expectEqualStrings("foo(),", buffer.items);
        buffer.deinit();
    }

    pub fn prefix(self: *Scope, p: Prefix) *Scope {
        assert(self.prfx == null);
        self.prfx = p;
        return self;
    }

    pub fn expression(self: *Scope, expr: Expr) !void {
        try self.statementFmt("{}", .{expr});
    }

    // Expr AssignOp Expr
    pub fn assign(self: *Scope, lhs: Identifier, op: AssignOp, rhs: Expr) !void {
        try self.statementFmt("{} {} {}", .{ lhs, op, rhs });
    }

    // Expr (COMMA Expr)+ EQUAL Expr
    // VarDeclExprStatement <- VarDeclProto (COMMA (VarDeclProto / Expr))* EQUAL Expr SEMICOLON
    /// Declare, assign, or destruct one or more variables.
    pub fn variable(self: *Scope, lhs: []const Assign, rhs: Expr) !void {
        try self.statementFmt("{} = {}", .{ List(Assign){ .items = lhs }, rhs });
    }

    pub fn block(self: *Scope, label: ?Identifier) !Scope {
        try self.preStatement();
        return Scope.init(self.writer, .{
            .label = label,
        }, .{ .form = .block });
    }

    test "expressions" {
        var buffer = std.ArrayList(u8).init(test_alloc);
        var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
        defer buffer.deinit();

        var scope = try Scope.init(&writer, .{}, .{ .form = .block });
        try scope.expression(.{ .raw = "foo()" });
        try scope.prefix(.deferred).assign(.{ .name = "foo" }, .plus_equal, .{ .raw = "bar" });
        try scope.prefix(.comp).variable(&.{
            .{ .unmut = .{ .name = "foo" } },
            .{ .mut = .{ .name = "bar" } },
            .{ .assign = .{ .name = "baz" } },
        }, .{ .raw = "qux" });

        var blk = try scope.prefix(.{ .errdeferred = .{ .name = "e" } }).block(null);
        try blk.expression(.{ .raw = "foo()" });
        try blk.end();

        try scope.end();
        try testing.expectEqualStrings(
            \\{
            \\    foo();
            \\    defer foo += bar;
            \\    comptime const foo, var bar, baz = qux;
            \\    errdefer |e| {
            \\        foo();
            \\    }
            \\}
        , buffer.items);
    }

    // IfStatement
    //     <- IfPrefix BlockExpr ( KEYWORD_else Payload? Statement )?
    //      / IfPrefix AssignExpr ( SEMICOLON / KEYWORD_else Payload? Statement )
    // PtrPayload <- PIPE ASTERISK? IDENTIFIER PIPE
    pub fn ifCtrl(self: *Scope, form: Form, p: IfPrefix, label: ?Identifier) !Scope {
        try self.preStatement();
        try self.writer.writeFmt("{} ", .{p});
        return self.postStatemntScope(form, .{ .label = label });
    }

    // ForStatement
    //     <- ForPrefix BlockExpr ( KEYWORD_else Statement )?
    //      / ForPrefix AssignExpr ( SEMICOLON / KEYWORD_else Statement )
    pub fn forLoop(self: *Scope, form: Form, p: ForPrefix) !Scope {
        try self.preStatement();
        try self.writer.writeFmt("{} ", .{p});
        return self.postStatemntScope(form, .{});
    }

    // WhileStatement
    //     <- WhilePrefix BlockExpr ( KEYWORD_else Payload? Statement )?
    //      / WhilePrefix AssignExpr ( SEMICOLON / KEYWORD_else Payload? Statement )
    pub fn whileLoop(self: *Scope, form: Form, p: WhilePrefix) !Scope {
        try self.preStatement();
        try self.writer.writeFmt("{} ", .{p});
        return self.postStatemntScope(form, .{});
    }

    pub fn switchCtrl(self: *Scope, subject: Expr) !SwitchExpr {
        try self.preStatement();
        return SwitchExpr.init(self.writer, subject);
    }

    test "control flow" {
        var buffer = std.ArrayList(u8).init(test_alloc);
        var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
        defer buffer.deinit();

        var scope = try Scope.init(&writer, .{}, .{ .form = .block });

        var blk = try scope.ifCtrl(.inlined, .{
            .condition = .{ .raw = "true" },
        }, null);
        try blk.expression(.{ .raw = "foo()" });
        try blk.end();

        blk = try scope.forLoop(.inlined, ForPrefix{
            .arguments = &.{
                .{ .single = Expr{ .raw = "foo" } },
                .{ .single = Expr{ .raw = "0.." } },
            },
            .payload = &.{ .{ .name = "f" }, .{ .name = "i" } },
        });
        try blk.expression(.{ .raw = "bar()" });
        try blk.end();

        blk = try scope.whileLoop(.inlined, WhilePrefix{
            .condition = .{ .raw = "foo" },
            .payload = .{ .name = "*f" },
            .@"continue" = .{ .raw = "i += 1" },
        });
        try blk.expression(.{ .raw = "bar()" });
        try blk.end();

        const expr = try scope.switchCtrl(.{ .raw = "foo" });
        blk = try expr.prongElse(.{}, .inlined);
        try blk.expression(.{ .raw = "bar()" });
        try blk.end();
        try expr.end();

        try scope.end();
        try testing.expectEqualStrings(
            \\{
            \\    if (true) foo();
            \\    for (foo, 0..) |f, i| bar();
            \\    while (foo) |*f| : (i += 1) bar();
            \\    switch (foo) {
            \\        else => bar(),
            \\    }
            \\}
        , buffer.items);
    }
};

// IfPrefix <- KEYWORD_if LPAREN Expr RPAREN PtrPayload?
pub const IfPrefix = struct {
    condition: Expr,
    payload: ?Identifier = null,

    pub fn format(self: IfPrefix, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.payload) |t| {
            try writer.print("if ({}) |{pre*}|", .{ self.condition, t });
        } else {
            try writer.print("if ({})", .{self.condition});
        }
    }

    test {
        try testing.expectFmt("if (foo) |f|", "{}", .{IfPrefix{
            .condition = .{ .raw = "foo" },
            .payload = Identifier{ .name = "f" },
        }});
    }
};

// ForPrefix <- KEYWORD_for LPAREN ForArgumentsList RPAREN PtrListPayload
// ForArgumentsList <- ForItem (COMMA ForItem)* COMMA?
// ForItem <- Expr (DOT2 Expr?)?
// PtrListPayload <- PIPE ASTERISK? IDENTIFIER (COMMA ASTERISK? IDENTIFIER)* COMMA? PIPE
pub const ForPrefix = struct {
    label: ?Identifier = null,
    inlined: bool = false,
    arguments: []const Item,
    payload: []const Identifier,

    pub fn format(self: ForPrefix, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        assert(self.arguments.len > 0);
        assert(self.payload.len > 0);
        if (self.label) |s| try writer.print("{}: ", .{s});
        if (self.inlined) try writer.writeAll("inline ");
        try writer.print("for ({}) |{pre*}|", .{
            List(Item){ .items = self.arguments },
            List(Identifier){ .items = self.payload },
        });
    }

    pub const Item = union(enum) {
        single: Expr,
        range: struct { Expr, ?Expr },

        pub fn format(self: Item, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            switch (self) {
                .single => |t| {
                    const depth = std.options.fmt_max_depth - 1;
                    try fmt.formatType(t, "", .{}, writer, depth);
                },
                .range => |t| if (t.@"1") |s| {
                    try writer.print("{}..{}", .{ t.@"0", s });
                } else {
                    try writer.print("{}..", .{t.@"0"});
                },
            }
        }
    };

    test {
        try testing.expectFmt("for (&foo) |*f|", "{}", .{ForPrefix{
            .arguments = &.{.{ .single = Expr{ .raw = "&foo" } }},
            .payload = &.{Identifier{ .name = "*f" }},
        }});
        try testing.expectFmt("for (foo, 0..) |f, i|", "{}", .{ForPrefix{
            .arguments = &.{
                .{ .single = Expr{ .raw = "foo" } },
                .{ .range = .{ Expr{ .raw = "0" }, null } },
            },
            .payload = &.{
                Identifier{ .name = "f" },
                Identifier{ .name = "i" },
            },
        }});
        try testing.expectFmt("foo: inline for (0..8) |i|", "{}", .{ForPrefix{
            .label = .{ .name = "foo" },
            .inlined = true,
            .arguments = &.{
                .{ .range = .{ Expr{ .raw = "0" }, Expr{ .raw = "8" } } },
            },
            .payload = &.{Identifier{ .name = "i" }},
        }});
    }
};

// WhilePrefix <- KEYWORD_while LPAREN Expr RPAREN PtrPayload? WhileContinueExpr?
// WhileContinueExpr <- COLON LPAREN AssignExpr RPAREN
// PtrPayload <- PIPE ASTERISK? IDENTIFIER PIPE
pub const WhilePrefix = struct {
    label: ?Identifier = null,
    inlined: bool = false,
    condition: Expr,
    payload: ?Identifier = null,
    @"continue": ?Expr = null,

    pub fn format(self: WhilePrefix, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.label) |s| try writer.print("{}: ", .{s});
        if (self.inlined) try writer.writeAll("inline ");
        try writer.print("while ({})", .{self.condition});
        if (self.payload) |t| try writer.print(" |{pre*}|", .{t});
        if (self.@"continue") |t| try writer.print(" : ({})", .{t});
    }

    test {
        try testing.expectFmt("foo: inline while (bar.next()) |*b| : (i += 1)", "{}", .{WhilePrefix{
            .label = .{ .name = "foo" },
            .inlined = true,
            .condition = Expr{ .raw = "bar.next()" },
            .payload = Identifier{ .name = "*b" },
            .@"continue" = Expr{ .raw = "i += 1" },
        }});
    }
};

// SwitchExpr <- KEYWORD_switch LPAREN Expr RPAREN LBRACE SwitchProngList RBRACE
// SwitchProngList <- (SwitchProng COMMA)* SwitchProng?
// SwitchProng <- KEYWORD_inline? SwitchCase EQUALRARROW PtrIndexPayload? SingleAssignExpr
// SwitchCase
//     <- SwitchItem (COMMA SwitchItem)* COMMA?
//      / KEYWORD_else
// SwitchItem <- Expr (DOT3 Expr)?
// PtrIndexPayload <- PIPE ASTERISK? IDENTIFIER (COMMA IDENTIFIER)? PIPE
// SingleAssignExpr <- Expr (AssignOp Expr)?
pub const SwitchExpr = struct {
    writer: *StackWriter,

    /// Call `end()` to complete the declaration.
    fn init(writer: *StackWriter, subject: Expr) !SwitchExpr {
        try writer.writeFmt("switch ({}) ", .{subject});
        const scope = try Scope.createSubWriter(writer, .{}, .block);
        return .{ .writer = scope };
    }

    pub fn end(self: SwitchExpr) !void {
        try self.writer.deinit();
    }

    /// Call `end()` to complete the block.
    pub fn prong(self: SwitchExpr, items: []const ProngItem, case: ProngCase, form: Scope.Form) !Scope {
        assert(items.len > 0);
        assert(case.payload.len <= 2);
        assert(!case.non_exhaustive);
        const list = List(ProngItem){ .items = items };
        if (case.@"inline") {
            try self.writer.lineFmt("inline {} => ", .{list});
        } else {
            try self.writer.lineFmt("{} => ", .{list});
        }
        return Scope.init(self.writer, case.decor(), .{
            .form = form,
            .suffix = ",",
        });
    }

    /// Call `end()` to complete the block.
    pub fn prongElse(self: SwitchExpr, case: ProngCase, form: Scope.Form) !Scope {
        assert(case.payload.len <= 2);
        const prefix = if (case.@"inline") "inline " else "";
        if (case.non_exhaustive) {
            try self.writer.lineFmt("{s}_ => ", .{prefix});
        } else {
            try self.writer.lineFmt("{s}else => ", .{prefix});
        }
        return Scope.init(self.writer, case.decor(), .{
            .form = form,
            .suffix = ",",
        });
    }

    pub const ProngItem = union(enum) {
        single: Expr,
        range: [2]Expr,

        pub fn format(self: ProngItem, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            switch (self) {
                .single => |s| try writer.print("{}", .{s}),
                .range => |r| try writer.print("{}...{}", .{ r[0], r[1] }),
            }
        }
    };

    pub const ProngCase = struct {
        @"inline": bool = false,
        non_exhaustive: bool = false,
        label: ?Identifier = null,
        payload: []const Identifier = &.{},

        fn decor(self: ProngCase) Scope.Decor {
            return .{
                .label = self.label,
                .payload = self.payload,
            };
        }
    };

    test {
        var buffer = std.ArrayList(u8).init(test_alloc);
        defer buffer.deinit();

        var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
        var expr = try SwitchExpr.init(&writer, Expr{ .raw = "foo" });

        var block = try expr.prong(&.{
            .{ .single = Expr{ .raw = ".foo" } },
        }, .{
            .@"inline" = true,
        }, .block);
        try block.expression(.{ .raw = "boom()" });
        try block.end();

        block = try expr.prong(&.{
            .{ .single = Expr{ .raw = ".bar" } },
            .{ .range = .{ Expr{ .raw = "4" }, Expr{ .raw = "8" } } },
        }, .{
            .label = Identifier{ .name = "blk" },
            .payload = &.{
                Identifier{ .name = "*a" },
                Identifier{ .name = "b" },
            },
        }, .block);
        try block.expression(.{ .raw = "break :blk yo()" });
        try block.end();

        block = try expr.prongElse(.{
            .@"inline" = true,
            .payload = &.{
                Identifier{ .name = "g" },
            },
        }, .inlined);
        try block.expression(.{ .raw = "boom()" });
        try block.end();

        try expr.end();
        try writer.deinit();
        try testing.expectEqualStrings(
            \\switch (foo) {
            \\    inline .foo => {
            \\        boom();
            \\    },
            \\    .bar, 4...8 => |*a, b| blk: {
            \\        break :blk yo();
            \\    },
            \\    inline else => |g| boom(),
            \\}
        , buffer.items);
    }
};

pub const Assign = union(enum) {
    unmut: Identifier,
    mut: Identifier,
    assign: Identifier,

    pub fn format(self: Assign, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .unmut => |t| try writer.print("const {}", .{t}),
            .mut => |t| try writer.print("var {}", .{t}),
            .assign => |t| try writer.print("{}", .{t}),
        }
    }
};

// ByteAlign <- KEYWORD_align LPAREN Expr RPAREN
const ByteAlign = struct {
    expr: Expr,

    pub fn format(self: ByteAlign, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try writer.print("align({})", .{self.expr});
    }

    test {
        try testing.expectFmt("align(4)", "{}", .{ByteAlign{
            .expr = Expr{ .raw = "4" },
        }});
    }
};

// KEYWORD_extern STRINGLITERALSINGLE?
const Extern = struct {
    source: ?[]const u8,

    pub fn format(self: Extern, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.source) |s| {
            try writer.print("extern \"{s}\"", .{s});
        } else {
            try writer.writeAll("extern");
        }
    }

    test {
        try testing.expectFmt("extern", "{}", .{Extern{ .source = null }});
        try testing.expectFmt("extern \"c\"", "{}", .{Extern{ .source = "c" }});
    }
};

const AssignOp = enum {
    // zig fmt: off
    asterisk_equal, asterisk_pipe_equal, slash_equal, percent_equal, plus_equal,
    plus_pipe_equal, minus_equal, minus_pipe_equal, larrow2_equal,
    larrow2_pipe_equal, rarrow2_equal, ampersand_equal, caret_equal, pipe_equal,
    asterisk_percent_equal, plus_percent_equal, minus_percent_equal, equal,
    // zig fmt: on

    pub fn format(self: AssignOp, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(switch (self) {
            .asterisk_equal => "*=",
            .asterisk_pipe_equal => "*|=",
            .slash_equal => "/=",
            .percent_equal => "%=",
            .plus_equal => "+=",
            .plus_pipe_equal => "+|=",
            .minus_equal => "-=",
            .minus_pipe_equal => "-|=",
            .larrow2_equal => "<<=",
            .larrow2_pipe_equal => "<<|=",
            .rarrow2_equal => ">>=",
            .ampersand_equal => "&=",
            .caret_equal => "^=",
            .pipe_equal => "|=",
            .asterisk_percent_equal => "*%=",
            .plus_percent_equal => "+%=",
            .minus_percent_equal => "-%=",
            .equal => "=",
        });
    }
};

/// For allowing a prefix character (e.g. `@`) use the `{pre@}` (replace `@`
/// with a desired character).
// IDENTIFIER
//     <- !keyword [A-Za-z_] [A-Za-z0-9_]* skip
//      / "@" STRINGLITERALSINGLE
// BUILTINIDENTIFIER <- "@"[A-Za-z_][A-Za-z0-9_]* skip
const Identifier = union(enum) {
    name: []const u8,
    lazy: *const LazyIdentifier,

    const Prefix = enum { builtin, ptr };

    pub fn format(self: Identifier, comptime fmt_spc: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        const allow_prefix = fmt_spc.len == 4 and std.mem.startsWith(u8, fmt_spc, "pre");
        const name = if (allow_prefix)
            self.resolveAllowPrefix(fmt_spc[3]) catch unreachable
        else
            self.resolve() catch unreachable;
        try writer.writeAll(name);
    }

    pub fn resolve(self: Identifier) ![]const u8 {
        const name = switch (self) {
            .name => |val| val,
            .lazy => |idn| try idn.resolve(),
        };

        try validate(name, null);
        return name;
    }

    pub fn resolveAllowPrefix(self: Identifier, prefix: u8) ![]const u8 {
        const name = switch (self) {
            .name => |val| val,
            .lazy => |idn| try idn.resolve(),
        };

        try validate(name, prefix);
        return name;
    }

    fn validate(value: []const u8, allow_prefix: ?u8) !void {
        if (value.len == 0) return error.EmptyIdentifier;

        const i: u8 = if (allow_prefix != null and value[0] == allow_prefix.?) 1 else 0;
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

        if (std.zig.Token.keywords.has(value)) {
            return error.ReservedIdentifier;
        }
    }

    test {
        try testing.expectError(error.EmptyIdentifier, Identifier.validate("", null));
        try testing.expectError(error.InvalidIdentifier, Identifier.validate("0foo", null));
        try testing.expectError(error.InvalidIdentifier, Identifier.validate("foo!", null));
        try testing.expectError(error.InvalidIdentifier, Identifier.validate("@foo", null));
        try testing.expectError(error.InvalidIdentifier, Identifier.validate("@0foo", '@'));
        try testing.expectError(error.ReservedIdentifier, Identifier.validate("return", null));
        try testing.expectEqual({}, Identifier.validate("foo0", null));
        try testing.expectEqual({}, Identifier.validate("@foo", '@'));

        var id = Identifier{ .name = "" };
        try testing.expectError(error.EmptyIdentifier, id.resolve());
        id = Identifier{ .name = "@foo" };
        try testing.expectError(error.InvalidIdentifier, id.resolve());
        id = Identifier{ .name = "return" };
        try testing.expectError(error.ReservedIdentifier, id.resolve());
        id = Identifier{ .name = "foo" };
        try testing.expectEqualDeep("foo", id.resolve());
        id = Identifier{ .name = "@foo" };
        try testing.expectEqualDeep("@foo", id.resolveAllowPrefix('@'));

        const lazy = LazyIdentifier{ .name = "bar" };
        id = lazy.identifier();
        try testing.expectEqualDeep("bar", id.resolve());

        try testing.expectFmt("foo", "{}", .{Identifier{ .name = "foo" }});
        try testing.expectFmt("@foo", "{pre@}", .{Identifier{ .name = "@foo" }});
    }
};

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

    test {
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
};

const Expr = union(enum) {
    raw: []const u8,
    // TODO
    temp_import: []const u8,

    pub fn format(self: Expr, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .raw => try writer.writeAll(self.raw),
            .temp_import => try writer.print("@import(\"{s}\")", .{self.temp_import}),
        }
    }
};

const TypeExpr = struct {
    temp: []const u8, // TODO

    pub fn format(self: TypeExpr, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(self.temp);
    }
};
