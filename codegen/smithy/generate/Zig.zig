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

// In general, a better approach would be to incorporate more of the Zig’s AST
// capabilities directly; but it seems to have expectaions and assumptions for
// an actual source. For now will stick with the current approach, but it’s
// worth looking into in the futrure.

const INDENT = "    ";

const Self = @This();
const Content = enum(u8) {
    none = 0,
    fields = 2,
    declarations = 3,
};

container: Container,
allocator: Allocator,
imports: std.StringArrayHashMapUnmanaged(Identifier) = .{},
content: Content = .none,

/// `Root <- skip container_doc_comment? ContainerMembers eof`
pub fn init(allocator: Allocator, writer: *const StackWriter) !Self {
    return .{
        .allocator = allocator,
        // We don't use the `init()` method to avoid writing a struct declaration.
        .container = .{
            .allocator = allocator,
            .writer = writer,
        },
    };
}

pub fn deinit(self: *Self) void {
    self.imports.deinit(self.allocator);
    self.* = undefined;
}

pub fn import(self: *Self, rel_path: []const u8) !Identifier {
    const entry = try self.imports.getOrPut(rel_path);
    if (entry.found_existing) {
        return entry.value;
    } else {
        const rep = std.mem.replaceScalar(u8, rel_path, '.', '_');
        const id = try fmt.allocPrint(self.allocator, "_imp_{s}", .{rep});

        if (self.content == .none) self.content = .fields;
        try self.container.writer.lineFmt("const {s} = @import(\"{s}\");", .{ id, rel_path });

        entry.value_ptr.* = Identifier{ .name = id };
        return Identifier{ .name = id };
    }
}

pub fn field(self: *Self, f: Field) !void {
    if (self.content == .declarations) return error.FieldAfterFunction;
    self.content = .fields;
    try self.container.field(f);
}

pub fn variable(self: *Self, decl: Variable.Declaration, proto: Variable.Prototype) !void {
    if (self.content == .none) self.content = .fields;
    try self.container.variable(decl, proto);
}

pub fn function(self: *Self, decl: Function.Declaration, proto: Function.Prototype) !Function {
    self.content = .declarations;
    return self.container.function(decl, proto);
}

pub fn using(self: *Self, decl: Using) !void {
    if (self.content == .none) self.content = .fields;
    try self.container.using(decl);
}

/// Call `end()` to complete the declaration.
pub fn testBlock(self: *Self, name: ?Identifier) !Block {
    if (self.content == .none) self.content = .fields;
    return self.container.testBlock(name);
}

/// Call `end()` to complete the declaration.
pub fn comptimeBlock(self: *Self) !Block {
    if (self.content == .none) self.content = .fields;
    return self.container.comptimeBlock();
}

/// ```
/// ContainerMembers <- ContainerDeclaration* (ContainerField COMMA)* (ContainerField / ContainerDeclaration*)
/// ContainerField <- doc_comment? KEYWORD_comptime? !KEYWORD_fn (IDENTIFIER COLON)? TypeExpr ByteAlign? (EQUAL Expr)?
/// ContainerDeclaration <- TestDecl / ComptimeDecl / doc_comment? KEYWORD_pub? Decl
/// Decl
///     <- (KEYWORD_export / KEYWORD_extern STRINGLITERALSINGLE? / KEYWORD_inline / KEYWORD_noinline)? FnProto (SEMICOLON / Block)
///      / (KEYWORD_export / KEYWORD_extern STRINGLITERALSINGLE?)? KEYWORD_threadlocal? GlobalVarDecl
///      / KEYWORD_usingnamespace Expr SEMICOLON
/// GlobalVarDecl <- VarDeclProto (EQUAL Expr)? SEMICOLON
/// TestDecl <- KEYWORD_test (STRINGLITERALSINGLE / IDENTIFIER)? Block
/// ComptimeDecl <- KEYWORD_comptime Block
/// ```
pub const Container = struct {
    allocator: Allocator,
    writer: *const StackWriter,

    /// Call `end()` to complete the declaration.
    fn init(allocator: Allocator, writer: *const StackWriter) Container {
        try writer.writeAll("{");
        const scope = try writer.appendPrefix(allocator, INDENT);
        try scope.deferLine("}");

        return .{
            .allocator = allocator,
            .writer = scope,
        };
    }

    // `TestDecl <- KEYWORD_test (STRINGLITERALSINGLE / IDENTIFIER)? Block`
    /// Call `end()` to complete the declaration.
    pub fn testBlock(self: Container, name: ?Identifier) !Block {
        if (name) |s| {
            try self.writer.lineFmt("test \"{}\"", .{s});
        } else {
            try self.writer.lineAll("test");
        }
        return Block.init(self.allocator, self.writer, .{}, .{});
    }

    test "testBlock" {
        var list = std.ArrayList(u8).init(test_alloc);
        const writer = StackWriter.init(list.writer().any(), .{});
        defer list.deinit();

        const cont = Container{ .allocator = test_alloc, .writer = &writer };
        const block = try cont.testBlock(Identifier{ .name = "foo" });
        try block.statement(Statement{ .temp = "bar()" });
        try block.end();

        try testing.expectEqualStrings("\ntest \"foo\" {\n    bar();\n}", list.items);
    }

    // `ComptimeDecl <- KEYWORD_comptime Block`
    /// Call `end()` to complete the declaration.
    pub fn comptimeBlock(self: Container) !Block {
        try self.writer.lineAll("comptime");
        return Block.init(self.allocator, self.writer, .{}, .{});
    }

    test "comptimeBlock" {
        var list = std.ArrayList(u8).init(test_alloc);
        const writer = StackWriter.init(list.writer().any(), .{});
        defer list.deinit();

        const cont = Container{ .allocator = test_alloc, .writer = &writer };
        const block = try cont.comptimeBlock();
        try block.statement(Statement{ .temp = "foo()" });
        try block.end();

        try testing.expectEqualStrings("\ncomptime {\n    foo();\n}", list.items);
    }

    pub fn field(self: Container, f: Field) !void {
        try self.writer.lineFmt("{},", .{f});
    }

    pub fn variable(self: Container, decl: Variable.Declaration, proto: Variable.Prototype) !void {
        try self.writer.lineFmt("{}", .{Variable{
            .decl = decl,
            .proto = proto,
        }});
    }

    pub fn function(self: Container, decl: Function.Declaration, proto: Function.Prototype) !Function {
        return Function.init(self.allocator, self.writer, decl, proto);
    }

    pub fn using(self: Container, decl: Using) !void {
        try self.writer.lineFmt("{}", .{decl});
    }

    pub fn end(self: Function) !void {
        try self.writer.pop();
    }
};

// `doc_comment? KEYWORD_pub? KEYWORD_usingnamespace Expr SEMICOLON`
pub const Using = struct {
    is_public: bool = false,
    expr: Expr,

    pub fn format(self: Using, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.is_public) try writer.writeAll("pub ");
        try writer.print("usingnamespace {};", .{self.expr});
    }

    test {
        try testing.expectFmt("usingnamespace foo;", "{}", .{Using{
            .expr = Expr{ .temp = "foo" },
        }});
        try testing.expectFmt("pub usingnamespace foo;", "{}", .{Using{
            .is_public = true,
            .expr = Expr{ .temp = "foo" },
        }});
    }
};

/// `ContainerField <- doc_comment? KEYWORD_comptime? (IDENTIFIER COLON)? TypeExpr ByteAlign? (EQUAL Expr)?`
pub const Field = struct {
    is_comptime: bool = false,
    /// Set `null` when inside a tuple.
    identifier: ?Identifier,
    type: TypeExpr,
    alignment: ?Expr = null,
    assign: ?Expr = null,

    pub fn format(self: Field, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.is_comptime) try writer.writeAll("comptime ");
        if (self.identifier) |t| try writer.print("{}: ", .{t});
        try writer.print("{}", .{self.type});
        if (self.alignment) |a| try writer.print(" {}", .{ByteAlign{ .expr = a }});
        if (self.assign) |t| try writer.print(" = {}", .{t});
    }

    test {
        try testing.expectFmt("comptime foo: bool = true", "{}", .{Field{
            .is_comptime = true,
            .identifier = Identifier{ .name = "foo" },
            .type = TypeExpr{ .temp = "bool" },
            .assign = Expr{ .temp = "true" },
        }});
        try testing.expectFmt("u8 align(4)", "{}", .{Field{
            .identifier = null,
            .type = TypeExpr{ .temp = "u8" },
            .alignment = Expr{ .temp = "4" },
        }});
    }
};

/// `GlobalVarDecl <- VarDeclProto (EQUAL Expr)? SEMICOLON`
pub const Variable = struct {
    decl: Declaration,
    proto: Prototype,

    pub fn format(self: Variable, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.decl.assign) |t| {
            try writer.print("{}{} = {};", .{ self.decl, self.proto, t });
        } else {
            try writer.print("{}{};", .{ self.decl, self.proto });
        }
    }

    test {
        _ = Declaration;
        _ = Prototype;

        try testing.expectFmt("pub var foo: bool;", "{}", .{Variable{
            .decl = .{
                .is_public = true,
            },
            .proto = .{
                .is_mutable = true,
                .identifier = Identifier{ .name = "foo" },
                .type = TypeExpr{ .temp = "bool" },
            },
        }});

        try testing.expectFmt("const foo: bool = true;", "{}", .{Variable{
            .decl = .{
                .assign = Expr{ .temp = "true" },
            },
            .proto = .{
                .identifier = Identifier{ .name = "foo" },
                .type = TypeExpr{ .temp = "bool" },
            },
        }});
    }

    /// ```
    /// doc_comment? KEYWORD_pub?
    /// (KEYWORD_export / KEYWORD_extern STRINGLITERALSINGLE?)? KEYWORD_threadlocal? GlobalVarDecl
    /// ```
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

        test {
            try testing.expectFmt("pub export threadlocal ", "{}", .{Declaration{
                .is_public = true,
                .specifier = .@"export",
                .is_local = true,
            }});
        }
    };

    /// `VarDeclProto <- (KEYWORD_const / KEYWORD_var) IDENTIFIER (COLON TypeExpr)? ByteAlign?`
    pub const Prototype = struct {
        is_mutable: bool = false,
        identifier: Identifier,
        type: ?TypeExpr,
        alignment: ?Expr = null,

        pub fn format(self: Prototype, comptime fmt_spc: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            if (self.is_mutable) {
                try writer.print("var {" ++ fmt_spc ++ "}", .{self.identifier});
            } else {
                try writer.print("const {" ++ fmt_spc ++ "}", .{self.identifier});
            }
            if (self.type) |t| try writer.print(": {}", .{t});
            if (self.alignment) |a| try writer.print(" {}", .{ByteAlign{ .expr = a }});
        }

        test {
            try testing.expectFmt("const foo", "{}", .{Prototype{
                .identifier = Identifier{ .name = "foo" },
                .type = null,
            }});

            try testing.expectFmt("var foo: Foo align(4)", "{}", .{Prototype{
                .is_mutable = true,
                .identifier = Identifier{ .name = "foo" },
                .type = TypeExpr{ .temp = "Foo" },
                .alignment = Expr{ .temp = "4" },
            }});
        }
    };
};

pub const Function = struct {
    allocator: Allocator,
    writer: *const StackWriter,

    fn init(allocator: Allocator, writer: *const StackWriter, decl: Declaration, proto: Prototype) !Function {
        try writer.lineFmt("{}", .{decl});
        try proto.write(writer);
        const scope = try Block.createScope(allocator, writer, .{});
        return .{
            .allocator = allocator,
            .writer = scope,
        };
    }

    pub fn statement(self: Function, s: Statement) !void {
        try self.writer.lineFmt("{};", .{s});
    }

    pub fn end(self: Function) !void {
        _ = try self.writer.pop();
    }

    test {
        _ = Declaration;
        _ = Prototype;

        var list = std.ArrayList(u8).init(test_alloc);
        const writer = StackWriter.init(list.writer().any(), .{});
        defer list.deinit();

        const func = try Function.init(test_alloc, &writer, .{
            .is_public = true,
        }, .{
            .identifier = Identifier{ .name = "foo" },
            .parameters = &.{},
            .return_type = null,
        });
        try func.statement(Statement{ .temp = "bar()" });
        try func.end();

        try testing.expectEqualStrings("\npub fn foo() void {\n    bar();\n}", list.items);
    }

    /// ```
    /// doc_comment? KEYWORD_pub?
    /// (KEYWORD_export / KEYWORD_extern STRINGLITERALSINGLE? / KEYWORD_inline / KEYWORD_noinline)?
    /// ```
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

        test {
            try testing.expectFmt("pub export ", "{}", .{Declaration{
                .is_public = true,
                .specifier = .@"export",
            }});
        }
    };

    /// ```
    /// FnProto <- KEYWORD_fn IDENTIFIER? LPAREN ParamDeclList RPAREN ByteAlign? CallConv? EXCLAMATIONMARK? TypeExpr
    /// ParamDeclList <- (ParamDecl COMMA)* ParamDecl?
    /// CallConv <- KEYWORD_callconv LPAREN Expr RPAREN
    /// ParamDecl
    ///     <- doc_comment? (KEYWORD_noalias / KEYWORD_comptime)? (IDENTIFIER COLON)? ParamType
    ///      / DOT3
    /// ParamType
    ///     <- KEYWORD_anytype
    ///      / TypeExpr
    /// ```
    pub const Prototype = struct {
        identifier: Identifier,
        parameters: []const Parameter,
        return_type: ?TypeExpr,
        alignment: ?Expr = null,
        call_conv: ?builtin.CallingConvention = null,

        fn write(self: Prototype, writer: *const StackWriter) !void {
            try writer.writeFmt("fn {}(", .{self.identifier});
            try writer.writeList(Parameter, self.parameters, .{});
            try writer.writeAll(") ");

            if (self.alignment) |a| try writer.writeFmt("{} ", .{ByteAlign{ .expr = a }});
            if (self.call_conv) |c| switch (c) {
                .Unspecified => {},
                inline else => |g| try writer.writeFmt("callconv(.{s}) ", .{@tagName(g)}),
            };

            if (self.return_type) |t| {
                try writer.writeFmt("{}", .{t});
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

        test {
            var list = std.ArrayList(u8).init(test_alloc);
            const writer = StackWriter.init(list.writer().any(), .{});
            errdefer list.deinit();

            try (Prototype{
                .identifier = Identifier{ .name = "foo" },
                .parameters = &.{},
                .return_type = null,
            }).write(&writer);
            try testing.expectEqualStrings("fn foo() void", list.items);
            list.clearAndFree();

            try (Prototype{
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
            }).write(&writer);
            try testing.expectEqualStrings("fn foo(bar: bool, baz: anytype, _: bool) void", list.items);
            list.clearAndFree();

            try (Prototype{
                .identifier = Identifier{ .name = "foo" },
                .parameters = &.{.{ .identifier = null, .type = null }},
                .call_conv = .C,
                .return_type = null,
            }).write(&writer);
            try testing.expectEqualStrings("fn foo(...) callconv(.C) void", list.items);
            list.clearAndFree();

            try (Prototype{
                .identifier = Identifier{ .name = "foo" },
                .parameters = &.{},
                .alignment = Expr{ .temp = "4" },
                .return_type = null,
            }).write(&writer);
            try testing.expectEqualStrings("fn foo() align(4) void", list.items);
            list.clearAndFree();
        }
    };
};

/// ```
/// IfStatement
///     <- IfPrefix BlockExpr ( KEYWORD_else Payload? Statement )?
///      / IfPrefix AssignExpr ( SEMICOLON / KEYWORD_else Payload? Statement )
/// IfPrefix <- KEYWORD_if LPAREN Expr RPAREN PtrPayload?
/// PtrPayload <- PIPE ASTERISK? IDENTIFIER PIPE
/// ```
pub const IfStatement = struct {
    allocator: Allocator,
    writer: *const StackWriter,

    pub const Prefix = struct {
        condition: Expr,
        payload: ?Identifier = null,

        pub fn format(self: Prefix, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            if (self.payload) |t| {
                try writer.print("if ({}) |{pre*}|", .{ self.condition, t });
            } else {
                try writer.print("if ({})", .{self.condition});
            }
        }
    };

    fn init(allocator: Allocator, writer: *const StackWriter, prefix: Prefix) !IfStatement {
        try writer.writeFmt("{}", .{prefix});
        return .{
            .allocator = allocator,
            .writer = writer,
        };
    }

    pub fn block(self: IfStatement, label: ?Identifier) !Block {
        return Block.init(self.allocator, self.writer, .{
            .label = label,
        }, .{
            .branching = .else_if,
            .payload = .single,
            .label = true,
        });
    }

    /// Call `assignElse()` or `assignEnd()` to complete the declaration.
    pub fn assign(self: IfStatement, expr: AssignExpr) !void {
        try self.writer.writeByte(' ');
        try expr.write(self.writer);
    }

    /// Don’t call both `assignElse()` and `assignEnd()`.
    pub fn assignElse(self: IfStatement, statement: Statement, payload: ?Identifier) !void {
        if (payload) |t| {
            try self.writer.prefixedFmt(" else |{}| {}", .{ t, statement });
        } else {
            try self.writer.prefixedFmt(" else {}", .{statement});
        }
    }

    /// Don’t call both `assignElse()` and `assignEnd()`.
    pub fn assignEnd(self: IfStatement) !void {
        try self.writer.writeByte(';');
    }

    test "block" {
        var list = std.ArrayList(u8).init(test_alloc);
        const writer = StackWriter.init(list.writer().any(), .{});
        defer list.deinit();

        const ifs = try IfStatement.init(test_alloc, &writer, .{
            .condition = Expr{ .temp = "true" },
            .payload = Identifier{ .name = "_" },
        });
        var blk = try ifs.block(Identifier{ .name = "blk" });
        try blk.statement(Statement{ .temp = "break :blk foo()" });
        blk = try blk.branchElse(.{});
        try blk.statement(Statement{ .temp = "bar()" });
        try blk.end();

        try testing.expectEqualStrings(
            "if (true) |_| blk: {\n    break :blk foo();\n} else {\n    bar();\n}",
            list.items,
        );
    }

    test "assign" {
        var list = std.ArrayList(u8).init(test_alloc);
        const writer = StackWriter.init(list.writer().any(), .{});
        defer list.deinit();

        const ifs = try IfStatement.init(test_alloc, &writer, .{
            .condition = Expr{ .temp = "true" },
            .payload = Identifier{ .name = "_" },
        });
        try ifs.assign(AssignExpr{ .expr = Expr{ .temp = "i++" } });
        try ifs.assignEnd();

        try testing.expectEqualStrings(
            "if (true) |_| i++;",
            list.items,
        );
    }

    test "assign else" {
        var list = std.ArrayList(u8).init(test_alloc);
        const writer = StackWriter.init(list.writer().any(), .{});
        defer list.deinit();

        const ifs = try IfStatement.init(test_alloc, &writer, .{
            .condition = Expr{ .temp = "true" },
            .payload = Identifier{ .name = "_" },
        });
        try ifs.assign(AssignExpr{ .expr = Expr{ .temp = "i++" } });
        try ifs.assignElse(Statement{ .temp = "{}" }, null);

        try testing.expectEqualStrings(
            "if (true) |_| i++ else {}",
            list.items,
        );
    }
};

/// ```
/// ForStatement
///     <- ForPrefix BlockExpr ( KEYWORD_else Statement )?
///      / ForPrefix AssignExpr ( SEMICOLON / KEYWORD_else Statement )
/// ForPrefix <- KEYWORD_for LPAREN ForArgumentsList RPAREN PtrListPayload
/// ForArgumentsList <- ForItem (COMMA ForItem)* COMMA?
/// ForItem <- Expr (DOT2 Expr?)?
/// PtrListPayload <- PIPE ASTERISK? IDENTIFIER (COMMA ASTERISK? IDENTIFIER)* COMMA? PIPE
/// ```
pub const ForStatement = struct {
    allocator: Allocator,
    writer: *const StackWriter,

    fn init(allocator: Allocator, writer: *const StackWriter, prefix: Prefix) !ForStatement {
        try prefix.write(writer);
        return .{
            .allocator = allocator,
            .writer = writer,
        };
    }

    pub fn block(self: ForStatement) !Block {
        return Block.init(self.allocator, self.writer, .{}, .{
            .branching = .else_if,
            .payload = .single,
            .label = true,
        });
    }

    /// Call `assignElse()` or `assignEnd()` to complete the declaration.
    pub fn assign(self: ForStatement, expr: AssignExpr) !void {
        try self.writer.writeByte(' ');
        try expr.write(self.writer);
    }

    /// Don’t call both `assignElse()` and `assignEnd()`.
    pub fn assignElse(self: ForStatement, statement: Statement) !void {
        try self.writer.prefixedFmt(" else {}", .{statement});
    }

    /// Don’t call both `assignElse()` and `assignEnd()`.
    pub fn assignEnd(self: ForStatement) !void {
        try self.writer.writeByte(';');
    }

    test "block" {
        var list = std.ArrayList(u8).init(test_alloc);
        const writer = StackWriter.init(list.writer().any(), .{});
        defer list.deinit();

        const ifs = try ForStatement.init(test_alloc, &writer, Prefix{
            .arguments = &.{.{ .single = Expr{ .temp = "foo" } }},
            .payload = &.{Identifier{ .name = "f" }},
        });
        var blk = try ifs.block();
        try blk.statement(Statement{ .temp = "bar()" });
        blk = try blk.branchElse(.{});
        try blk.statement(Statement{ .temp = "baz()" });
        try blk.end();

        try testing.expectEqualStrings(
            "for (foo) |f| {\n    bar();\n} else {\n    baz();\n}",
            list.items,
        );
    }

    test "assign" {
        var list = std.ArrayList(u8).init(test_alloc);
        const writer = StackWriter.init(list.writer().any(), .{});
        defer list.deinit();

        const ifs = try ForStatement.init(test_alloc, &writer, Prefix{
            .arguments = &.{.{ .single = Expr{ .temp = "foo" } }},
            .payload = &.{Identifier{ .name = "f" }},
        });
        try ifs.assign(AssignExpr{ .expr = Expr{ .temp = "i++" } });
        try ifs.assignEnd();

        try testing.expectEqualStrings(
            "for (foo) |f| i++;",
            list.items,
        );
    }

    test "assign else" {
        var list = std.ArrayList(u8).init(test_alloc);
        const writer = StackWriter.init(list.writer().any(), .{});
        defer list.deinit();

        const ifs = try ForStatement.init(test_alloc, &writer, Prefix{
            .arguments = &.{.{ .single = Expr{ .temp = "foo" } }},
            .payload = &.{Identifier{ .name = "f" }},
        });
        try ifs.assign(AssignExpr{ .expr = Expr{ .temp = "i++" } });
        try ifs.assignElse(Statement{ .temp = "{}" });

        try testing.expectEqualStrings(
            "for (foo) |f| i++ else {}",
            list.items,
        );
    }

    pub const Prefix = struct {
        arguments: []const ForItem,
        payload: []const Identifier = &.{},

        fn write(self: Prefix, writer: *const StackWriter) !void {
            assert(self.arguments.len > 0);
            try writer.writeAll("for (");
            try writer.writeList(ForItem, self.arguments, .{});
            try writer.writeAll(") |");
            try writer.writeList(Identifier, self.payload, .{ .item_format = "pre*" });
            try writer.writeByte('|');
        }
    };

    pub const ForItem = union(enum) {
        single: Expr,
        range: struct { Expr, ?Expr },

        pub fn format(self: ForItem, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            switch (self) {
                .single => |t| {
                    const depth = std.options.fmt_max_depth - 1;
                    try fmt.formatType(t, "", .{}, writer, depth);
                },
                .range => |t| if (t.@"1") |end| {
                    try writer.print("{}..{}", .{ t.@"0", end });
                } else {
                    try writer.print("{}..", .{t.@"0"});
                },
            }
        }
    };

    test "Prefix" {
        var list = std.ArrayList(u8).init(test_alloc);
        const writer = StackWriter.init(list.writer().any(), .{});
        defer list.deinit();

        try (Prefix{
            .arguments = &.{.{ .single = Expr{ .temp = "&foo" } }},
            .payload = &.{Identifier{ .name = "*f" }},
        }).write(&writer);
        try testing.expectEqualStrings("for (&foo) |*f|", list.items);
        list.clearAndFree();

        try (Prefix{
            .arguments = &.{
                .{ .single = Expr{ .temp = "foo" } },
                .{ .range = .{ Expr{ .temp = "0" }, null } },
            },
            .payload = &.{
                Identifier{ .name = "f" },
                Identifier{ .name = "i" },
            },
        }).write(&writer);
        try testing.expectEqualStrings("for (foo, 0..) |f, i|", list.items);
        list.clearAndFree();

        try (Prefix{
            .arguments = &.{
                .{ .range = .{ Expr{ .temp = "0" }, Expr{ .temp = "8" } } },
            },
            .payload = &.{Identifier{ .name = "i" }},
        }).write(&writer);
        try testing.expectEqualStrings("for (0..8) |i|", list.items);
    }
};

/// ```
/// WhileStatement
///     <- WhilePrefix BlockExpr ( KEYWORD_else Payload? Statement )?
///      / WhilePrefix AssignExpr ( SEMICOLON / KEYWORD_else Payload? Statement )
/// WhilePrefix <- KEYWORD_while LPAREN Expr RPAREN PtrPayload? WhileContinueExpr?
/// PtrPayload <- PIPE ASTERISK? IDENTIFIER PIPE
/// WhileContinueExpr <- COLON LPAREN AssignExpr RPAREN
/// ```
const WhileStatement = struct {
    allocator: Allocator,
    writer: *const StackWriter,

    pub const Prefix = struct {
        condition: Expr,
        payload: ?Identifier = null,
        @"continue": ?AssignExpr = null,

        pub fn write(self: Prefix, writer: *const StackWriter) !void {
            try writer.writeFmt("while ({})", .{self.condition});
            if (self.payload) |t| try writer.writeFmt(" |{pre*}|", .{t});
            if (self.@"continue") |t| {
                try writer.writeAll(" : (");
                try t.write(writer);
                try writer.writeByte(')');
            }
        }
    };

    test "Prefix" {
        var list = std.ArrayList(u8).init(test_alloc);
        const writer = StackWriter.init(list.writer().any(), .{});
        defer list.deinit();

        try (Prefix{
            .condition = Expr{ .temp = "foo.next()" },
            .payload = Identifier{ .name = "*bar" },
            .@"continue" = AssignExpr{ .expr = Expr{ .temp = "i++" } },
        }).write(&writer);
        try testing.expectEqualStrings("while (foo.next()) |*bar| : (i++)", list.items);
    }

    fn init(allocator: Allocator, writer: *const StackWriter, prefix: Prefix) !WhileStatement {
        try prefix.write(writer);
        return .{
            .allocator = allocator,
            .writer = writer,
        };
    }

    pub fn block(self: WhileStatement, label: ?Identifier) !Block {
        return Block.init(self.allocator, self.writer, .{
            .label = label,
        }, .{
            .branching = .else_if,
            .payload = .single,
            .label = true,
        });
    }

    /// Call `assignElse()` or `assignEnd()` to complete the declaration.
    pub fn assign(self: WhileStatement, expr: AssignExpr) !void {
        try self.writer.writeByte(' ');
        try expr.write(self.writer);
    }

    /// Don’t call both `assignElse()` and `assignEnd()`.
    pub fn assignElse(self: WhileStatement, statement: Statement, payload: ?Identifier) !void {
        if (payload) |t| {
            try self.writer.prefixedFmt(" else |{}| {}", .{ t, statement });
        } else {
            try self.writer.prefixedFmt(" else {}", .{statement});
        }
    }

    /// Don’t call both `assignElse()` and `assignEnd()`.
    pub fn assignEnd(self: WhileStatement) !void {
        try self.writer.writeByte(';');
    }

    test "block" {
        var list = std.ArrayList(u8).init(test_alloc);
        const writer = StackWriter.init(list.writer().any(), .{});
        defer list.deinit();

        const ifs = try WhileStatement.init(test_alloc, &writer, .{
            .condition = Expr{ .temp = "true" },
            .payload = Identifier{ .name = "_" },
            .@"continue" = AssignExpr{ .expr = Expr{ .temp = "i++" } },
        });
        var blk = try ifs.block(null);
        try blk.statement(Statement{ .temp = "break" });
        blk = try blk.branchElse(.{});
        try blk.statement(Statement{ .temp = "foo()" });
        try blk.end();

        try testing.expectEqualStrings(
            "while (true) |_| : (i++) {\n    break;\n} else {\n    foo();\n}",
            list.items,
        );
    }

    test "assign" {
        var list = std.ArrayList(u8).init(test_alloc);
        const writer = StackWriter.init(list.writer().any(), .{});
        defer list.deinit();

        const ifs = try WhileStatement.init(test_alloc, &writer, .{
            .condition = Expr{ .temp = "true" },
            .payload = Identifier{ .name = "_" },
        });
        try ifs.assign(AssignExpr{ .expr = Expr{ .temp = "i++" } });
        try ifs.assignEnd();

        try testing.expectEqualStrings(
            "while (true) |_| i++;",
            list.items,
        );
    }

    test "assign else" {
        var list = std.ArrayList(u8).init(test_alloc);
        const writer = StackWriter.init(list.writer().any(), .{});
        defer list.deinit();

        const ifs = try WhileStatement.init(test_alloc, &writer, .{
            .condition = Expr{ .temp = "true" },
            .payload = Identifier{ .name = "_" },
        });
        try ifs.assign(AssignExpr{ .expr = Expr{ .temp = "i++" } });
        try ifs.assignElse(Statement{ .temp = "{}" }, null);

        try testing.expectEqualStrings(
            "while (true) |_| i++ else {}",
            list.items,
        );
    }
};

/// ```
/// SwitchExpr <- KEYWORD_switch LPAREN Expr RPAREN LBRACE SwitchProngList RBRACE
/// SwitchProngList <- (SwitchProng COMMA)* SwitchProng?
/// SwitchProng <- KEYWORD_inline? SwitchCase EQUALRARROW PtrIndexPayload? SingleAssignExpr
/// SwitchCase
///     <- SwitchItem (COMMA SwitchItem)* COMMA?
///      / KEYWORD_else
/// SwitchItem <- Expr (DOT3 Expr)?
/// PtrIndexPayload <- PIPE ASTERISK? IDENTIFIER (COMMA IDENTIFIER)? PIPE
/// SingleAssignExpr <- Expr (AssignOp Expr)?
/// ```
const SwitchExpr = struct { // TODO: Replace REMOVE_*
    expr: Expr,
    prongs: []const SwitchProng,

    pub fn format(self: SwitchExpr, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.prongs.len == 0) {
            return writer.print("switch ({s}) {{}}", .{self.expr});
        } else {
            try writer.print("switch ({s}) {{\n", .{self.expr});
            try REMOVE_renderList(SwitchProng, self.prongs, .{
                .multiline = REMOVE_INDENT_SIZE,
            }, .{}, writer);
            try writer.writeAll("\n}");
        }
    }

    pub const SwitchProng = struct {
        @"inline": bool = false,
        case: SwitchCase,
        payload: []const Identifier = &.{},
        expr: Expr, // TODO: SingleAssignExpr <- Expr (AssignOp Expr)?

        pub fn format(self: SwitchProng, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            if (self.@"inline") try writer.writeAll("inline ");
            switch (self.payload.len) {
                0 => try writer.print("{} => {}", .{ self.case, self.expr }),
                1 => try writer.print("{} => |{pre*}| {}", .{ self.case, self.payload[0], self.expr }),
                2 => try writer.print("{} => |{pre*}, {}| {}", .{ self.case, self.payload[0], self.payload[1], self.expr }),
                else => unreachable,
            }
        }
    };

    pub const SwitchCase = union(enum) {
        items: []const SwitchItem,
        @"else",
        /// Non-exhaustive enum `_`
        else_non_exhaustive,

        pub fn format(self: SwitchCase, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            switch (self) {
                .items => |c| try REMOVE_renderList(SwitchItem, c, .single, .{}, writer),
                .@"else" => try writer.writeAll("else"),
                .else_non_exhaustive => try writer.writeAll("_"),
            }
        }
    };

    pub const SwitchItem = union(enum) {
        single: Expr,
        range: [2]Expr,

        pub fn format(self: SwitchItem, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            switch (self) {
                .single => |s| try writer.print("{}", .{s}),
                .range => |r| try writer.print("{}...{}", .{ r[0], r[1] }),
            }
        }
    };

    test {
        try testing.expectFmt("switch (<expr>) {}", "{}", .{
            SwitchExpr{
                .expr = Expr{ .temp = "<expr>" },
                .prongs = &.{},
            },
        });

        try testing.expectFmt(
            \\switch (<expr>) {
            \\    inline .foo => {},
            \\    .bar, 4...8 => |*a, b| {},
            \\    else => {},
            \\    _ => {},
            \\}
        , "{}", .{
            SwitchExpr{
                .expr = Expr{ .temp = "<expr>" },
                .prongs = &.{
                    .{
                        .@"inline" = true,
                        .case = .{ .items = &.{
                            .{ .single = Expr{ .temp = ".foo" } },
                        } },
                        .expr = Expr{ .temp = "{}" },
                    },
                    .{
                        .case = .{ .items = &.{
                            .{ .single = Expr{ .temp = ".bar" } },
                            .{ .range = .{ Expr{ .temp = "4" }, Expr{ .temp = "8" } } },
                        } },
                        .payload = &.{
                            Identifier{ .name = "*a" },
                            Identifier{ .name = "b" },
                        },
                        .expr = Expr{ .temp = "{}" },
                    },
                    .{
                        .case = .@"else",
                        .expr = Expr{ .temp = "{}" },
                    },
                    .{
                        .case = .else_non_exhaustive,
                        .expr = Expr{ .temp = "{}" },
                    },
                },
            },
        });
    }
};

pub const Block = struct {
    allocator: Allocator,
    writer: *const StackWriter,
    options: BranchOptions,

    pub const Decor = struct {
        label: ?Identifier = null,
        payload: []const Identifier = &.{},
    };

    const Branching = enum { none, @"else", else_if };
    const Payload = enum { none, single, multi };
    const BranchOptions = struct {
        branching: Branching = .none,
        label: bool = false,
        payload: Payload = .none,
    };

    fn init(allocator: Allocator, writer: *const StackWriter, decor: Decor, options: BranchOptions) !Block {
        const scope = try createScope(allocator, writer, decor);
        return .{
            .allocator = allocator,
            .writer = scope,
            .options = options,
        };
    }

    /// Calling this method is instead of calling `end()`.
    pub fn branchElseIf(self: Block, expr: Expr, decor: Decor) !Block {
        assert(self.options.branching == .else_if);
        assert(decor.label == null or self.options.label);
        assert(self.options.payload == .none or
            (decor.payload.len <= 1 and self.options.payload == .single) or
            self.options.payload == .multi);
        const writer = try self.writer.pop();
        try writer.writeFmt(" else if ({})", .{expr});
        const scope = try createScope(self.allocator, writer, decor);
        return .{
            .allocator = self.allocator,
            .writer = scope,
            .options = self.options,
        };
    }

    /// Calling this method is instead of calling `end()`.
    pub fn branchElse(self: Block, decor: Decor) !Block {
        assert(self.options.branching != .none);
        assert(decor.label == null or self.options.label);
        assert(self.options.payload == .none or
            (decor.payload.len <= 1 and self.options.payload == .single) or
            self.options.payload == .multi);
        const writer = try self.writer.pop();
        try writer.writeAll(" else");
        const scope = try createScope(self.allocator, writer, decor);
        return .{
            .allocator = self.allocator,
            .writer = scope,
            .options = .{}, // Default options prevent another branch
        };
    }

    pub fn statement(self: Block, s: Statement) !void {
        try self.writer.lineFmt("{};", .{s});
    }

    pub fn end(self: Block) !void {
        _ = try self.writer.pop();
    }

    /// ```
    /// BlockExpr <- BlockLabel? Block
    /// BlockLabel <- IDENTIFIER COLON
    /// Block <- LBRACE Statement* RBRACE
    /// ```
    fn createScope(allocator: Allocator, writer: *const StackWriter, decor: Decor) !*const StackWriter {
        switch (decor.payload.len) {
            0 => {},
            1 => try writer.writeFmt(" |{pre*}|", .{decor.payload[0]}),
            else => {
                try writer.writeAll(" |");
                try writer.writeList(Identifier, decor.payload, .{
                    .item_format = "pre*",
                });
                try writer.writeByte('|');
            },
        }
        if (decor.label) |t| try writer.writeFmt(" {}:", .{t});
        try writer.writeAll(" {");
        const scope = try writer.appendPrefix(allocator, INDENT);
        try scope.deferLine("}");
        return scope;
    }

    test {
        var list = std.ArrayList(u8).init(test_alloc);
        const writer = StackWriter.init(list.writer().any(), .{});
        defer list.deinit();

        var block = try Block.init(test_alloc, &writer, .{
            .payload = &.{Identifier{ .name = "p8" }},
        }, .{
            .label = true,
            .payload = .multi,
            .branching = .else_if,
        });
        try block.statement(Statement{ .temp = "foo()" });
        block = try block.branchElseIf(Expr{ .temp = "true" }, .{
            .label = Identifier{ .name = "blk" },
        });
        try block.statement(Statement{ .temp = "bar()" });
        block = try block.branchElse(.{
            .label = Identifier{ .name = "blk" },
            .payload = &.{
                Identifier{ .name = "p8" },
                Identifier{ .name = "p9" },
            },
        });
        try block.statement(Statement{ .temp = "baz()" });
        try block.end();

        try testing.expectEqualStrings(
            \\ |p8| {
            \\    foo();
            \\} else if (true) blk: {
            \\    bar();
            \\} else |p8, p9| blk: {
            \\    baz();
            \\}
        , list.items);
    }
};

/// `ByteAlign <- KEYWORD_align LPAREN Expr RPAREN`
const ByteAlign = struct {
    expr: Expr,

    pub fn format(self: ByteAlign, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try writer.print("align({})", .{self.expr});
    }

    test {
        try testing.expectFmt("align(4)", "{}", .{ByteAlign{
            .expr = Expr{ .temp = "4" },
        }});
    }
};

/// `KEYWORD_extern STRINGLITERALSINGLE?`
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

/// `AssignExpr <- Expr (AssignOp Expr / (COMMA Expr)+ EQUAL Expr)?`
pub const AssignExpr = struct {
    lhs: Lhs = .none,
    expr: Expr,

    pub const Lhs = union(enum) {
        none,
        op: struct { Expr, AssignOp },
        destruct: []const Expr,
    };

    fn write(self: AssignExpr, writer: *const StackWriter) !void {
        switch (self.lhs) {
            .none => try writer.writeFmt("{}", .{self.expr}),
            .op => |t| try writer.writeFmt(
                "{} {s} {}",
                .{ t.@"0", t.@"1".resolve(), self.expr },
            ),
            .destruct => |exprs| {
                try writer.writeList(Expr, exprs, .{});
                try writer.writeFmt(" = {}", .{self.expr});
            },
        }
    }

    test {
        var list = std.ArrayList(u8).init(test_alloc);
        const writer = StackWriter.init(list.writer().any(), .{});
        defer list.deinit();

        try (AssignExpr{
            .expr = Expr{ .temp = "foo" },
        }).write(&writer);
        try testing.expectEqualStrings("foo", list.items);
        list.clearAndFree();

        try (AssignExpr{
            .lhs = .{ .op = .{
                Expr{ .temp = "foo" },
                .plus_equal,
            } },
            .expr = Expr{ .temp = "bar" },
        }).write(&writer);
        try testing.expectEqualStrings("foo += bar", list.items);
        list.clearAndFree();

        try (AssignExpr{
            .lhs = .{ .destruct = &.{
                Expr{ .temp = "const foo" },
                Expr{ .temp = "const bar" },
            } },
            .expr = Expr{ .temp = "baz" },
        }).write(&writer);
        try testing.expectEqualStrings("const foo, const bar = baz", list.items);
    }
};

const AssignOp = enum {
    // zig fmt: off
    asterisk_equal, asterisk_pipe_equal, slash_equal, percent_equal, plus_equal,
    plus_pipe_equal, minus_equal, minus_pipe_equal, larrow2_equal,
    larrow2_pipe_equal, rarrow2_equal, ampersand_equal, caret_equal, pipe_equal,
    asterisk_percent_equal, plus_percent_equal, minus_percent_equal, equal,
    // zig fmt: on

    pub fn resolve(self: AssignOp) []const u8 {
        return switch (self) {
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
        };
    }
};

/// For allowing a prefix character (e.g. `@`) use the `{pre@}` (replace `@`
/// with a desired character).
///
/// ```
/// IDENTIFIER
///     <- !keyword [A-Za-z_] [A-Za-z0-9_]* skip
///      / "@" STRINGLITERALSINGLE
/// BUILTINIDENTIFIER <- "@"[A-Za-z_][A-Za-z0-9_]* skip
/// ```
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

test {
    _ = LazyIdentifier;
    _ = Identifier;
    _ = AssignExpr;
    _ = ByteAlign;
    _ = Extern;
    _ = Block;

    _ = Field;
    _ = Using;
    _ = Variable;
    _ = Function;
    _ = Container;

    _ = IfStatement;
    _ = ForStatement;
    _ = WhileStatement;
    _ = SwitchExpr;
}

const Statement = struct {
    temp: []const u8, // TODO

    pub fn format(self: Statement, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(self.temp);
    }
};

const Expr = struct {
    temp: []const u8, // TODO

    pub fn format(self: Expr, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(self.temp);
    }
};

const TypeExpr = struct {
    temp: []const u8, // TODO

    pub fn format(self: TypeExpr, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(self.temp);
    }
};
