const StackChain = @import("../../utils/declarative.zig").StackChain;
const Writer = @import("../CodegenWriter.zig");
const flow = @import("flow.zig");

const ExprChain = StackChain(*const Expr);

pub const Expr = union(enum) {
    pub const new: Expr = Expr._empty;

    _empty,
    _raw: []const u8,
    _chain: ExprChain,
    type: ExprType,
    value: ExprValue,
    operation: ExprOp,
    keyword: ExprKeyword,
    flow: ExprFlow,

    fn append(self: *const Expr, expr: Expr) Expr {
        return switch (self.*) {
            ._empty => expr,
            ._chain => |t| Expr{ ._chain = t.append(&expr) },
            else => Expr{ ._chain = ExprChain.start(self).append(&expr) },
        };
    }

    pub fn raw(self: *const Expr, value: []const u8) Expr {
        return self.append(.{ ._raw = value });
    }

    pub fn __write(self: Expr, writer: *Writer) anyerror!void {
        switch (self) {
            ._empty => unreachable,
            ._raw => |s| try writer.appendString(s),
            ._chain => unreachable,
            .flow => |t| try t.write(writer),
            else => unreachable,
            // .empty => ex,
            // .chain => |t| Expr{ .chain = t.append(ex) },
            // else => Expr{ .chain = StackChain(Expr).start(self.*).append(ex) },
        }
    }
};

const ExprType = union(enum) {
    PLACEHOLDER,
};

const ExprValue = union(enum) {
    PLACEHOLDER,
};

const ExprFlow = union(enum) {
    PLACEHOLDER,
};

const ExprKeyword = union(enum) {
    PLACEHOLDER,
};

const ExprOp = union(enum) {
    PLACEHOLDER,
};
