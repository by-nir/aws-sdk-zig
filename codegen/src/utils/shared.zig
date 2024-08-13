const std = @import("std");

pub const DefaultIndexer = u32;

pub fn Handle(comptime Indexer: type) type {
    return enum(Indexer) {
        none = std.math.maxInt(Indexer),
        _,
    };
}

pub const Reorder = enum { ordered, swap };
