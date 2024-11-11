test {
    _ = @import("consume/read.zig");
    _ = @import("consume/evaluate.zig");
    _ = combine;
    _ = decoder;
    _ = testing;

    _ = ops_char;
}

const decoder = @import("consume/decode.zig");
pub const SliceDecoder = decoder.SliceDecoder;
pub const ReaderDecoder = decoder.ReaderDecoder;

const combine = @import("combine.zig");
pub const Filter = combine.Filter;
pub const Matcher = combine.Matcher;
pub const SizeHint = combine.SizeHint;
pub const Resolver = combine.Resolver;
pub const Operator = combine.Operator;
pub const OperatorDefine = combine.OperatorDefine;

pub const testing = @import("testing.zig");

const ops_char = @import("ops/char.zig");

pub const ops = struct {
    // Char
    pub const matchChar = ops_char.matchChar;
    pub const unlessChar = ops_char.unlessChar;
    pub const matchAnyChar = ops_char.matchAnyChar;
    pub const unlessAnyChar = ops_char.unlessAnyChar;
    pub const matchWhitespace = ops_char.matchWhitespace;
    pub const matchAlphabet = ops_char.matchAlphabet;
    pub const matchAlphanum = ops_char.matchAlphanum;
    pub const matchDigit = ops_char.matchDigit;
    pub const matchHex = ops_char.matchHex;
    pub const matchLower = ops_char.matchLower;
    pub const matchUpper = ops_char.matchUpper;
    pub const matchControl = ops_char.matchControl;
    pub const matchAscii = ops_char.matchAscii;
    pub const escapeChar = ops_char.encodeEscape;
    pub const unescapeChar = ops_char.decodeEscape;
};
