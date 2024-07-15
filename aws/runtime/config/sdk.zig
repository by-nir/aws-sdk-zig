const std = @import("std");
const testing = std.testing;
const Region = @import("region.gen.zig").Region;

// https://docs.aws.amazon.com/sdkref/latest/guide/creds-config-files.html
// https://docs.aws.amazon.com/sdkref/latest/guide/settings-reference.html
pub const SdkConfig = struct {
    /// A name to add to the user agent string.
    /// Supported characters are alphanumeric characters and the following: `!#$%&'*+-.^_`|~`
    /// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/feature-appid.html)
    app_name: ?[]const u8 = null,
    /// The AWS region configured for the SDK client.
    /// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/feature-region.html)
    region: ?Region = null,
    /// Override the endpoint URL.
    endpoint_url: ?[]const u8 = null,
    /// When true, send this request to the FIPS-compliant regional endpoint.
    /// If no FIPS-compliant endpoint can be determined, dispatching the request will return an error.
    /// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/feature-endpoints.html)
    use_fips: ?bool = null,
    /// When true, send this request to the dual-stack regional endpoint.
    /// If no dual-stack endpoint can be determined, dispatching the request will return an error.
    /// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/feature-endpoints.html)
    use_dual_stack: ?bool = null,

    pub fn validate(self: SdkConfig) !void {
        if (self.app_name) |name| try validateAppName(name);
    }

    fn validateAppName(name: []const u8) !void {
        if (name.len > 50) return error.ConfigAppNameTooLong;
        for (name) |c| {
            switch (c) {
                '0'...'9', 'A'...'Z', 'a'...'z' => {},
                '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
                else => return error.ConfigAppNameInvalid,
            }
        }
    }
};

test "SdkConfig.validAppName" {
    try SdkConfig.validateAppName("foo");
    try testing.expectError(error.ConfigAppNameInvalid, SdkConfig.validateAppName("fo@"));
    try testing.expectError(error.ConfigAppNameTooLong, SdkConfig.validateAppName("f" ** 51));
}
