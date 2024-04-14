const std = @import("std");
const fmt = std.fmt;
const builtin = std.builtin;
const ZigType = builtin.Type;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;

const INDENT_SIZE = 4;

// In general, a better approach would be to incorporate more of the Zig’s AST
// capabilities directly; but it seems to have expectaions and assumptions for
// an actual source. For now will stick with the current approach, but it’s
// worth looking into in the futrure.

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
const FnProto = struct {
    identifier: Identifier,
    parameters: []const Parameter,
    return_type: ?TypeExpr,
    alignment: ?Expr = null,
    call_conv: ?builtin.CallingConvention = null,

    pub fn format(self: FnProto, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try writer.print("fn {}(", .{self.identifier});
        try renderList(Parameter, self.parameters, .single, .{}, writer);
        try writer.writeAll(") ");

        if (self.alignment) |a| {
            try renderByteAlign(a, writer);
        }

        if (self.call_conv) |c| switch (c) {
            .Unspecified => {},
            inline else => |g| try writer.print("callconv(.{s}) ", .{@tagName(g)}),
        };

        if (self.return_type) |t| {
            try fmt.formatType(t, "", .{}, writer, std.options.fmt_max_depth - 1);
        } else {
            try writer.writeAll("void");
        }
    }

    pub const Specifier = enum { none, @"noalias", @"comptime" };

    pub const Parameter = struct {
        // TODO: doc: ?Comment = null,
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

test "FnProto" {
    try testing.expectFmt("fn foo() void", "{}", .{
        FnProto{
            .identifier = Identifier{ .name = "foo" },
            .parameters = &.{},
            .return_type = null,
        },
    });
    try testing.expectFmt("fn foo(bar: bool, baz: anytype, _: bool) void", "{}", .{
        FnProto{
            .identifier = Identifier{ .name = "foo" },
            .parameters = &.{
                .{
                    .identifier = Identifier{ .name = "bar" },
                    .type = TypeExpr{ .temp = "bool" },
                },
                .{
                    .identifier = Identifier{ .name = "baz" },
                    .type = null,
                },
                .{
                    .identifier = null,
                    .type = TypeExpr{ .temp = "bool" },
                },
            },
            .return_type = null,
        },
    });
    try testing.expectFmt("fn foo(...) callconv(.C) void", "{}", .{
        FnProto{
            .identifier = Identifier{ .name = "foo" },
            .parameters = &.{
                .{ .identifier = null, .type = null },
            },
            .call_conv = .C,
            .return_type = null,
        },
    });
    try testing.expectFmt("fn foo() align(4) void", "{}", .{
        FnProto{
            .identifier = Identifier{ .name = "foo" },
            .parameters = &.{},
            .alignment = Expr{ .temp = "4" },
            .return_type = null,
        },
    });
}

/// ```
/// IfStatement
///     <- IfPrefix BlockExpr ( KEYWORD_else Payload? Statement )?
///      / IfPrefix AssignExpr ( SEMICOLON / KEYWORD_else Payload? Statement )
/// IfPrefix <- KEYWORD_if LPAREN Expr RPAREN PtrPayload?
/// PtrPayload <- PIPE ASTERISK? IDENTIFIER PIPE
/// ```
const IfStatement = struct {
    prefix: Prefix,
    body: ControlBody,
    @"else": ?Else = null,

    pub fn format(self: IfStatement, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.@"else") |t| switch (self.body) {
            inline else => |b| if (t.payload) |s| {
                try writer.print("{} {} else |{}| {}", .{ self.prefix, b, s, t.statement });
            } else {
                try writer.print("{} {} else {}", .{ self.prefix, b, t.statement });
            },
        } else switch (self.body) {
            .block => |t| try writer.print("{} {}", .{ self.prefix, t }),
            .assign => |t| try writer.print("{} {};", .{ self.prefix, t }),
        }
    }

    pub const Else = struct {
        payload: ?Identifier = null,
        statement: Statement,
    };

    pub const Prefix = struct {
        expr: Expr,
        payload: ?Identifier = null,

        pub fn format(self: Prefix, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            if (self.payload) |t| {
                try writer.print("if ({}) |{pre*}|", .{ self.expr, t });
            } else {
                try writer.print("if ({})", .{self.expr});
            }
        }
    };
};

test "IfStatement" {
    try testing.expectFmt("if (true)", "{}", .{IfStatement.Prefix{
        .expr = Expr{ .temp = "true" },
    }});
    try testing.expectFmt("if (foo.next()) |*bar|", "{}", .{IfStatement.Prefix{
        .expr = Expr{ .temp = "foo.next()" },
        .payload = Identifier{ .name = "*bar" },
    }});

    try testing.expectFmt("if (true) {}", "{}", .{
        IfStatement{
            .prefix = .{ .expr = Expr{ .temp = "true" } },
            .body = .{ .block = BlockExpr{ .statements = &.{} } },
        },
    });
    try testing.expectFmt("if (true) {} else {}", "{}", .{
        IfStatement{
            .prefix = .{ .expr = Expr{ .temp = "true" } },
            .body = .{ .block = BlockExpr{ .statements = &.{} } },
            .@"else" = .{ .statement = Statement{ .temp = "{}" } },
        },
    });

    try testing.expectFmt("if (true) i++ else |foo| { _ = foo; }", "{}", .{
        IfStatement{
            .prefix = .{ .expr = Expr{ .temp = "true" } },
            .body = .{ .assign = .{ .expr = Expr{ .temp = "i++" } } },
            .@"else" = .{
                .payload = Identifier{ .name = "foo" },
                .statement = Statement{ .temp = "{ _ = foo; }" },
            },
        },
    });
    try testing.expectFmt("if (true) i++;", "{}", .{
        IfStatement{
            .prefix = .{ .expr = Expr{ .temp = "true" } },
            .body = .{ .assign = .{ .expr = Expr{ .temp = "i++" } } },
        },
    });
    try testing.expectFmt("if (true) i++ else foo();", "{}", .{
        IfStatement{
            .prefix = .{ .expr = Expr{ .temp = "true" } },
            .body = .{ .assign = .{ .expr = Expr{ .temp = "i++" } } },
            .@"else" = .{ .statement = Statement{ .temp = "foo();" } },
        },
    });
}

/// ```
/// ForStatement
///     <- ForPrefix BlockExpr ( KEYWORD_else Statement )?
///      / ForPrefix AssignExpr ( SEMICOLON / KEYWORD_else Statement )
/// ForPrefix <- KEYWORD_for LPAREN ForArgumentsList RPAREN PtrListPayload
/// ForArgumentsList <- ForItem (COMMA ForItem)* COMMA?
/// ForItem <- Expr (DOT2 Expr?)?
/// PtrListPayload <- PIPE ASTERISK? IDENTIFIER (COMMA ASTERISK? IDENTIFIER)* COMMA? PIPE
/// ```
const ForStatement = struct {
    prefix: Prefix,
    body: ControlBody,
    @"else": ?Statement = null,

    pub fn format(self: ForStatement, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        switch (self.body) {
            inline else => |b| {
                if (self.@"else") |t| {
                    try writer.print("{} {} else {}", .{ self.prefix, b, t });
                } else if (self.body == .assign) {
                    try writer.print("{} {};", .{ self.prefix, b });
                } else {
                    try writer.print("{} {}", .{ self.prefix, b });
                }
            },
        }
    }

    pub const Prefix = struct {
        arguments: []const ForItem,
        payload: []const Identifier = &.{},

        pub fn format(self: Prefix, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            assert(self.arguments.len > 0);
            try writer.writeAll("for (");
            try renderList(ForItem, self.arguments, .single, .{}, writer);
            try writer.writeAll(") |");
            try renderList(Identifier, self.payload, .single, .{
                .fmt_spc = "pre*",
            }, writer);
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
};

test "ForStatement" {
    try testing.expectFmt("for (&foo) |*f|", "{}", .{ForStatement.Prefix{
        .arguments = &.{.{ .single = Expr{ .temp = "&foo" } }},
        .payload = &.{Identifier{ .name = "*f" }},
    }});
    try testing.expectFmt("for (foo, 0..) |f, i|", "{}", .{ForStatement.Prefix{
        .arguments = &.{
            .{ .single = Expr{ .temp = "foo" } },
            .{ .range = .{ Expr{ .temp = "0" }, null } },
        },
        .payload = &.{
            Identifier{ .name = "f" },
            Identifier{ .name = "i" },
        },
    }});
    try testing.expectFmt("for (0..8) |i|", "{}", .{ForStatement.Prefix{
        .arguments = &.{
            .{ .range = .{ Expr{ .temp = "0" }, Expr{ .temp = "8" } } },
        },
        .payload = &.{Identifier{ .name = "i" }},
    }});

    try testing.expectFmt("for (foo) |f| {}", "{}", .{
        ForStatement{
            .prefix = .{
                .arguments = &.{.{ .single = Expr{ .temp = "foo" } }},
                .payload = &.{Identifier{ .name = "f" }},
            },
            .body = .{ .block = BlockExpr{ .statements = &.{} } },
        },
    });
    try testing.expectFmt("for (foo) |f| {} else {}", "{}", .{
        ForStatement{
            .prefix = .{
                .arguments = &.{.{ .single = Expr{ .temp = "foo" } }},
                .payload = &.{Identifier{ .name = "f" }},
            },
            .body = .{ .block = BlockExpr{ .statements = &.{} } },
            .@"else" = Statement{ .temp = "{}" },
        },
    });

    try testing.expectFmt("for (foo) |f| i++;", "{}", .{
        ForStatement{
            .prefix = .{
                .arguments = &.{.{ .single = Expr{ .temp = "foo" } }},
                .payload = &.{Identifier{ .name = "f" }},
            },
            .body = .{ .assign = .{ .expr = Expr{ .temp = "i++" } } },
        },
    });
    try testing.expectFmt("for (foo) |f| i++ else foo();", "{}", .{
        ForStatement{
            .prefix = .{
                .arguments = &.{.{ .single = Expr{ .temp = "foo" } }},
                .payload = &.{Identifier{ .name = "f" }},
            },
            .body = .{ .assign = .{ .expr = Expr{ .temp = "i++" } } },
            .@"else" = Statement{ .temp = "foo();" },
        },
    });
}

/// ```
/// WhileStatement
///     <- WhilePrefix BlockExpr ( KEYWORD_else Payload? Statement )?
///      / WhilePrefix AssignExpr ( SEMICOLON / KEYWORD_else Payload? Statement )
/// WhilePrefix <- KEYWORD_while LPAREN Expr RPAREN PtrPayload? WhileContinueExpr?
/// PtrPayload <- PIPE ASTERISK? IDENTIFIER PIPE
/// WhileContinueExpr <- COLON LPAREN AssignExpr RPAREN
/// ```
const WhileStatement = struct {
    prefix: Prefix,
    body: ControlBody,
    @"else": ?Else = null,

    pub fn format(self: WhileStatement, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.@"else") |t| switch (self.body) {
            inline else => |b| if (t.payload) |s| {
                try writer.print("{} {} else |{}| {}", .{ self.prefix, b, s, t.statement });
            } else {
                try writer.print("{} {} else {}", .{ self.prefix, b, t.statement });
            },
        } else switch (self.body) {
            .block => |t| try writer.print("{} {}", .{ self.prefix, t }),
            .assign => |t| try writer.print("{} {};", .{ self.prefix, t }),
        }
    }

    pub const Else = struct {
        payload: ?Identifier = null,
        statement: Statement,
    };

    pub const Prefix = struct {
        condition: Expr,
        payload: ?Identifier = null,
        @"continue": ?AssignExpr = null,

        pub fn format(self: Prefix, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            try writer.print("while ({})", .{self.condition});
            if (self.payload) |t| try writer.print(" |{pre*}|", .{t});
            if (self.@"continue") |t| try writer.print(" : ({})", .{t});
        }
    };
};

test "WhileStatement" {
    try testing.expectFmt("while (true)", "{}", .{WhileStatement.Prefix{
        .condition = Expr{ .temp = "true" },
    }});
    try testing.expectFmt("while (foo.next()) |*bar| : (i++)", "{}", .{WhileStatement.Prefix{
        .condition = Expr{ .temp = "foo.next()" },
        .payload = Identifier{ .name = "*bar" },
        .@"continue" = .{ .expr = Expr{ .temp = "i++" } },
    }});

    try testing.expectFmt("while (true) {}", "{}", .{
        WhileStatement{
            .prefix = .{ .condition = Expr{ .temp = "true" } },
            .body = .{ .block = BlockExpr{ .statements = &.{} } },
        },
    });
    try testing.expectFmt("while (true) {} else {}", "{}", .{
        WhileStatement{
            .prefix = .{ .condition = Expr{ .temp = "true" } },
            .body = .{ .block = BlockExpr{ .statements = &.{} } },
            .@"else" = .{ .statement = Statement{ .temp = "{}" } },
        },
    });

    try testing.expectFmt("while (true) i++ else |foo| { _ = foo; }", "{}", .{
        WhileStatement{
            .prefix = .{ .condition = Expr{ .temp = "true" } },
            .body = .{ .assign = .{ .expr = Expr{ .temp = "i++" } } },
            .@"else" = .{
                .payload = Identifier{ .name = "foo" },
                .statement = Statement{ .temp = "{ _ = foo; }" },
            },
        },
    });
    try testing.expectFmt("while (true) i++;", "{}", .{
        WhileStatement{
            .prefix = .{ .condition = Expr{ .temp = "true" } },
            .body = .{ .assign = .{ .expr = Expr{ .temp = "i++" } } },
        },
    });
    try testing.expectFmt("while (true) i++ else foo();", "{}", .{
        WhileStatement{
            .prefix = .{ .condition = Expr{ .temp = "true" } },
            .body = .{ .assign = .{ .expr = Expr{ .temp = "i++" } } },
            .@"else" = .{ .statement = Statement{ .temp = "foo();" } },
        },
    });
}

const ControlBody = union(enum) {
    block: BlockExpr,
    assign: AssignExpr,
};

/// ```
/// BlockExpr <- BlockLabel? Block
/// BlockLabel <- IDENTIFIER COLON
/// Block <- LBRACE Statement* RBRACE
/// ```
const BlockExpr = struct {
    label: ?Identifier = null,
    statements: []const Statement,

    pub fn format(self: BlockExpr, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.statements.len == 0) {
            assert(self.label == null);
            return writer.writeAll("{}");
        }

        if (self.label) |l| {
            try writer.print("{}: {{\n", .{l});
        } else {
            try writer.writeAll("{\n");
        }

        try renderList(Statement, self.statements, .{
            .multiline = INDENT_SIZE,
        }, .{ .delimiter = ';' }, writer);
        try writer.writeAll("\n}");
    }
};

test "BlockExpr" {
    try testing.expectFmt("{}", "{}", .{BlockExpr{
        .statements = &.{},
    }});

    try testing.expectFmt("{\n    foo();\n    bar();\n}", "{}", .{BlockExpr{
        .statements = &.{
            Statement{ .temp = "foo()" },
            Statement{ .temp = "bar()" },
        },
    }});

    try testing.expectFmt("label: {\n    foo();\n}", "{}", .{BlockExpr{
        .label = Identifier{ .name = "label" },
        .statements = &.{Statement{ .temp = "foo()" }},
    }});
}

/// `AssignExpr <- Expr (AssignOp Expr / (COMMA Expr)+ EQUAL Expr)?`
const AssignExpr = struct {
    lhs: Lhs = .none,
    expr: Expr,

    pub const Lhs = union(enum) {
        none,
        op: struct { Expr, AssignOp },
        destruct: []const Expr,
    };

    pub fn format(self: AssignExpr, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        switch (self.lhs) {
            .none => {
                const depth = std.options.fmt_max_depth - 1;
                try fmt.formatType(self.expr, "", .{}, writer, depth);
            },
            .op => |t| try writer.print("{} {s} {}", .{ t.@"0", t.@"1".resolve(), self.expr }),
            .destruct => |exprs| {
                try renderList(Expr, exprs, .single, .{}, writer);
                try writer.print(" = {}", .{self.expr});
            },
        }
    }
};

test "AssignExpr" {
    try testing.expectFmt("foo", "{}", .{AssignExpr{
        .expr = Expr{ .temp = "foo" },
    }});

    try testing.expectFmt("foo += bar", "{}", .{AssignExpr{
        .lhs = .{ .op = .{
            Expr{ .temp = "foo" },
            .plus_equal,
        } },
        .expr = Expr{ .temp = "bar" },
    }});

    try testing.expectFmt("const foo, const bar = baz", "{}", .{AssignExpr{
        .lhs = .{ .destruct = &.{
            Expr{ .temp = "const foo" },
            Expr{ .temp = "const bar" },
        } },
        .expr = Expr{ .temp = "baz" },
    }});
}

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
const SwitchExpr = struct {
    expr: Expr,
    prongs: []const SwitchProng,

    pub fn format(self: SwitchExpr, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.prongs.len == 0) {
            return writer.print("switch ({s}) {{}}", .{self.expr});
        } else {
            try writer.print("switch ({s}) {{\n", .{self.expr});
            try renderList(SwitchProng, self.prongs, .{
                .multiline = INDENT_SIZE,
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
                .items => |c| try renderList(SwitchItem, c, .single, .{}, writer),
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
};

test "SwitchExpr" {
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
/// `ByteAlign <- KEYWORD_align LPAREN Expr RPAREN`
fn renderByteAlign(expr: Expr, writer: anytype) !void {
    try writer.print("align({}) ", .{expr});
}

test "renderByteAlign" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    errdefer buffer.deinit();

    try renderByteAlign(Expr{ .temp = "4" }, buffer.writer());
    try testing.expectEqualStrings("align(4) ", buffer.items);
    buffer.clearAndFree();
}

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
};

test "Identifier" {
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

const MultilineBehavior = union(enum) {
    single,
    /// Value is indentation tab width
    multiline: u8,
    /// Value is indentation tab width
    auto: u8,
};

const ListOptions = struct {
    delimiter: u8 = ',',
    fmt_spc: []const u8 = "",
};

/// Generic list with multiline awareness.
fn renderList(
    comptime T: type,
    items: []const T,
    multiline: MultilineBehavior,
    comptime options: ListOptions,
    writer: anytype,
) !void {
    if (items.len == 0) return;

    var deli_buffer: [32]u8 = comptime .{ options.delimiter, '\n' } ++ " ".* ** 30;
    const deli: []const u8, const is_multiline = switch (multiline) {
        .single => .{ &.{ options.delimiter, ' ' }, false },
        .multiline => |indent| blk: {
            try writer.writeAll(deli_buffer[2..][0..indent]);
            break :blk .{ deli_buffer[0 .. indent + 2], true };
        },
        .auto => unreachable,
    };

    for (items, 0..) |item, i| {
        if (i > 0) try writer.writeAll(deli);
        const depth = std.options.fmt_max_depth - 1;
        try fmt.formatType(item, options.fmt_spc, .{}, writer, depth);
    }

    if (is_multiline) try writer.writeByte(options.delimiter);
}

test "renderList" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    errdefer buffer.deinit();

    try renderList(u8, &.{1}, .single, .{}, buffer.writer());
    try testing.expectEqualStrings("1", buffer.items);
    buffer.clearAndFree();

    try renderList(u8, &.{ 1, 2, 3 }, .single, .{}, buffer.writer());
    try testing.expectEqualStrings("1, 2, 3", buffer.items);
    buffer.clearAndFree();

    try renderList(u8, &.{}, .{
        .multiline = 0,
    }, .{}, buffer.writer());
    try testing.expectEqualStrings("", buffer.items);
    buffer.clearAndFree();

    try renderList(u8, &.{1}, .{
        .multiline = 4,
    }, .{}, buffer.writer());
    try testing.expectEqualStrings("    1,", buffer.items);
    buffer.clearAndFree();

    try renderList(u8, &.{ 1, 2, 3 }, .{
        .multiline = 4,
    }, .{}, buffer.writer());
    try testing.expectEqualStrings("    1,\n    2,\n    3,", buffer.items);
    buffer.clearAndFree();
}
