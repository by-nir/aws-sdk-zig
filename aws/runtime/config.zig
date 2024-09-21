const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const http = @import("http.zig");
const identity = @import("auth/identity.zig");
const Region = @import("infra/region.gen.zig").Region;

const ConfigOptions = struct {
    region: ?Region = null,
    app_id: ?[]const u8 = null,
    endpoint_url: ?[]const u8 = null,
    use_fips: ?bool = null,
    use_dual_stack: ?bool = null,
};

/// Configuraion options and resources that may be shared across multiple clients.
pub const SharedConfig = struct {
    allocator: Allocator,
    options: ConfigOptions,
    http_provider: Resource(http.SharedClient),
    identity_manager: Resource(identity.SharedManager),

    pub fn build(allocator: Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SharedConfig) void {
        if (self.http_provider == .managed) self.http_provider.managed.deinit();
        if (self.identity_manager == .managed) self.identity_manager.managed.deinit();
        self.* = undefined;
    }

    fn retainHttpClient(self: *SharedConfig) *http.Client {
        switch (self.http_provider) {
            .none => {
                self.http_provider = .{
                    .managed = http.SharedClient.init(self.allocator),
                };
                return self.http_provider.managed.retain();
            },
            .managed => return self.http_provider.managed.retain(),
            .unmanaged => return self.http_provider.unmanaged.retain(),
        }
    }

    fn retainIdentityManager(self: *SharedConfig) *identity.Manager {
        switch (self.identity_manager) {
            .none => {
                self.identity_manager = .{
                    .managed = identity.SharedManager.initStandard(self.allocator),
                };
                return self.identity_manager.managed.retain();
            },
            .managed => return self.identity_manager.managed.retain(),
            .unmanaged => return self.identity_manager.unmanaged.retain(),
        }
    }

    fn Resource(comptime T: type) type {
        return union(enum) {
            none,
            managed: T,
            unmanaged: *T,
        };
    }

    /// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/settings-reference.html)
    pub const Builder = struct {
        allocator: Allocator,
        options: ConfigOptions = .{},
        http_provider: ?*http.SharedClient = null,
        identity_manager: ?*identity.SharedManager = null,

        pub fn deinit(self: *Builder) void {
            self.* = undefined;
        }

        /// The AWS region configured for the SDK client.
        /// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/feature-region.html)
        pub fn setRegion(self: *Builder, region: Region) void {
            self.options.region = region;
        }

        /// A name to add to the user agent string.
        /// Supported characters are alphanumeric characters and the following: `!#$%&'*+-.^_`|~`
        /// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/feature-appid.html)
        pub fn setAppId(self: *Builder, id: []const u8) void {
            self.options.app_id = id;
        }

        /// Override the endpoint URL.
        pub fn setEndpointUrl(self: *Builder, url: []const u8) void {
            self.options.endpoint_url = url;
        }

        /// When true, send this request to the FIPS-compliant regional endpoint.
        /// If no FIPS-compliant endpoint can be determined, dispatching the request will return an error.
        /// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/feature-endpoints.html)
        pub fn setUseFips(self: *Builder, value: bool) void {
            self.options.use_fips = value;
        }

        /// When true, send this request to the dual-stack regional endpoint.
        /// If no dual-stack endpoint can be determined, dispatching the request will return an error.
        /// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/feature-endpoints.html)
        pub fn setUseDualStack(self: *Builder, value: bool) void {
            self.options.use_dual_stacks = value;
        }

        pub fn setHttpClient(self: *Builder, client: *http.SharedClient) void {
            self.http_provider = client;
        }

        pub fn setIdentityManager(self: *Builder, manager: *identity.SharedManager) void {
            self.identity_manager = manager;
        }

        pub fn consume(self: *Builder) SharedConfig {
            const http_provider: Resource(http.SharedClient) = if (self.http_provider) |t| .{ .unmanaged = t } else .none;
            const identity_manager: Resource(identity.SharedManager) = if (self.identity_manager) |t| .{ .unmanaged = t } else .none;

            defer self.* = undefined;
            return .{
                .allocator = self.allocator,
                .options = self.options,
                .http_provider = http_provider,
                .identity_manager = identity_manager,
            };
        }
    };
};

/// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/settings-reference.html)
pub const Config = struct {
    /// Shared configuration that will be used when no an explicit value is not set.
    shared: ?*SharedConfig = null,

    /// The HTTP client to use for sending requests.
    http_client: ?*http.SharedClient = null,
    /// The HTTP client to use for sending requests.
    identity_manager: ?*identity.SharedManager = null,

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
};

pub const ClientConfig = struct {
    http_client: *http.Client,
    identity_manager: *identity.Manager,
    region: Region,
    app_id: ?[]const u8,
    endpoint_url: ?[]const u8,
    use_fips: ?bool,
    use_dual_stack: ?bool,

    pub fn resolveFrom(cfg: Config) !ClientConfig {
        const http_client = try resolveHttp(cfg);
        errdefer http_client.deinit();

        const identity_manager = try resolveIdentityManager(cfg);
        errdefer identity_manager.deinit();

        const region =
            cfg.region orelse
            resolveOption(cfg, Region, "region") orelse
            return error.ConfigMissingRegion;

        const app_id = resolveOption(cfg, []const u8, "app_id");
        if (app_id) |id| try validateAppId(id);

        return .{
            .http_client = http_client,
            .identity_manager = identity_manager,
            .region = region,
            .app_id = app_id,
            .endpoint_url = resolveOption(cfg, []const u8, "endpoint_url"),
            .use_fips = resolveOption(cfg, bool, "use_fips"),
            .use_dual_stack = resolveOption(cfg, bool, "use_dual_stack"),
        };
    }

    fn resolveOption(cfg: Config, comptime T: type, comptime field_name: []const u8) ?T {
        if (@field(cfg, field_name)) |v| return v;
        if (cfg.shared) |shared| if (@field(shared.options, field_name)) |v| return v;
        return null;
    }

    fn resolveHttp(cfg: Config) !*http.Client {
        if (cfg.http_client) |t| return t.retain();
        if (cfg.shared) |r| return r.retainHttpClient();
        return error.ConfigMissingHttpClient;
    }

    fn resolveIdentityManager(cfg: Config) !*identity.Manager {
        if (cfg.identity_manager) |t| return t.retain();
        if (cfg.shared) |r| return r.retainIdentityManager();
        return error.ConfigMissingIdentityManager;
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
