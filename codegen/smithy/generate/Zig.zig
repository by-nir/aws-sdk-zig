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
const JsonValue = @import("../utils/JsonReader.zig").Value;
const Markdown = @import("Markdown.zig");

// In general, a better approach would be to incorporate more of the Zig’s AST
// capabilities directly; but it seems to have expectaions and assumptions for
// an actual source. For now will stick with the current approach, but it’s
// worth looking into in the futrure.

const Container = @This();
pub const CommentLevel = enum { normal, doc, doc_top };

const INDENT = "    ";
pub const param_self = Function.Prototype.Parameter{
    .identifier = .{ .name = "self" },
    .type = .typ_This,
};
pub const param_self_ref = Function.Prototype.Parameter{
    .identifier = .{ .name = "self" },
    .type = .{
        .typ_pointer = .{ .type = &.typ_This },
    },
};
pub const param_self_mut = Function.Prototype.Parameter{
    .identifier = .{ .name = "self" },
    .type = .{
        .typ_pointer = .{ .mutable = true, .type = &.typ_This },
    },
};

writer: *StackWriter,
parent: ?*const Container,
section: Section = .none,
previous: Statements = .comptime_block,
imports: std.StringArrayHashMapUnmanaged(Identifier) = .{},

const Section = enum { none, fields, funcs };
const Statements = enum { comment, doc, test_block, comptime_block, declare, field, variable, function, using };

/// Call `end()` to complete the declaration and deinit.
pub fn init(writer: *StackWriter, parent: ?*const Container) !Container {
    return .{
        .parent = parent,
        .writer = if (parent == null) writer else blk: {
            try writer.writeAll("{\n");
            const scope = try writer.appendPrefix(INDENT);
            try scope.deferLineAll(.parent, "}");
            break :blk scope;
        },
    };
}

fn initDecl(writer: *StackWriter, parent: *const Container, identifier: Identifier, decl: ContainerDecl) !Container {
    if (decl.is_public) try writer.writeAll("pub ");
    try writer.writeFmt("const {} = {} {{\n", .{ identifier, decl });
    const scope = try writer.appendPrefix(INDENT);
    try scope.deferLineAll(.parent, "};");
    return .{ .parent = parent, .writer = scope };
}

pub fn deinit(self: *Container) void {
    self.dinitImports();
    self.writer.deinit();
    self.* = undefined;
}

/// Complete the declaration and deinit.
/// **This will also deinit the writer.**
pub fn end(self: *Container) !void {
    self.dinitImports();
    try self.writer.end();
    self.* = undefined;
}

fn dinitImports(self: *Container) void {
    const allocator = self.writer.allocator;
    for (self.imports.values()) |id| {
        allocator.free(id.name);
    }
    self.imports.deinit(allocator);
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
    std.mem.replaceScalar(u8, output, '-', '_');

    const id = Identifier{ .name = id_name };
    if (self.imports.count() == 0) {
        try self.writer.deferLineBreak(.self, 1);
    }
    try self.writer.deferLineFmt(.self, "{}", .{Variable{
        .decl = .{},
        .proto = .{
            .identifier = id,
        },
        .assign = Expr.call("@import", &.{Expr.val(rel_path)}),
    }});
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
    try testing.expectEqualDeep(Identifier{ .name = "_imp_baz_qux" }, child.import("baz-qux"));
    try testing.expectEqualDeep(Identifier{ .name = "_imp_std" }, child.import("std"));
    try child.end();

    try scope.end();
    try testing.expectEqualStrings(
        \\{
        \\
        \\
        \\    const _imp_baz_qux = @import("baz-qux");
        \\}
        \\
        \\const _imp_std = @import("std");
        \\const _imp_xx_foo_bar_zig = @import("../foo/bar.zig");
    , buffer.items);
}

pub fn field(self: *Container, f: Field) !?Identifier {
    switch (self.section) {
        .funcs => return error.FieldAfterFunction,
        .none => {
            self.section = .fields;
            try self.writer.writePrefix();
        },
        .fields => switch (self.previous) {
            .doc, .comment, .field => try self.writer.lineBreak(1),
            else => try self.writer.lineBreak(2),
        },
    }
    self.previous = .field;
    try self.writer.writeFmt("{},", .{f});
    return if (f.name) |id| Identifier{ .name = id } else null;
}

test "field" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    var scope = try init(&writer, null);

    const fld = Field{ .name = "foo", .type = Expr{ .raw = "u8" } };
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

pub fn variable(self: *Container, decl: Variable.Declaration, proto: Variable.Prototype, assign: ?Expr) !Identifier {
    if (self.section == .none) {
        self.section = .fields;
        try self.writer.writePrefix();
    } else switch (self.previous) {
        .doc, .comment, .variable, .using => try self.writer.lineBreak(1),
        else => try self.writer.lineBreak(2),
    }
    self.previous = .variable;
    try self.writer.writeFmt("{}", .{Variable{
        .decl = decl,
        .proto = proto,
        .assign = assign,
    }});
    return proto.identifier;
}

test "variable" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    var scope = try init(&writer, null);

    const proto = Variable.Prototype{
        .identifier = .{ .name = "foo" },
        .type = Expr.typ(bool),
    };
    _ = try scope.variable(.{}, proto, null);
    try testing.expectEqual(.fields, scope.section);

    _ = try scope.variable(.{}, proto, null);
    scope.previous = .doc;
    _ = try scope.variable(.{}, proto, null);
    scope.previous = .comment;
    _ = try scope.variable(.{}, proto, null);
    scope.previous = .using;
    _ = try scope.variable(.{}, proto, null);

    scope.previous = .comptime_block;
    _ = try scope.variable(.{}, proto, null);

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

pub fn declare(self: *Container, identifier: Identifier, decl: ContainerDecl) !Container {
    if (self.section == .none) {
        self.section = .fields;
        try self.writer.writePrefix();
    } else switch (self.previous) {
        .doc, .comment => try self.writer.lineBreak(1),
        else => try self.writer.lineBreak(2),
    }
    self.previous = .declare;
    return Container.initDecl(self.writer, self, identifier, decl);
}

test "declare" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    var scope = try init(&writer, null);

    var cnt = try scope.declare(.{ .name = "foo" }, .{ .type = .Opaque });
    _ = try cnt.field(.{ .name = "bar", .type = Expr.typ(bool) });
    _ = try cnt.field(.{ .name = "baz", .type = Expr.typ(bool) });
    try cnt.end();
    try testing.expectEqual(.fields, scope.section);

    cnt = try scope.declare(.{ .name = "foo" }, .{ .type = .Opaque });
    _ = try cnt.field(.{ .name = "bar", .type = Expr.typ(bool) });
    try cnt.end();

    scope.previous = .doc;
    cnt = try scope.declare(.{ .name = "foo" }, .{ .type = .Opaque });
    _ = try cnt.field(.{ .name = "bar", .type = Expr.typ(bool) });
    try cnt.end();

    scope.previous = .comment;
    cnt = try scope.declare(.{ .name = "foo" }, .{ .type = .Opaque });
    _ = try cnt.field(.{ .name = "bar", .type = Expr.typ(bool) });
    try cnt.end();

    try scope.end();
    try testing.expectEqualStrings(
        \\const foo = opaque {
        \\    bar: bool,
        \\    baz: bool,
        \\};
        \\
        \\const foo = opaque {
        \\    bar: bool,
        \\};
        \\const foo = opaque {
        \\    bar: bool,
        \\};
        \\const foo = opaque {
        \\    bar: bool,
        \\};
    , buffer.items);
}

pub fn using(self: *Container, decl: Using) !void {
    if (self.section == .none) {
        self.section = .fields;
        try self.writer.writePrefix();
    } else switch (self.previous) {
        .doc, .comment, .variable, .using => try self.writer.lineBreak(1),
        else => try self.writer.lineBreak(2),
    }
    self.previous = .using;
    try self.writer.writeFmt("{}", .{decl});
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
    if (self.section == .none) {
        try self.writer.writePrefix();
    } else switch (self.previous) {
        .doc, .comment => try self.writer.lineBreak(1),
        else => try self.writer.lineBreak(2),
    }

    try self.writer.writeFmt("{}{} ", .{ decl, proto });
    self.section = .funcs;
    return Scope.init(self.writer, .{}, .{ .form = .block }, self);
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
    try func.expr(.{ .raw = "bar()" });
    try func.end();

    try scope.end();
    try testing.expectEqualStrings("pub fn foo() void {\n    bar();\n}", buffer.items);
}

// TestDecl <- KEYWORD_test (STRINGLITERALSINGLE / IDENTIFIER)? Block
/// Call `end()` to complete the declaration.
pub fn testBlock(self: *Container, name: []const u8) !Scope {
    if (self.section == .none) {
        self.section = .fields;
        try self.writer.writePrefix();
    } else switch (self.previous) {
        .doc => return error.InvalidBlockAfterDoc,
        .comment => try self.writer.lineBreak(1),
        else => try self.writer.lineBreak(2),
    }
    self.previous = .test_block;
    if (name.len > 0) {
        try self.writer.writeFmt("test \"{s}\" ", .{name});
    } else {
        try self.writer.writeAll("test ");
    }
    return Scope.init(self.writer, .{}, .{ .form = .block }, self);
}

test "testBlock" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    var scope = try init(&writer, null);

    var block = try scope.testBlock("foo");
    try testing.expectEqual(.fields, scope.section);
    try block.expr(.{ .raw = "bar()" });
    try block.end();

    block = try scope.testBlock("");
    try block.expr(.{ .raw = "bar()" });
    try block.end();

    scope.previous = .comment;
    block = try scope.testBlock("foo");
    try block.expr(.{ .raw = "bar()" });
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
        try self.writer.writePrefix();
    } else switch (self.previous) {
        .doc => return error.InvalidBlockAfterDoc,
        .comment, .variable => try self.writer.lineBreak(1),
        else => try self.writer.lineBreak(2),
    }
    self.previous = .comptime_block;
    try self.writer.writeAll("comptime ");
    return Scope.init(self.writer, .{}, .{ .form = .block }, self);
}

test "comptimeBlock" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    var scope = try init(&writer, null);

    var block = try scope.comptimeBlock();
    try testing.expectEqual(.fields, scope.section);
    try block.expr(.{ .raw = "foo()" });
    try block.end();

    block = try scope.comptimeBlock();
    try block.expr(.{ .raw = "foo()" });
    try block.end();

    scope.previous = .comment;
    block = try scope.comptimeBlock();
    try block.expr(.{ .raw = "foo()" });
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
        try self.writer.writePrefix();
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

pub fn preRenderMultiline(
    self: *Container,
    allocator: Allocator,
    comptime T: type,
    items: []const T,
    pre_pad: []const u8,
    post_pad: []const u8,
) ![]const u8 {
    return renderMultilineList(allocator, T, items, .{
        .line_prefix = self.writer.options.line_prefix,
        .pad_pre = pre_pad,
        .pad_post = post_pad,
    });
}

test "preRenderMultiline" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();
    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    var scope = try Scope.init(&writer, .{}, .{ .form = .block }, undefined);

    const result = try scope.preRenderMultiline(test_alloc, []const u8, &.{
        "foo",
        "bar",
        "baz",
    }, ".{", "}");
    defer test_alloc.free(result);
    testing.expectEqualStrings(
        \\.{
        \\        foo,
        \\        bar,
        \\        baz,
        \\    }
    , result) catch |e| {
        try scope.end();
        return e;
    };

    try scope.end();
}

test {
    _ = LazyIdentifier;
    _ = Identifier;
    _ = ByteAlign;
    _ = Extern;

    _ = Expr;
    _ = ContainerDecl;

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
    name: ?[]const u8,
    type: ?Expr,
    alignment: ?Expr = null,
    assign: ?Expr = null,

    pub fn format(self: Field, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.is_comptime) try writer.writeAll("comptime ");
        if (self.name) |t| try writer.print("{s}", .{t});
        if (self.type) |t| if (self.name != null) {
            try writer.print(": {}", .{t});
        } else {
            try writer.print("{}", .{t});
        };
        if (self.alignment) |a| {
            std.debug.assert(self.type != null);
            try writer.print(" {}", .{ByteAlign{ .expr = a }});
        }
        if (self.assign) |t| try writer.print(" = {}", .{t});
    }

    test {
        try testing.expectFmt("comptime foo: bool = true", "{}", .{Field{
            .is_comptime = true,
            .name = "foo",
            .type = Expr.typ(bool),
            .assign = Expr.val(true),
        }});
        try testing.expectFmt("u8 align(4)", "{}", .{Field{
            .name = null,
            .type = Expr.typ(u8),
            .alignment = Expr.val(4),
        }});
    }
};

pub const Variable = struct {
    decl: Declaration,
    proto: Prototype,
    assign: ?Expr = null,

    /// GlobalVarDecl <- VarDeclProto (EQUAL Expr)? SEMICOLON
    pub fn format(self: Variable, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.assign) |t| {
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
                .identifier = .{ .name = "foo" },
                .type = Expr.typ(bool),
            },
        }});
        try testing.expectFmt("const foo: bool = true;", "{}", .{Variable{
            .decl = .{},
            .proto = .{
                .identifier = .{ .name = "foo" },
                .type = Expr.typ(bool),
            },
            .assign = Expr.val(true),
        }});
    }

    // doc_comment? KEYWORD_pub?
    // (KEYWORD_export / KEYWORD_extern STRINGLITERALSINGLE?)? KEYWORD_threadlocal? GlobalVarDecl
    pub const Declaration = struct {
        is_public: bool = false,
        specifier: ?Specifier = null,
        /// Thread local.
        is_local: bool = false,

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
        identifier: Identifier,
        type: ?Expr = null,
        alignment: ?Expr = null,

        pub fn format(self: Prototype, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            if (self.is_mutable) {
                try writer.print("var {}", .{self.identifier});
            } else {
                try writer.print("const {}", .{self.identifier});
            }
            if (self.type) |t| try writer.print(": {}", .{t});
            if (self.alignment) |a| try writer.print(" {}", .{ByteAlign{ .expr = a }});
        }
    };

    test "Prototype" {
        try testing.expectFmt("const foo", "{}", .{Prototype{
            .identifier = .{ .name = "foo" },
        }});

        try testing.expectFmt("var foo: Foo align(4)", "{}", .{Prototype{
            .is_mutable = true,
            .identifier = .{ .name = "foo" },
            .type = Expr{ .raw = "Foo" },
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
        return_type: ?Expr,
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
            type: ?Expr,

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
                .type = Expr.typ(bool),
            }, .{
                .identifier = Identifier{ .name = "baz" },
                .type = null,
            }, .{
                .identifier = null,
                .type = Expr.typ(bool),
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
    container: *const Container,

    pub const Form = enum { block, inlined };

    pub const Decor = struct {
        label: ?Identifier = null,
        payload: []const Identifier = &.{},
    };

    pub const Prefix = union(enum) {
        ret,
        comp,
        deferred,
        errdeferred: ?Identifier,
    };

    const Options = struct {
        form: Form,
        branching: bool = false,
        suffix: ?[]const u8 = null,
    };

    fn init(writer: *StackWriter, decor: Decor, options: Options, container: *const Container) !Scope {
        const scope = try createSubWriter(writer, decor, options.form);
        return .{
            .writer = scope,
            .options = options,
            .container = container,
        };
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
        try self.writer.end();
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
                .ret => try self.writer.writeAll("return "),
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
        }, self.container);
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
        }, undefined);
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
        }, undefined);
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
        }, undefined);
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

    pub fn expr(self: *Scope, ex: Expr) !void {
        try self.statementFmt("{}", .{ex});
    }

    pub fn exprFmt(self: *Scope, comptime format: []const u8, args: anytype) !void {
        try self.statementFmt(format, args);
    }

    // Expr AssignOp Expr
    pub fn assign(self: *Scope, lhs: Identifier, op: AssignOp, rhs: Expr) !void {
        try self.statementFmt("{} {} {}", .{ lhs, op, rhs });
    }

    // Expr (COMMA Expr)+ EQUAL Expr
    // VarDeclExprStatement <- VarDeclProto (COMMA (VarDeclProto / Expr))* EQUAL Expr SEMICOLON
    pub fn destruct(self: *Scope, lhs: []const Destruct, rhs: Expr) !void {
        try self.statementFmt("{} = {}", .{ List(Destruct){ .items = lhs }, rhs });
    }

    /// Call `end()` to complete the block.
    pub fn block(self: *Scope, label: ?Identifier) !Scope {
        try self.preStatement();
        return Scope.init(self.writer, .{
            .label = label,
        }, .{ .form = .block }, self.container);
    }

    /// Declare a container type.
    /// Call `end()` to complete the declaration.
    pub fn declare(self: *Scope, identifier: Identifier, decl: ContainerDecl) !Container {
        try self.writer.lineBreak(1);
        return Container.initDecl(self.writer, self.container, identifier, decl);
    }

    test "expressions" {
        var buffer = std.ArrayList(u8).init(test_alloc);
        var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
        defer buffer.deinit();

        const parent_container: *const Container = undefined;
        var scope = try Scope.init(&writer, .{}, .{ .form = .block }, parent_container);
        try scope.prefix(.deferred).assign(.{ .name = "foo" }, .plus_equal, .{ .raw = "bar" });
        try scope.prefix(.comp).destruct(&.{
            .{ .unmut = .{ .name = "foo" } },
            .{ .mut = .{ .name = "bar" } },
            .{ .assign = .{ .name = "baz" } },
        }, .{ .raw = "qux" });

        var blk = try scope.prefix(.{ .errdeferred = .{ .name = "e" } }).block(null);
        try blk.exprFmt("{s}()", .{"foo"});
        try blk.end();

        var cnt = try scope.declare(.{ .name = "foo" }, .{ .type = .Union });
        try testing.expectEqual(parent_container, cnt.parent.?);
        _ = try cnt.field(.{ .name = "bar", .type = Expr.typ(bool) });
        _ = try cnt.field(.{ .name = "baz", .type = Expr.typ(bool) });
        try cnt.end();

        try scope.prefix(.ret).expr(.{ .raw = "foo()" });

        try scope.end();
        try testing.expectEqualStrings(
            \\{
            \\    defer foo += bar;
            \\    comptime const foo, var bar, baz = qux;
            \\    errdefer |e| {
            \\        foo();
            \\    }
            \\    const foo = union {
            \\        bar: bool,
            \\        baz: bool,
            \\    };
            \\    return foo();
            \\}
        , buffer.items);
    }

    // IfStatement
    //     <- IfPrefix BlockExpr ( KEYWORD_else Payload? Statement )?
    //      / IfPrefix AssignExpr ( SEMICOLON / KEYWORD_else Payload? Statement )
    // PtrPayload <- PIPE ASTERISK? IDENTIFIER PIPE
    /// Call `end()` to complete the declaration.
    pub fn ifCtrl(self: *Scope, form: Form, p: IfPrefix, label: ?Identifier) !Scope {
        try self.preStatement();
        try self.writer.writeFmt("{} ", .{p});
        return self.postStatemntScope(form, .{ .label = label });
    }

    // ForStatement
    //     <- ForPrefix BlockExpr ( KEYWORD_else Statement )?
    //      / ForPrefix AssignExpr ( SEMICOLON / KEYWORD_else Statement )
    /// Call `end()` to complete the declaration.
    pub fn forLoop(self: *Scope, form: Form, p: ForPrefix) !Scope {
        try self.preStatement();
        try self.writer.writeFmt("{} ", .{p});
        return self.postStatemntScope(form, .{});
    }

    // WhileStatement
    //     <- WhilePrefix BlockExpr ( KEYWORD_else Payload? Statement )?
    //      / WhilePrefix AssignExpr ( SEMICOLON / KEYWORD_else Payload? Statement )
    /// Call `end()` to complete the declaration.
    pub fn whileLoop(self: *Scope, form: Form, p: WhilePrefix) !Scope {
        try self.preStatement();
        try self.writer.writeFmt("{} ", .{p});
        return self.postStatemntScope(form, .{});
    }

    /// Call `end()` to complete the declaration.
    pub fn switchCtrl(self: *Scope, subject: Expr) !SwitchExpr {
        try self.preStatement();
        return SwitchExpr.init(self.writer, subject, self.container);
    }

    test "control flow" {
        var buffer = std.ArrayList(u8).init(test_alloc);
        var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
        defer buffer.deinit();

        var scope = try Scope.init(&writer, .{}, .{ .form = .block }, undefined);

        var blk = try scope.ifCtrl(.inlined, .{
            .condition = .{ .raw = "true" },
        }, null);
        try blk.expr(.{ .raw = "foo()" });
        try blk.end();

        blk = try scope.forLoop(.inlined, ForPrefix{
            .arguments = &.{
                .{ .single = Expr{ .raw = "foo" } },
                .{ .single = Expr{ .raw = "0.." } },
            },
            .payload = &.{ .{ .name = "f" }, .{ .name = "i" } },
        });
        try blk.expr(.{ .raw = "bar()" });
        try blk.end();

        blk = try scope.whileLoop(.inlined, WhilePrefix{
            .condition = .{ .raw = "foo" },
            .payload = .{ .name = "*f" },
            .@"continue" = .{ .raw = "i += 1" },
        });
        try blk.expr(.{ .raw = "bar()" });
        try blk.end();

        const ex = try scope.switchCtrl(.{ .raw = "foo" });
        blk = try ex.prongElse(.{}, .inlined);
        try blk.expr(.{ .raw = "bar()" });
        try blk.end();
        try ex.end();

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

    pub fn preRenderMultiline(
        self: *Scope,
        allocator: Allocator,
        comptime T: type,
        items: []const T,
        pre_pad: []const u8,
        post_pad: []const u8,
    ) ![]const u8 {
        return renderMultilineList(allocator, T, items, .{
            .line_prefix = self.writer.options.line_prefix,
            .pad_pre = pre_pad,
            .pad_post = post_pad,
        });
    }

    test "preRenderMultiline" {
        var buffer = std.ArrayList(u8).init(test_alloc);
        defer buffer.deinit();
        var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
        var scope = try Scope.init(&writer, .{}, .{ .form = .block }, undefined);

        const result = try scope.preRenderMultiline(test_alloc, []const u8, &.{
            "foo",
            "bar",
            "baz",
        }, ".{", "}");
        defer test_alloc.free(result);
        testing.expectEqualStrings(
            \\.{
            \\        foo,
            \\        bar,
            \\        baz,
            \\    }
        , result) catch |e| {
            try scope.end();
            return e;
        };

        try scope.end();
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
    container: *const Container,

    /// Call `end()` to complete the declaration.
    fn init(writer: *StackWriter, subject: Expr, container: *const Container) !SwitchExpr {
        try writer.writeFmt("switch ({}) ", .{subject});
        const scope = try Scope.createSubWriter(writer, .{}, .block);
        return .{ .writer = scope, .container = container };
    }

    pub fn end(self: SwitchExpr) !void {
        try self.writer.end();
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
        }, self.container);
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
        }, self.container);
    }

    pub const ProngItem = union(enum) {
        expr: Expr,
        value: Identifier,
        range: [2]Expr,

        pub fn format(self: ProngItem, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            switch (self) {
                .expr => |s| try writer.print("{}", .{s}),
                .value => |s| try writer.print(".{}", .{s}),
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
        var expr = try SwitchExpr.init(&writer, Expr{ .raw = "foo" }, undefined);

        var block = try expr.prong(&.{
            .{ .expr = Expr{ .raw = ".foo" } },
        }, .{
            .@"inline" = true,
        }, .block);
        try block.expr(.{ .raw = "boom()" });
        try block.end();

        block = try expr.prong(&.{
            .{ .value = .{ .name = "bar" } },
            .{ .range = .{ Expr{ .raw = "4" }, Expr{ .raw = "8" } } },
        }, .{
            .label = Identifier{ .name = "blk" },
            .payload = &.{
                Identifier{ .name = "*a" },
                Identifier{ .name = "b" },
            },
        }, .block);
        try block.expr(.{ .raw = "break :blk yo()" });
        try block.end();

        block = try expr.prongElse(.{
            .@"inline" = true,
            .payload = &.{
                Identifier{ .name = "g" },
            },
        }, .inlined);
        try block.expr(.{ .raw = "boom()" });
        try block.end();

        try expr.end();
        try writer.end();
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

pub const Destruct = union(enum) {
    unmut: Identifier,
    mut: Identifier,
    assign: Identifier,

    pub fn format(self: Destruct, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
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
pub const Identifier = union(enum) {
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
            .name => |s| s,
            .lazy => |t| try t.resolve(),
        };

        try validate(name, null);
        return name;
    }

    pub fn resolveAllowPrefix(self: Identifier, prefix: u8) ![]const u8 {
        const name = switch (self) {
            .name => |s| s,
            .lazy => |t| try t.resolve(),
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

    pub fn child(self: Identifier, allocator: Allocator, rel: []const u8) ![]const u8 {
        const base = try self.resolve();
        return fmt.allocPrint(allocator, "{s}.{s}", .{ base, rel });
    }

    pub fn children(self: Identifier, allocator: Allocator, segments: []const []const u8) ![]const u8 {
        assert(segments.len > 0);
        const base = try self.resolve();
        return fmt.allocPrint(allocator, "{s}.{s}", .{
            base,
            List([]const u8){
                .items = segments,
                .delimiter = ".",
            },
        });
    }

    test "child/ren" {
        const base = Identifier{ .name = "foo" };

        const path_child = try base.child(test_alloc, "bar");
        defer test_alloc.free(path_child);
        try testing.expectEqualStrings("foo.bar", path_child);

        const path_children = try base.children(test_alloc, &.{ "bar", "baz" });
        defer test_alloc.free(path_children);
        try testing.expectEqualDeep("foo.bar.baz", path_children);
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

pub const Expr = union(enum) {
    raw: []const u8,
    raw_seq: []const []const u8,
    json: JsonValue,
    call: struct { identifier: []const u8, args: []const Expr },
    val_undefined,
    val_null,
    val_void,
    val_false,
    val_true,
    val_int: i64,
    val_uint: u64,
    val_float: f64,
    val_error: []const u8,
    val_enum: []const u8,
    /// Values: tag name, value. Use `Val.enm` for void payloads.
    val_union: [2][]const u8,
    val_string: []const u8,
    typ_This,
    typ_string,
    typ_optional: *const Expr,
    typ_array: struct { len: usize, type: *const Expr },
    typ_slice: struct { mutable: bool = false, type: *const Expr },
    typ_pointer: struct { mutable: bool = false, type: *const Expr },

    /// Assumes `args` is a list of `Val`s.
    pub fn call(identifier: []const u8, args: []const Expr) Expr {
        return .{ .call = .{ .identifier = identifier, .args = args } };
    }

    test "call" {
        try testing.expectEqualDeep(
            Expr{ .call = .{
                .identifier = "foo",
                .args = &.{ val(108), val("bar") },
            } },
            Expr.call("foo", &.{ val(108), val("bar") }),
        );
    }

    pub fn val(v: anytype) Expr {
        const T = @TypeOf(v);
        return if (T == []const u8)
            Expr{ .val_string = v }
        else switch (@typeInfo(T)) {
            .Bool => if (v) Expr.val_true else Expr.val_false,
            .Int => |t| switch (t.signedness) {
                .signed => Expr{ .val_int = v },
                .unsigned => Expr{ .val_uint = v },
            },
            .ComptimeInt => if (v < 0) Expr{ .val_int = v } else Expr{ .val_uint = v },
            .Float, .ComptimeFloat => Expr{ .val_float = v },
            .Enum, .EnumLiteral => Expr{ .val_enum = @tagName(v) },
            .Union => @compileError("Manually construct `Val.val_union` or `Val.val_raw` instead."),
            .ErrorSet => Expr{ .val_error = @errorName(v) },
            .ErrorUnion => |t| if (v) |s| switch (@typeInfo(t.payload)) {
                .Void => Expr.val_void,
                else => val(s),
            } else |e| Expr{ .val_error = @errorName(e) },
            .Optional => if (v) |s| val(s) else Expr.val_null,
            .Void => @compileError("Use `Expr.val_void` instead of `Expr.val(void)`."),
            .Null => @compileError("Use `Expr.val_null` instead of `Expr.val(null)`."),
            .Undefined => @compileError("Use `Expr.val_undefined` instead of `Expr.val(undefined)`."),
            .Pointer => |t| blk: {
                if (t.size == .Slice and t.child == u8) {
                    break :blk Expr{ .val_string = v };
                } else if (t.size == .One) {
                    const meta = @typeInfo(t.child);
                    if (meta == .Array and meta.Array.child == u8) {
                        break :blk Expr{ .val_string = v };
                    }
                }
                @compileError("Only string pointers can auto-covert into a value Expr.");
            },
            // Fn, Pointer, Array, Struct
            else => @compileError("Type `" ++ @typeName(T) ++ "` can’t auto-convert into a value Expr."),
        };
    }

    test "val" {
        try testing.expectEqualDeep(Expr.val_true, val(true));
        try testing.expectEqualDeep(Expr.val_false, val(false));
        try testing.expectEqualDeep(Expr{ .val_int = 108 }, val(@as(i8, 108)));
        try testing.expectEqualDeep(Expr{ .val_uint = 108 }, val(@as(u8, 108)));
        try testing.expectEqualDeep(Expr{ .val_int = -108 }, val(-108));
        try testing.expectEqualDeep(Expr{ .val_uint = 108 }, val(108));
        try testing.expectEqualDeep(Expr{ .val_float = 1.08 }, val(@as(f64, 1.08)));
        try testing.expectEqualDeep(Expr{ .val_float = 1.08 }, val(1.08));
        try testing.expectEqualDeep(Expr{ .val_enum = "foo" }, val(.foo));
        try testing.expectEqualDeep(
            Expr{ .val_error = "Foo" },
            val(@as(error{Foo}!void, error.Foo)),
        );
        try testing.expectEqualDeep(Expr.val_void, val(@as(error{Foo}!void, {})));
        try testing.expectEqualDeep(Expr{ .val_uint = 108 }, val(@as(error{Foo}!u8, 108)));
        try testing.expectEqualDeep(Expr{ .val_uint = 108 }, val(@as(?u8, 108)));
        try testing.expectEqualDeep(Expr.val_null, val(@as(?u8, null)));
        try testing.expectEqualDeep(Expr{ .val_string = "foo" }, val("foo"));
    }

    pub fn typ(comptime T: type) Expr {
        return .{ .raw = @typeName(T) };
    }

    test "typ" {
        try testing.expectEqualDeep(
            Expr{ .raw = "error{Foo}!*const []u8" },
            typ(error{Foo}!*const []u8),
        );
    }

    pub fn format(self: Expr, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .raw => try writer.writeAll(self.raw),
            .raw_seq => |t| for (t) |s| try writer.writeAll(s),
            .call => |t| try writer.print("{s}({})", .{
                t.identifier,
                List(Expr){ .items = t.args },
            }),
            .val_void => try writer.writeAll("{}"),
            inline .val_undefined, .val_null, .val_false, .val_true => |_, t| {
                const tag = @tagName(t);
                try writer.writeAll(tag[4..tag.len]);
            },
            inline .val_int, .val_uint, .val_float => |t| try writer.print("{d}", .{t}),
            .val_error => |s| try writer.print("error.{s}", .{s}),
            .val_enum => |s| try writer.print(".{s}", .{s}),
            .val_union => |t| try writer.print(".{{ .{s} = {s} }}", .{ t[0], t[1] }),
            .val_string => |s| try writer.print("\"{s}\"", .{s}),
            .typ_This => try writer.writeAll("@This()"),
            .typ_string => try writer.writeAll("[]const u8"),
            .typ_optional => |t| try writer.print("?{}", .{t}),
            .typ_array => |t| try writer.print("[{d}]{}", .{ t.len, t.type }),
            inline .typ_slice, .typ_pointer => |t, g| {
                try if (g == .typ_pointer) writer.writeByte('*') else writer.writeAll("[]");
                try if (t.mutable) writer.print("{}", .{t.type}) else writer.print("const {}", .{t.type});
            },
            .json => |json| switch (json) {
                .null => try writer.writeAll("null"),
                .boolean => |v| try writer.writeAll(if (v) "true" else "false"),
                inline .integer, .float => |v| try writer.print("{d}", .{v}),
                .string => |v| try writer.print("\"{s}\"", .{v}),
                .array => |items| {
                    try writer.writeAll(".{ ");
                    for (items, 0..) |item, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.print("{}", .{Expr{ .json = item }});
                    }
                    try writer.writeAll(" }");
                },
                // TODO: Respect new line prefix
                .object => |items| {
                    try writer.writeAll(".{");
                    for (items) |item| {
                        try writer.print(
                            "\n" ++ INDENT ++ ".{s} = {},",
                            .{ item.key, Expr{ .json = item.value } },
                        );
                    }
                    try writer.writeAll("\n}");
                },
            },
        }
    }

    test "format" {
        try testing.expectFmt("foo", "{}", .{Expr{ .raw = "foo" }});
        try testing.expectFmt("foobar", "{}", .{
            Expr{ .raw_seq = &.{ "foo", "bar" } },
        });

        try testing.expectFmt("{}", "{}", .{Expr{ .val_void = {} }});
        try testing.expectFmt("undefined", "{}", .{Expr{ .val_undefined = {} }});
        try testing.expectFmt("null", "{}", .{Expr{ .val_null = {} }});
        try testing.expectFmt("false", "{}", .{Expr{ .val_false = {} }});
        try testing.expectFmt("true", "{}", .{Expr{ .val_true = {} }});
        try testing.expectFmt("-108", "{}", .{Expr{ .val_int = -108 }});
        try testing.expectFmt("108", "{}", .{Expr{ .val_uint = 108 }});
        try testing.expectFmt("1.08", "{}", .{Expr{ .val_float = 1.08 }});
        try testing.expectFmt("error.Foo", "{}", .{Expr{ .val_error = "Foo" }});
        try testing.expectFmt(".foo", "{}", .{Expr{ .val_enum = "foo" }});
        try testing.expectFmt(".{ .foo = 108 }", "{}", .{Expr{ .val_union = .{ "foo", "108" } }});
        try testing.expectFmt("\"foo\"", "{}", .{Expr{ .val_string = "foo" }});

        try testing.expectFmt("foo()", "{}", .{
            Expr{ .call = .{ .identifier = "foo", .args = &.{} } },
        });
        try testing.expectFmt("foo(108, \"bar\")", "{}", .{Expr{
            .call = .{
                .identifier = "foo",
                .args = &.{ val(108), val("bar") },
            },
        }});

        try testing.expectFmt("?u8", "{}", .{Expr{ .typ_optional = &typ(u8) }});
        try testing.expectFmt("[2]u8", "{}", .{
            Expr{ .typ_array = .{ .len = 2, .type = &typ(u8) } },
        });
        try testing.expectFmt("[]const u8", "{}", .{
            Expr{ .typ_slice = .{ .type = &typ(u8) } },
        });
        try testing.expectFmt("[]u8", "{}", .{
            Expr{ .typ_slice = .{ .mutable = true, .type = &typ(u8) } },
        });
        try testing.expectFmt("*const u8", "{}", .{
            Expr{ .typ_pointer = .{ .type = &typ(u8) } },
        });
        try testing.expectFmt("*u8", "{}", .{
            Expr{ .typ_pointer = .{ .mutable = true, .type = &typ(u8) } },
        });

        try testing.expectFmt(
            \\.{ null, true, false, 108, 1.08, "foo", .{
            \\    .key1 = "bar",
            \\    .key2 = null,
            \\} }
        , "{}", .{Expr{
            .json = .{ .array = &.{
                .null,
                .{ .boolean = true },
                .{ .boolean = false },
                .{ .integer = 108 },
                .{ .float = 1.08 },
                .{ .string = "foo" },
                .{ .object = &.{
                    .{ .key = "key1", .value = .{ .string = "bar" } },
                    .{ .key = "key2", .value = .null },
                } },
            } },
        }});
    }
};

// ContainerDecl <- (KEYWORD_extern / KEYWORD_packed)? ContainerDeclType
// ContainerDeclType
//     <- KEYWORD_struct (LPAREN Expr RPAREN)?
//      / KEYWORD_opaque
//      / KEYWORD_enum (LPAREN Expr RPAREN)?
//      / KEYWORD_union (LPAREN (KEYWORD_enum (LPAREN Expr RPAREN)? / Expr) RPAREN)?
pub const ContainerDecl = struct {
    type: Type,
    is_public: bool = false,
    is_packed: bool = false,
    is_external: bool = false,

    pub fn format(self: ContainerDecl, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.is_external) try writer.writeAll("extern ");
        if (self.is_packed) try writer.writeAll("packed ");

        switch (self.type) {
            .Struct => |t| {
                try if (t) |s| writer.print("struct({})", .{s}) else try writer.writeAll("struct");
            },
            .Opaque => try writer.writeAll("opaque"),
            .Enum => |t| {
                try if (t) |s| writer.print("enum({})", .{s}) else writer.writeAll("enum");
            },
            .Union => try writer.writeAll("union"),
            .TaggedUnion => |t| {
                try if (t) |s| writer.print("union(enum {})", .{s}) else writer.writeAll("union(enum)");
            },
        }
    }

    const Type = union(enum) {
        Struct: ?Expr,
        Opaque,
        Enum: ?Expr,
        Union,
        TaggedUnion: ?Expr,
    };

    test {
        try testing.expectFmt("extern packed struct", "{}", .{ContainerDecl{
            .type = .{ .Struct = null },
            .is_packed = true,
            .is_external = true,
        }});
        try testing.expectFmt("struct(u24)", "{}", .{ContainerDecl{
            .type = .{ .Struct = .{ .raw = "u24" } },
        }});
        try testing.expectFmt("opaque", "{}", .{ContainerDecl{
            .type = .Opaque,
        }});
        try testing.expectFmt("enum", "{}", .{ContainerDecl{
            .type = .{ .Enum = null },
        }});
        try testing.expectFmt("enum(u16)", "{}", .{ContainerDecl{
            .type = .{ .Enum = .{ .raw = "u16" } },
        }});
        try testing.expectFmt("union", "{}", .{ContainerDecl{
            .type = .Union,
        }});
        try testing.expectFmt("union(enum)", "{}", .{ContainerDecl{
            .type = .{ .TaggedUnion = null },
        }});
        try testing.expectFmt("union(enum u16)", "{}", .{ContainerDecl{
            .type = .{ .TaggedUnion = .{ .raw = "u16" } },
        }});
    }
};

const MultilineOptions = struct {
    line_prefix: []const u8,
    pad_pre: []const u8 = "",
    pad_post: []const u8 = "",
};

fn renderMultilineList(
    allocator: Allocator,
    comptime T: type,
    items: []const T,
    options: MultilineOptions,
) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();
    var w = buffer.writer();
    try w.writeAll(options.pad_pre);
    const template = comptime if (T == []const u8) "\n{s}{s}{s}," else "\n{s}{s}{},";
    for (items) |item| {
        try w.print(template, .{ options.line_prefix, INDENT, item });
    }
    try w.print("\n{s}{s}", .{ options.line_prefix, options.pad_post });
    return try buffer.toOwnedSlice();
}

test "renderMultilineList" {
    const result = try renderMultilineList(test_alloc, []const u8, &.{
        "foo",
        "bar",
        "baz",
    }, .{
        .pad_pre = ".{",
        .pad_post = "}",
        .line_prefix = "//",
    });
    defer test_alloc.free(result);
    try testing.expectEqualStrings(
        \\.{
        \\//    foo,
        \\//    bar,
        \\//    baz,
        \\//}
    , result);
}
