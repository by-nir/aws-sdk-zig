test {
    _ = @import("consume/read.zig");
    _ = @import("consume/evaluate.zig");
    _ = combine;
    _ = decoder;
    _ = testing;

    _ = ops_ascii;
    _ = ops_utf8;
    _ = ops_seq;
    _ = ops_repeat;
    _ = ops_type;
}

const decoder = @import("consume/decode.zig");
pub const SliceDecoder = decoder.SliceDecoder;
pub const sliceDecoder = decoder.sliceDecoder;
pub const ReaderDecoder = decoder.ReaderDecoder;
pub const readerDecoder = decoder.readerDecoder;

const combine = @import("combine.zig");
pub const Filter = combine.Filter;
pub const Matcher = combine.Matcher;
pub const SizeHint = combine.SizeHint;
pub const Resolver = combine.Resolver;
pub const Operator = combine.Operator;
pub const OperatorDefine = combine.OperatorDefine;

pub const testing = @import("testing.zig");

const ops_ascii = @import("ops/ascii.zig");
const ops_utf8 = @import("ops/utf8.zig");
const ops_seq = @import("ops/sequence.zig");
const ops_repeat = @import("ops/repeat.zig");

const ops_type = @import("ops/type.zig");
pub const TypeLayout = ops_type.Layout;
pub const TypeValueOptions = ops_type.ValueOptions;

pub const op = struct {
    // Repeat
    pub const repeat = ops_repeat.repeat;
    pub const repeatMin = ops_repeat.repeatMin;
    pub const repeatMax = ops_repeat.repeatMax;
    pub const repeatRange = ops_repeat.repeatRange;
    pub const repeatWhile = ops_repeat.repeatWhile;
    pub const repeatUntil = ops_repeat.repeatUntil;

    // Type
    pub const typeValue = ops_type.typeValue;

    // Sequence
    pub const amount = ops_seq.amount;
    pub const matchSequence = ops_seq.matchSequence;
    pub const matchString = ops_seq.matchString;
    pub const matchAnyString = ops_seq.matchAnyString;

    /// ASCII character
    pub const ascii = struct {
        pub const any = ops_ascii.matchValid;
        pub const char = ops_ascii.matchChar;
        pub const unless = ops_ascii.unlessChar;
        pub const from = ops_ascii.matchAnyChar;
        pub const unlessFrom = ops_ascii.unlessAnyChar;
        pub const compound = ops_ascii.matchCharCompound;
        pub const whitespace = ops_ascii.matchWhitespace;
        pub const alphabet = ops_ascii.matchAlphabet;
        pub const alphanum = ops_ascii.matchAlphanum;
        pub const digit = ops_ascii.matchDigit;
        pub const hex = ops_ascii.matchHex;
        pub const lower = ops_ascii.matchLower;
        pub const upper = ops_ascii.matchUpper;
        pub const control = ops_ascii.matchControl;
        pub const escape = ops_ascii.encodeEscape;
        pub const unescape = ops_ascii.decodeEscape;
    };
    pub const AsciiCompund = ops_ascii.CharCompound;

    /// UTF-8 codepoint (byte sequence)
    pub const utf8 = struct {
        pub const any = ops_utf8.matchValid;
        pub const char = ops_utf8.matchChar;
        pub const unless = ops_utf8.unlessChar;
        pub const from = ops_utf8.matchAnyChar;
        pub const unlessFrom = ops_utf8.unlessAnyChar;
        pub const compound = ops_utf8.matchCharCompound;
        pub const unlessCompound = ops_utf8.unlessCharCompound;
    };
    pub const Utf8Compund = ops_utf8.CharCompound;
};
