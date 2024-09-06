const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const http = @import("http.zig");
const creds = @import("auth/creds.zig");
const Region = @import("infra/region.gen.zig").Region;

pub const ConfigResources = struct {
    allocator: Allocator,
    http_provider: ?http.ClientProvider = null,

    pub fn init(allocator: Allocator) ConfigResources {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ConfigResources) void {
        if (self.http_provider) |*t| t.deinit();
        self.* = undefined;
    }

    fn provideHttp(self: *ConfigResources) *http.ClientProvider {
        if (self.http_provider == null) self.http_provider = http.ClientProvider.init(self.allocator);
        return &self.http_provider.?;
    }
};

/// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/settings-reference.html)
pub const ConfigOptions = struct {
    /// The AWS region configured for the SDK client.
    /// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/feature-region.html)
    region: Region,
    /// A name to add to the user agent string.
    /// Supported characters are alphanumeric characters and the following: `!#$%&'*+-.^_`|~`
    /// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/feature-appid.html)
    app_id: ?[]const u8 = null,
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

    pub fn default(region: Region) ConfigOptions {
        return .{ .region = region };
    }
};

/// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/settings-reference.html)
pub const Config = struct {
    /// When an explicit option is not loaded, fallback to the value set by the given options.
    fallback_options: ?ConfigOptions = null,
    /// When an explicit resource is not set, fallback to the a shared resource provided by the given manager.
    fallback_resources: ?*ConfigResources = null,
    /// The http client or provider to use for requests.
    /// - `value`: reference to a `HttpClient`
    /// - `provider`: reference to a `HttpClientProvider`
    http_client: Resource(*http.Client, *http.ClientProvider) = .none,
    credentials: Resource(creds.Credentials, void) = .none,
    /// The AWS region configured for the SDK client.
    /// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/feature-region.html)
    region: ?Region = null,
    /// A name to add to the user agent string.
    /// Supported characters are alphanumeric characters and the following: `!#$%&'*+-.^_`|~`
    /// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/feature-appid.html)
    app_id: ?[]const u8 = null,
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

    pub fn Resource(comptime Val: type, comptime Provide: type) type {
        return union(enum) {
            none,
            value: Val,
            provider: Provide,
        };
    }
};

pub const ClientConfig = struct {
    http_client: *http.Client,
    credentials: creds.Credentials,
    region: Region,
    app_id: ?[]const u8,
    endpoint_url: ?[]const u8,
    use_fips: ?bool,
    use_dual_stack: ?bool,

    pub fn resolve(cfg: Config) !ClientConfig {
        const http_client = try resolveHttp(cfg);
        errdefer if (cfg.http_client == .provider) cfg.http_client.provider.release(http_client);

        const credentials = try resolveCredentials(cfg);

        const region = cfg.region orelse if (cfg.fallback_options) |o| o.region else {
            return error.ConfigMissingRegion;
        };

        const app_id = resolveOption(cfg, []const u8, "app_id");
        if (app_id) |id| try validateAppId(id);

        return .{
            .http_client = http_client,
            .credentials = credentials,
            .region = region,
            .app_id = app_id,
            .endpoint_url = resolveOption(cfg, []const u8, "endpoint_url"),
            .use_fips = resolveOption(cfg, bool, "use_fips"),
            .use_dual_stack = resolveOption(cfg, bool, "use_dual_stack"),
        };
    }

    fn resolveOption(cfg: Config, comptime T: type, comptime field_name: []const u8) ?T {
        if (@field(cfg, field_name)) |v| return v;
        if (cfg.fallback_options) |o| if (@field(o, field_name)) |v| return v;
        return null;
    }

    fn resolveHttp(cfg: Config) !*http.Client {
        switch (cfg.http_client) {
            .value => |v| return v,
            .provider => |p| return p.retain(),
            .none => if (cfg.fallback_resources) |r| {
                const provider = r.provideHttp();
                return provider.retain();
            },
        }
        return error.ConfigMissingHttpClient;
    }

    fn resolveCredentials(cfg: Config) !creds.Credentials {
        switch (cfg.credentials) {
            .value => |v| return v,
            else => {}, // TODO
        }
        return error.ConfigMissingCredentials;
    }

    fn validateAppId(id: []const u8) !void {
        if (id.len > 50) return error.ConfigAppIdTooLong;
        for (id) |c| {
            switch (c) {
                '0'...'9', 'A'...'Z', 'a'...'z' => {},
                '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
                else => return error.ConfigAppIdInvalid,
            }
        }
    }
};

test "ClientConfig.validateAppId" {
    try ClientConfig.validateAppId("foo");
    try testing.expectError(error.ConfigAppIdInvalid, ClientConfig.validateAppId("fo@"));
    try testing.expectError(error.ConfigAppIdTooLong, ClientConfig.validateAppId("f" ** 51));
}
