test {
    _ = @import("consume/read.zig");
    _ = @import("consume/evaluate.zig");
    _ = combine;
    _ = decoder;
    _ = testing;

    _ = ops_char;
    _ = ops_seq;
    _ = ops_repeat;
    _ = ops_type;
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
const ops_seq = @import("ops/sequence.zig");
const ops_repeat = @import("ops/repeat.zig");

const ops_type = @import("ops/type.zig");
pub const TypeLayout = ops_type.Layout;
pub const TypeValueOptions = ops_type.ValueOptions;

pub const op = struct {
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

    // Sequence
    pub const amount = ops_seq.amount;
    pub const matchSequence = ops_seq.matchSequence;
    pub const matchString = ops_seq.matchString;
    pub const matchAnyString = ops_seq.matchAnyString;

    // Repeat
    pub const repeat = ops_repeat.repeat;
    pub const repeatMin = ops_repeat.repeatMin;
    pub const repeatMax = ops_repeat.repeatMax;
    pub const repeatRange = ops_repeat.repeatRange;
    pub const repeatWhile = ops_repeat.repeatWhile;
    pub const repeatUntil = ops_repeat.repeatUntil;

    // Type
    pub const typeValue = ops_type.typeValue;
};
