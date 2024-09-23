const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Region = @import("../infra/region.gen.zig").Region;

pub const Entry = struct {
    field: []const u8,
    key_env: ?[]const u8,
    key_profile: ?[]const u8,
    type_ref: *const anyopaque,
    parseFn: ?*const fn (value: []const u8, out: *anyopaque) bool,

    pub fn Type(comptime self: Entry) type {
        return @as(*const type, @ptrCast(@alignCast(self.type_ref))).*;
    }

    fn new(
        field: []const u8,
        T: type,
        env: ?[]const u8,
        profile: ?[]const u8,
        parseFn: ?*const fn (value: []const u8, out: *anyopaque) bool,
    ) Entry {
        return Entry{
            .type_ref = &T,
            .field = field,
            .key_env = env,
            .key_profile = profile,
            .parseFn = parseFn,
        };
    }

    pub fn parse(comptime self: Entry, s: []const u8) !self.Type() {
        const parseFn = self.parseFn orelse return s;
        var out: self.Type() = undefined;
        if (!parseFn(s, &out)) return error.EnvConfigParseFailed;
        return out;
    }

    pub fn parseAlloc(comptime self: Entry, allocator: Allocator, s: []const u8) !self.Type() {
        const val = try self.parse(s);
        return if (self.Type() == []const u8) allocator.dupe(u8, s) else val;
    }
};

pub const env_entries: std.StaticStringMap(Entry) = blk: {
    var map_len: usize = 0;
    var map: [entries.len]struct { []const u8, Entry } = undefined;

    for (entries) |entry| {
        const key = entry.key_env orelse continue;
        map[map_len] = .{ key, entry };
        map_len += 1;
    }

    break :blk std.StaticStringMap(Entry).initComptime(map[0..map_len]);
};

pub const profile_entries: std.StaticStringMap(Entry) = blk: {
    var map_len: usize = 0;
    var map: [entries.len]struct { []const u8, Entry } = undefined;

    for (entries) |entry| {
        const key = entry.key_profile orelse continue;
        map[map_len] = .{ key, entry };
        map_len += 1;
    }

    break :blk std.StaticStringMap(Entry).initComptime(map[0..map_len]);
};

const entries: []const Entry = &.{
    // General configuration settings
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-gen-config.html
    Entry.new("api_versions", []const u8, null, "api_versions", null),
    Entry.new("ca_bundle", []const u8, "AWS_CA_BUNDLE", "ca_bundle", null),
    Entry.new("output_format", []const u8, null, "output", null),
    Entry.new("client_validation", []const u8, null, "parameter_validation", null),

    // Smart configuration defaults
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-smart-config-defaults.html
    Entry.new("defaults_mode", []const u8, "AWS_DEFAULTS_MODE", "defaults_mode", null),

    // AWS Region
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-region.html
    Entry.new("region", Region, "AWS_REGION", "region", parseRegion),

    // Application ID
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-appid.html
    Entry.new("ua_app_id", []const u8, "AWS_SDK_UA_APP_ID", "sdk_ua_app_id", null),

    // Shared config and credentials files
    // https://docs.aws.amazon.com/sdkref/latest/guide/file-format.html
    Entry.new("profile_name", []const u8, "AWS_PROFILE", null, null),
    Entry.new("config_file", []const u8, "AWS_CONFIG_FILE", null, null),
    Entry.new("credentials_file", []const u8, "AWS_SHARED_CREDENTIALS_FILE", null, null),

    // AWS access keys
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-static-credentials.html
    Entry.new("access_id", []const u8, "AWS_ACCESS_KEY_ID", "aws_access_key_id", null),
    Entry.new("access_secret", []const u8, "AWS_SECRET_ACCESS_KEY", "aws_secret_access_key", null),
    Entry.new("session_token", []const u8, "AWS_SESSION_TOKEN", "aws_session_token", null),

    // Assume role credential provider
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-assume-role-credentials.html
    Entry.new("assume_credential_source", []const u8, null, "credential_source", null),
    Entry.new("assume_duration_seconds", []const u8, null, "duration_seconds", null),
    Entry.new("assume_external_id", []const u8, null, "external_id", null),
    Entry.new("assume_mfa_serial", []const u8, null, "mfa_serial", null),
    Entry.new("assume_source_profile", []const u8, null, "source_profile", null),
    Entry.new("assume_role_arn", []const u8, "AWS_IAM_ROLE_ARN", "role_arn", null),
    Entry.new("assume_role_session_name", []const u8, "AWS_IAM_ROLE_SESSION_NAME", "role_session_name", null),
    Entry.new("assume_web_token_file", []const u8, "AWS_WEB_IDENTITY_TOKEN_FILE", "web_identity_token_file", null),

    // IAM Identity Center credential provider
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-sso-credentials.html
    Entry.new("sso_region", Region, null, "sso_region", parseRegion),
    Entry.new("sso_role_name", []const u8, null, "sso_role_name", null),
    Entry.new("sso_start_url", []const u8, null, "sso_start_url", null),
    Entry.new("sso_account_id", []const u8, null, "sso_account_id", null),
    Entry.new("sso_registration_scopes", []const u8, null, "sso_registration_scopes", null),

    // AWS STS Regional endpoints
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-sts-regionalized-endpoints.html
    Entry.new("sts_regional_endpoints", []const u8, "AWS_STS_REGIONAL_ENDPOINTS", "sts_regional_endpoints", null),

    // Dual-stack and FIPS endpoints
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-endpoints.html
    Entry.new("endpoint_fips", []const u8, "AWS_USE_FIPS_ENDPOINT", "use_fips_endpoint", null),
    Entry.new("endpoint_dualstack", []const u8, "AWS_USE_DUALSTACK_ENDPOINT", "use_dualstack_endpoint", null),

    // Retry behavior
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-retry-behavior.html
    Entry.new("retry_mode", []const u8, "AWS_RETRY_MODE", "retry_mode", null),
    Entry.new("retry_attempts", u32, "AWS_MAX_ATTEMPTS", "max_attempts", parseUInt32),

    // Request compression
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-compression.html
    Entry.new("compression_disable", []const u8, "AWS_DISABLE_REQUEST_COMPRESSION", "disable_request_compression", null),
    Entry.new("compression_min_bytes", []const u8, "AWS_REQUEST_MIN_COMPRESSION_SIZE_BYTES", "request_min_compression_size_bytes", null),

    // Endpoint discovery
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-endpoint-discovery.html
    Entry.new("endpoint_discovery", []const u8, "AWS_ENABLE_ENDPOINT_DISCOVERY", "endpoint_discovery_enabled", null),

    // Account-based endpoints
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-account-endpoints.html
    Entry.new("endpoint_account", []const u8, "AWS_ACCOUNT_ID", "aws_account_id", null),
    Entry.new("endpoint_mode", []const u8, "AWS_ACCOUNT_ID_ENDPOINT_MODE", "account_id_endpoint_mode", null),

    // Service-specific endpoints
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-ss-endpoints.html
    Entry.new("endpoint_url", []const u8, "AWS_ENDPOINT_URL", "endpoint_url", null),
    Entry.new("endpoint_url_ignore", []const u8, "AWS_IGNORE_CONFIGURED_ENDPOINT_URLS", "ignore_configured_endpoint_urls", null),

    // Process credential provider
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-process-credentials.html
    Entry.new("credential_process", []const u8, null, "credential_process", null),

    // Container credential provider
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html
    Entry.new("container_auth_token", []const u8, "AWS_CONTAINER_AUTHORIZATION_TOKEN", null, null),
    Entry.new("container_auth_token_file", []const u8, "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE", null, null),
    Entry.new("container_creds_uri_full", []const u8, "AWS_CONTAINER_CREDENTIALS_FULL_URI", null, null),
    Entry.new("container_creds_uri_relative", []const u8, "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", null, null),

    // IMDS credential provider
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-imds-credentials.html
    Entry.new("ec2_metadata_disabled", []const u8, "AWS_EC2_METADATA_DISABLED", null, null),
    Entry.new("ec2_metadata_v1_disabled", []const u8, "AWS_EC2_METADATA_V1_DISABLED", "ec2_metadata_v1_disabled", null),
    Entry.new("ec2_metadata_endpoint", []const u8, "AWS_EC2_METADATA_SERVICE_ENDPOINT", "ec2_metadata_service_endpoint", null),
    Entry.new("ec2_metadata_endpoint_mode", []const u8, "AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE", "ec2_metadata_service_endpoint_mode", null),

    // Amazon EC2 instance metadata
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-ec2-instance-metadata.html
    Entry.new("metadata_timeout", []const u8, "AWS_METADATA_SERVICE_TIMEOUT", "metadata_service_timeout", null),
    Entry.new("metadata_num_attempts", []const u8, "AWS_METADATA_SERVICE_NUM_ATTEMPTS", "metadata_service_num_attempts", null),

    // Amazon S3
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-s3-mrap.html
    // https://docs.aws.amazon.com/sdkref/latest/guide/feature-s3-access-point.html
    Entry.new("s3_arn_region", []const u8, "AWS_S3_USE_ARN_REGION", "s3_use_arn_region", null),
    Entry.new("s3_multiregion_disable", []const u8, "AWS_S3_DISABLE_MULTIREGION_ACCESS_POINTS", "s3_disable_multiregion_access_points", null),
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
    const region = Region.parse(value) orelse return false;
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
