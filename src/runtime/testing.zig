const std = @import("std");
const RequestContent = @import("request.zig").RequestContent;

pub const ACCESS_ID = "AKIAIOSFODNN7EXAMPLE";
pub const ACCESS_SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";

pub fn demoRequest(allocator: std.mem.Allocator) !RequestContent {
    return RequestContent.init(allocator, .GET, "/foo", &.{
        .{ "foo", "%bar" },
        .{ "baz", "$qux" },
    }, &.{
        .{ "X-amz-date", "20130708T220855Z" },
        .{ "Host", "s3.amazonaws.com" },
    }, "foo-bar-baz");
}
