const std = @import("std");
const testing = std.testing;
const Region = @import("../infra/region.gen.zig").Region;

pub const Entry = struct {
    Type: *const anyopaque,
    field: []const u8,
    key_env: ?[]const u8,
    key_profile: ?[]const u8,
    parseFn: ?*const fn (value: []const u8, out: *anyopaque) bool,

    pub fn new(
        field: []const u8,
        T: type,
        env: ?[]const u8,
        profile: ?[]const u8,
        parseFn: ?*const fn (value: []const u8, out: *anyopaque) bool,
    ) Entry {
        return Entry{
            .Type = &T,
            .field = field,
            .key_env = env,
            .key_profile = profile,
            .parseFn = parseFn,
        };
    }
};

pub const entries: []const Entry = &.{
    Entry.new("profile_file", []const u8, "AWS_PROFILE", null, null),
    Entry.new("config_file", []const u8, "AWS_CONFIG_FILE", null, null),
    Entry.new("shared_credentials_file", []const u8, "AWS_SHARED_CREDENTIALS_FILE", null, null),

    Entry.new("api_versions", []const u8, null, "api_versions", null),
    Entry.new("defaults_mode", []const u8, "AWS_DEFAULTS_MODE", "defaults_mode", null),
    Entry.new("ua_app_id", []const u8, "AWS_SDK_UA_APP_ID", "sdk_ua_app_id", null),

    Entry.new("access_id", []const u8, "AWS_ACCESS_KEY_ID", "aws_access_key_id", null),
    Entry.new("access_secret", []const u8, "AWS_SECRET_ACCESS_KEY", "aws_secret_access_key", null),
    Entry.new("session_token", []const u8, "AWS_SESSION_TOKEN", "aws_session_token", null),
    Entry.new("ca_bundle", []const u8, "AWS_CA_BUNDLE", "ca_bundle", null),
    Entry.new("iam_role_arn", []const u8, "AWS_IAM_ROLE_ARN", "role_arn", null),
    Entry.new("iam_role_session_name", []const u8, "AWS_IAM_ROLE_SESSION_NAME", "role_session_name", null),
    Entry.new("web_identity_token_file", []const u8, "AWS_WEB_IDENTITY_TOKEN_FILE", "web_identity_token_file", null),

    Entry.new("region", Region, "AWS_REGION", "region", parseRegion),
    Entry.new("endpoint_fips", []const u8, "AWS_USE_FIPS_ENDPOINT", "use_fips_endpoint", null),
    Entry.new("endpoint_dualstack", []const u8, "AWS_USE_DUALSTACK_ENDPOINT", "use_dualstack_endpoint", null),

    Entry.new("retry_mode", []const u8, "AWS_RETRY_MODE", "retry_mode", null),
    Entry.new("retry_attempts", u32, "AWS_MAX_ATTEMPTS", "max_attempts", parseUInt32),

    Entry.new("compression_disable", []const u8, "AWS_DISABLE_REQUEST_COMPRESSION", "disable_request_compression", null),
    Entry.new("compression_min_bytes", []const u8, "AWS_REQUEST_MIN_COMPRESSION_SIZE_BYTES", "request_min_compression_size_bytes", null),

    Entry.new("endpoint_discovery", []const u8, "AWS_ENABLE_ENDPOINT_DISCOVERY", "endpoint_discovery_enabled", null),
    Entry.new("endpoint_urls", []const u8, "AWS_ENDPOINT_URL", "endpoint_url", null),
    Entry.new("endpoint_urls_ignore", []const u8, "AWS_IGNORE_CONFIGURED_ENDPOINT_URLS", "ignore_configured_endpoint_urls", null),

    Entry.new("sts_regional_endpoints", []const u8, "AWS_STS_REGIONAL_ENDPOINTS", "sts_regional_endpoints", null),

    Entry.new("s3_arn_region", []const u8, "AWS_S3_USE_ARN_REGION", "s3_use_arn_region", null),
    Entry.new("s3_multiregion_disable", []const u8, "AWS_S3_DISABLE_MULTIREGION_ACCESS_POINTS", "s3_disable_multiregion_access_points", null),

    Entry.new("ec2_metadata_disabled", []const u8, "AWS_EC2_METADATA_DISABLED", null, null),
    Entry.new("ec2_metadata_v1_disabled", []const u8, "AWS_EC2_METADATA_V1_DISABLED", "ec2_metadata_v1_disabled", null),
    Entry.new("ec2_metadata_endpoint", []const u8, "AWS_EC2_METADATA_SERVICE_ENDPOINT", "ec2_metadata_service_endpoint", null),
    Entry.new("ec2_metadata_endpoint_mode", []const u8, "AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE", "ec2_metadata_service_endpoint_mode", null),

    Entry.new("metadata_timeout", []const u8, "AWS_METADATA_SERVICE_TIMEOUT", "metadata_service_timeout", null),
    Entry.new("metadata_num_attempts", []const u8, "AWS_METADATA_SERVICE_NUM_ATTEMPTS", "metadata_service_num_attempts", null),

    Entry.new("container_auth_token", []const u8, "AWS_CONTAINER_AUTHORIZATION_TOKEN", null, null),
    Entry.new("container_auth_token_file", []const u8, "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE", null, null),
    Entry.new("container_creds_uri_full", []const u8, "AWS_CONTAINER_CREDENTIALS_FULL_URI", null, null),
    Entry.new("container_creds_uri_relative", []const u8, "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", null, null),
};

fn parseUInt32(value: []const u8, out: *anyopaque) bool {
    const number = std.fmt.parseUnsigned(u32, value, 10) catch return false;
    const ref: *u32 = @ptrCast(@alignCast(out));
    ref.* = number;
    return true;
}

test "parseUInt32" {
    var out: u32 = undefined;
    try testing.expectEqual(false, parseUInt32("zero", &out));
    try testing.expectEqual(true, parseUInt32("108", &out));
    try testing.expectEqual(out, 108);
}

fn parseRegion(value: []const u8, out: *anyopaque) bool {
    const region = Region.parseCode(value) orelse return false;
    const ref: *Region = @ptrCast(@alignCast(out));
    ref.* = region;
    return true;
}

test "parseRegion" {
    var out: Region = undefined;
    try testing.expectEqual(false, parseRegion("foo-bar-108", &out));
    try testing.expectEqual(true, parseRegion("us-west-2", &out));
    try testing.expectEqual(out, Region.us_west_2);
}
