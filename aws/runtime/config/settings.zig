const std = @import("std");
const ZigType = std.builtin.Type;
const testing = std.testing;
const Region = @import("region.gen.zig").Region;

pub const ACCESS_ID_LEN = 20;
pub const ACCESS_SECRET_LEN = 40;

pub const AccessId = [ACCESS_ID_LEN]u8;
pub const AccessSecret = [ACCESS_SECRET_LEN]u8;
pub const SessionToken = []const u8;

/// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/feature-static-credentials.html)
pub const Credentials = union(enum) {
    /// The access key ID.
    access_id: AccessId,
    /// The secret access key.
    access_secret: AccessSecret,
    /// The session token (optional).
    session_token: ?SessionToken,
};

/// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/settings-reference.html)
pub const Config = struct {
    /// A name to add to the user agent string.
    /// Supported characters are alphanumeric characters and the following: `!#$%&'*+-.^_`|~`
    /// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/feature-appid.html)
    app_id: ?[]const u8 = null,
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

    pub const Options = struct {
        cached_env: bool = true,
        profile_name: ?[]const u8 = null,
        profiles_path: ?[]const u8 = null,
        credentials_path: ?[]const u8 = null,
    };

    pub fn load(options: Options) !Config {
        var config: Config = .{};
        try fillEnvironment(&config, options.cached_env);
        return config;
    }

    pub fn loadEnv(cached: bool) !Config {
        var config: Config = .{};
        try fillEnvironment(&config, cached);
        return config;
    }

    fn fillEnvironment(config: *Config, cached: bool) !void {
        const env = if (cached) try Env.loadCached() else try Env.load();
        if (config.app_id == null) config.app_id = env.ua_app_id;
        if (config.region == null) config.region = env.region;
        if (config.use_fips == null) config.use_fips = env.endpoint_fips;
        if (config.use_dual_stack == null) config.use_dual_stack = env.endpoint_dualstack;
    }

    pub fn validate(self: Config) !void {
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

test "Config.validAppName" {
    try Config.validateAppName("foo");
    try testing.expectError(error.ConfigAppNameInvalid, Config.validateAppName("fo@"));
    try testing.expectError(error.ConfigAppNameTooLong, Config.validateAppName("f" ** 51));
}

/// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/settings-reference.html#EVarSettings)
const Env = struct {
    pub var shared: ?Values = null;

    pub fn load() !Values {
        return parse(std.os.environ);
    }

    pub fn loadCached() !Values {
        if (shared == null) shared = try parse(std.os.environ);
        return shared.?;
    }

    fn parse(lines: []const [*:0]const u8) !Values {
        var values: Values = .{};

        for (lines) |line| {
            var line_i: usize = 0;
            while (line[line_i] != 0 and line[line_i] != '=') : (line_i += 1) {}
            const key = line[0..line_i];

            const entry = entries_env.get(key) orelse continue;

            var end_i: usize = line_i;
            while (line[end_i] != 0) : (end_i += 1) {}
            const str_value = line[line_i + 1 .. end_i];

            inline for (comptime entries_env.values()) |e| {
                if (std.mem.eql(u8, e.field, entry.field)) {
                    if (e.parseFn) |parseFn| {
                        const T: type = @as(*const type, @ptrCast(@alignCast(e.Type))).*;
                        var out: T = undefined;
                        if (!parseFn(str_value, &out)) return error.EnvConfigParseFailed;
                        @field(values, e.field) = out;
                    } else {
                        @field(values, e.field) = str_value;
                    }
                    break;
                }
            }
        }

        return values;
    }

    const Values: type = blk: {
        var fields_len: usize = 0;
        var fields: [entries_env.kvs.len]ZigType.StructField = undefined;

        for (0..entries_env.kvs.len) |i| {
            const entry = entries_env.kvs.values[i];

            var name: [entry.field.len:0]u8 = undefined;
            @memcpy(name[0..entry.field.len], entry.field);

            const T: type = @as(*const type, @ptrCast(@alignCast(entry.Type))).*;
            const default_value: ?T = null;
            fields[fields_len] = ZigType.StructField{
                .name = &name,
                .type = ?T,
                .default_value = &default_value,
                .is_comptime = false,
                .alignment = @alignOf(?T),
            };
            fields_len += 1;
        }

        break :blk @Type(.{ .Struct = .{
            .layout = .auto,
            .fields = fields[0..fields_len],
            .decls = &.{},
            .is_tuple = false,
        } });
    };
};

test "Env.parse" {
    try testing.expectEqualDeep(Env.Values{
        .ua_app_id = "baz",
        .retry_attempts = 3,
        .region = .us_east_2,
    }, try Env.parse(&[_][*:0]const u8{
        "FOO=bar",
        "AWS_SDK_UA_APP_ID=baz",
        "AWS_MAX_ATTEMPTS=3",
        "AWS_REGION=us-east-2",
    }));
}

const Entry = struct {
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

const entries_env: std.StaticStringMap(Entry) = blk: {
    var map_len: usize = 0;
    var map: [entries.len]struct { []const u8, Entry } = undefined;

    for (entries) |entry| {
        if (entry.key_env == null) continue;
        map[map_len] = .{ entry.key_env.?, entry };
        map_len += 1;
    }

    break :blk std.StaticStringMap(Entry).initComptime(map[0..map_len]);
};

const entries: []const Entry = &.{
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
