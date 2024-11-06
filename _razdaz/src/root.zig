const decoder = @import("decode.zig");
pub const SliceDecoder = decoder.SliceDecoder;
pub const ReaderDecoder = decoder.ReaderDecoder;
pub const TestingDecoder = decoder.TestingDecoder;

const combine = @import("combine.zig");
pub const Operator = combine.Operator;
pub const OperatorDefine = combine.OperatorDefine;
pub const Filter = combine.Filter;
pub const Matcher = combine.Matcher;
pub const Resolver = combine.Resolver;

test {
    _ = @import("read.zig");
    _ = @import("consume.zig");
    _ = combine;
    _ = decoder;
}
