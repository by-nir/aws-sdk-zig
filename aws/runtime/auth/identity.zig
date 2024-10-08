//! https://github.com/awslabs/aws-c-auth
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const conf_env = @import("../config/env.zig");
const conf_profile = @import("../config/profile.zig");
const SharedResource = @import("../utils/SharedResource.zig");

const log = std.log.scoped(.aws_sdk);

pub const CREDS_ID_LEN = 20;
pub const CREDS_SECRET_LEN = 40;

pub const TEST_ID: []const u8 = "AKIAIOSFODNN7EXAMPLE";
pub const TEST_SECRET: []const u8 = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
pub const TEST_TOKEN: []const u8 = "IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZVERYLONGSTRINGEXAMPLE";
pub const TEST_CREDS = Credentials{
    .access_id = TEST_ID,
    .access_secret = TEST_SECRET,
};

/// Provides a shared identity cache for multiple SDK clients.
pub const SharedManager = struct {
    allocator: Allocator,
    tracker: SharedResource = .{},
    manager: Manager = undefined,
    resolvers: []const IdentityResolver,

    const standard_resolver = StandardCredsProvider{};
    const standard_chain: []const IdentityResolver = &.{standard_resolver.identityResolver()};

    /// Use the standard identity resoulution chain.
    pub fn initStandard(allocator: Allocator) SharedManager {
        return initChain(allocator, standard_chain);
    }

    /// Use a manual fallback chain of identity resolvers.
    pub fn initChain(allocator: Allocator, resolvers: []const IdentityResolver) SharedManager {
        return .{
            .allocator = allocator,
            .resolvers = resolvers,
        };
    }

    pub fn deinit(self: *SharedManager) void {
        const count = self.tracker.countSafe();
        if (count == 0) return;

        log.warn("Deinit shared Identity Manager while still used by {d} SDK clients.", .{count});
        self.manager.forceDeinit();
        self.* = undefined;
    }

    pub fn retain(self: *SharedManager) *Manager {
        self.tracker.retainCallback(createManager, self);
        return &self.manager;
    }

    pub fn release(self: *SharedManager, cache: *Manager) void {
        assert(@intFromPtr(&self.manager) == @intFromPtr(cache));
        self.tracker.releaseCallback(destroyManager, self);
    }

    fn createManager(self: *SharedManager) void {
        self.manager = Manager.init(self.allocator, self.resolvers);
        self.manager.shared = self;
    }

    fn destroyManager(self: *SharedManager) void {
        self.manager.forceDeinit();
    }
};

pub const Manager = struct {
    allocator: Allocator,
    resolvers: []const IdentityResolver,
    cache: std.ArrayListUnmanaged(Identity) = .{},
    /// Maximum duration in seconds to cache an identity.
    max_cache_duration: u32 = 15 * std.time.s_per_min,
    /// Dureation in seconds before the specified expiration to consider an identity expired.
    expiration_buffer: f32 = 10,
    prng: std.Random.DefaultPrng,
    rand: ?std.Random = null,
    shared: ?*SharedManager = null,

    pub fn init(allocator: Allocator, resolvers: []const IdentityResolver) Manager {
        return .{
            .allocator = allocator,
            .resolvers = resolvers,
            .prng = .init(blk: {
                var seed: u64 = undefined;
                std.posix.getrandom(std.mem.asBytes(&seed)) catch @panic("posix random failed");
                break :blk seed;
            }),
        };
    }

    pub fn deinit(self: *Manager) void {
        if (self.shared) |p| p.release(self) else self.forceDeinit();
    }

    fn forceDeinit(self: *Manager) void {
        for (self.cache.items) |identity| identity.resolver.destroy(identity, self.allocator);
        self.cache.deinit(self.allocator);
    }

    pub fn resolve(self: *Manager, kind: Identity.Kind) !Identity {
        if (self.resolvers.len == 0) return error.NoIdentityResolvers;
        if (self.rand == null) self.rand = self.prng.random();

        var i: usize = 0;
        const now = std.time.timestamp();
        while (i < self.cache.items.len) {
            const identity = self.cache.items[i];
            if (identity.expiration != null and identity.expiration.? < now) {
                identity.resolver.destroy(identity, self.allocator);
                _ = self.cache.orderedRemove(i);
            } else if (identity.kind == kind) {
                return identity;
            } else {
                i += 1;
            }
        }

        for (self.resolvers) |resolver| {
            var identity = (try resolver.resolve(self.allocator, kind)) orelse continue;
            errdefer resolver.destroy(identity, self.allocator);

            const max = std.time.timestamp() + self.max_cache_duration; // Refresh time in case of a remote resolver
            const expire = if (identity.expiration) |exp| @min(exp, max) else max;
            const jitter: u32 = @intFromFloat(self.expiration_buffer * self.rand.?.float(f32));
            identity.expiration = expire - jitter;

            try self.cache.append(self.allocator, identity);
            return identity;
        }

        return error.CantResolveIdentity;
    }

    pub fn release(self: *Manager, identity: Identity) void {
        const resolver = identity.resolver;
        resolver.destroy(identity, self.allocator);
    }
};

/// An opaque identity type used for authenticating requests.
const Identity = struct {
    kind: Kind,
    expiration: ?i64,
    data: *const anyopaque,
    resolver: IdentityResolver,

    pub const Kind = enum { credentials, token, login };

    pub fn as(self: Identity, comptime kind: Kind) KindType(kind) {
        assert(self.kind == kind);
        const cast: *const KindType(kind) = @ptrCast(@alignCast(self.data));
        return cast.*;
    }

    fn KindType(comptime kind: Kind) type {
        return switch (kind) {
            .credentials => Credentials,
            .token => Token,
            .login => Login,
        };
    }
};

/// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/feature-static-credentials.html)
pub const Credentials = struct {
    /// The access key ID.
    access_id: []const u8,
    /// The secret access key.
    access_secret: []const u8,
    /// The session token (optional).
    session_token: ?[]const u8 = null,

    pub fn validSlicesLength(self: Credentials) bool {
        return self.access_id.len == CREDS_ID_LEN and self.access_secret.len == CREDS_SECRET_LEN;
    }

    pub fn deinit(self: Credentials, allocator: Allocator) void {
        allocator.free(self.access_id);
        allocator.free(self.access_secret);
        if (self.session_token) |token| allocator.free(token);
    }

    /// Deep copy of the value strings.
    pub fn clone(self: Credentials, allocator: Allocator) !Credentials {
        const access_id = try allocator.dupe(u8, self.access_id);
        errdefer allocator.free(access_id);

        const access_secret = try allocator.dupe(u8, self.access_secret);
        errdefer allocator.free(access_secret);

        const session_token = if (self.session_token) |s| try allocator.dupe(u8, s) else null;
        errdefer if (session_token) |token| allocator.free(token);

        return .{
            .access_id = access_id,
            .access_secret = access_secret,
            .session_token = session_token,
        };
    }
};

/// Identity type required to sign requests using Smithy’s token-based HTTP auth schemes.
pub const Token = struct {
    /// The token value.
    value: []const u8,
};

/// Identity type required to sign requests using Smithy’s login-based HTTP auth schemes.
pub const Login = struct {
    /// The user ID.
    user: []const u8,
    /// The user password.
    password: []const u8,
};

pub const IdentityResolver = struct {
    ctx: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        resolve: *const fn (ctx: *const anyopaque, allocator: Allocator, kind: Identity.Kind) anyerror!?Identity,
        destroy: *const fn (ctx: *const anyopaque, identity: Identity, allocator: Allocator) void,
    };

    pub inline fn resolve(self: IdentityResolver, allocator: Allocator, kind: Identity.Kind) anyerror!?Identity {
        return self.vtable.resolve(self.ctx, allocator, kind);
    }

    pub inline fn destroy(self: IdentityResolver, identity: Identity, allocator: Allocator) void {
        self.vtable.destroy(self.ctx, identity, allocator);
    }
};

pub const StandardCredsProvider = struct {
    pub fn identityResolver(self: *const StandardCredsProvider) IdentityResolver {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    const vtable = IdentityResolver.VTable{
        .resolve = resolve,
        .destroy = destroy,
    };

    fn ctxSelf(ctx: *const anyopaque) *const StandardCredsProvider {
        return @ptrCast(@alignCast(ctx));
    }

    fn resolve(ctx: *const anyopaque, allocator: Allocator, kind: Identity.Kind) !?Identity {
        if (kind != .credentials) return null;

        const aws_env = try conf_env.loadEnvironment(allocator);
        defer conf_env.releaseEnvironment();

        var access_id: ?[]const u8 = aws_env.access_id;
        var access_secret: ?[]const u8 = aws_env.access_secret;
        var session_token: ?[]const u8 = aws_env.session_token;

        var file0: ?conf_profile.AwsConfigFile = null;
        defer if (file0) |f| f.deinit();

        if (session_token == null or access_secret == null or access_id == null) blk: {
            file0 = try conf_profile.readCredsFile(allocator, aws_env.credentials_file);
            const cfg = file0.?.getProfile(aws_env.profile_name) orelse break :blk;
            if (access_id == null) access_id = cfg.access_id;
            if (access_secret == null) access_secret = cfg.access_secret;
            if (session_token == null) session_token = cfg.session_token;
        }

        var file1: ?conf_profile.AwsConfigFile = null;
        defer if (file1) |f| f.deinit();

        if (session_token == null or access_secret == null or access_id == null) blk: {
            file1 = try conf_profile.readCredsFile(allocator, aws_env.config_file);
            const cfg = file1.?.getProfile(aws_env.profile_name) orelse break :blk;
            if (access_id == null) access_id = cfg.access_id;
            if (access_secret == null) access_secret = cfg.access_secret;
            if (session_token == null) session_token = cfg.session_token;
        }

        if (access_id != null and access_secret != null) {
            const creds_id = try allocator.dupe(u8, access_id.?);
            errdefer allocator.free(creds_id);

            const creds_secret = try allocator.dupe(u8, access_secret.?);
            errdefer allocator.free(creds_secret);

            const creds_token = if (session_token) |s| try allocator.dupe(u8, s) else null;
            errdefer if (creds_token) |token| allocator.free(token);

            const creds = try allocator.create(Credentials);
            creds.* = .{
                .access_id = creds_id,
                .access_secret = creds_secret,
                .session_token = creds_token,
            };

            return .{
                .data = creds,
                .kind = .credentials,
                .expiration = null,
                .resolver = ctxSelf(ctx).identityResolver(),
            };
        } else {
            return null;
        }
    }

    fn destroy(_: *const anyopaque, identity: Identity, allocator: Allocator) void {
        const creds: *const Credentials = @ptrCast(@alignCast(identity.data));
        creds.deinit(allocator);
        allocator.destroy(creds);
    }
};

pub const StaticCredsProvider = struct {
    creds: Credentials,

    pub fn from(id: []const u8, secret: []const u8) StaticCredsProvider {
        assert(id.len == CREDS_ID_LEN);
        assert(secret.len == CREDS_SECRET_LEN);

        return .{ .creds = .{
            .access_id = id,
            .access_secret = secret,
        } };
    }

    pub fn identityResolver(self: *const StaticCredsProvider) IdentityResolver {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    const vtable = IdentityResolver.VTable{
        .resolve = resolve,
        .destroy = destroy,
    };

    fn ctxSelf(ctx: *const anyopaque) *const StaticCredsProvider {
        return @ptrCast(@alignCast(ctx));
    }

    fn resolve(ctx: *const anyopaque, _: Allocator, kind: Identity.Kind) anyerror!?Identity {
        const self = ctxSelf(ctx);
        if (kind != .credentials) return null;
        return .{
            .data = &self.creds,
            .kind = .credentials,
            .expiration = null,
            .resolver = self.identityResolver(),
        };
    }

    fn destroy(ctx: *const anyopaque, identity: Identity, _: Allocator) void {
        // noop
        assert(@intFromPtr(identity.data) == @intFromPtr(&ctxSelf(ctx).creds));
    }
};

test StaticCredsProvider {
    var static = StaticCredsProvider.from(TEST_ID, TEST_SECRET);
    const static_resolver = static.identityResolver();

    const identity = (try static_resolver.resolve(test_alloc, .credentials)).?;
    defer static_resolver.destroy(identity, test_alloc);
    try testing.expectEqual(null, identity.expiration);
    try testing.expectEqual(.credentials, identity.kind);

    const creds = identity.as(.credentials);
    try testing.expectEqualStrings(TEST_ID, creds.access_id);
    try testing.expectEqualStrings(TEST_SECRET, creds.access_secret);
    try testing.expectEqual(null, creds.session_token);
}

pub const EnvironmentCredsProvider = struct {
    pub fn identityResolver(self: *const EnvironmentCredsProvider) IdentityResolver {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    const vtable = IdentityResolver.VTable{
        .resolve = resolve,
        .destroy = destroy,
    };

    fn ctxSelf(ctx: *const anyopaque) *const EnvironmentCredsProvider {
        return @ptrCast(@alignCast(ctx));
    }

    fn resolve(ctx: *const anyopaque, allocator: Allocator, kind: Identity.Kind) !?Identity {
        if (kind != .credentials) return null;

        _ = try conf_env.loadEnvironment(allocator);
        defer conf_env.releaseEnvironment();

        const access_id = try allocator.dupe(u8, conf_env.readValue(.access_id) orelse return null);
        errdefer allocator.free(access_id);

        const access_secret = try allocator.dupe(u8, conf_env.readValue(.access_secret) orelse return null);
        errdefer allocator.free(access_secret);

        const session_token = if (conf_env.readValue(.session_token)) |s| try allocator.dupe(u8, s) else null;
        errdefer if (session_token) |token| allocator.free(token);

        const creds = try allocator.create(Credentials);
        creds.* = .{
            .access_id = access_id,
            .access_secret = access_secret,
            .session_token = session_token,
        };

        return .{
            .data = creds,
            .kind = .credentials,
            .expiration = null,
            .resolver = ctxSelf(ctx).identityResolver(),
        };
    }

    fn destroy(_: *const anyopaque, identity: Identity, allocator: Allocator) void {
        const creds: *const Credentials = @ptrCast(@alignCast(identity.data));
        creds.deinit(allocator);
        allocator.destroy(creds);
    }
};

test EnvironmentCredsProvider {
    _ = try conf_env.loadEnvironment(test_alloc);
    defer conf_env.releaseEnvironment();

    conf_env.overrideValue(.access_id, TEST_ID);
    conf_env.overrideValue(.access_secret, TEST_SECRET);

    const static: EnvironmentCredsProvider = .{};
    const static_resolver = static.identityResolver();

    const identity = (try static_resolver.resolve(test_alloc, .credentials)).?;
    defer static_resolver.destroy(identity, test_alloc);
    try testing.expectEqual(null, identity.expiration);
    try testing.expectEqual(.credentials, identity.kind);

    const creds = identity.as(.credentials);
    try testing.expectEqualStrings(TEST_ID, creds.access_id);
    try testing.expectEqualStrings(TEST_SECRET, creds.access_secret);
    try testing.expectEqual(null, creds.session_token);
}

pub const SharedFilesProvider = struct {
    /// The profile name to use, or `null` to use the _default_ profile.
    profile_name: ?[]const u8 = null,
    /// Override the standard shared credentials and configuration files location.
    /// The first path gets presedence over the second.
    /// Supports `~/` home directory expansion.
    override_paths: ?[2][]const u8 = null,

    pub fn identityResolver(self: *const SharedFilesProvider) IdentityResolver {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    const vtable = IdentityResolver.VTable{
        .resolve = resolve,
        .destroy = destroy,
    };

    fn ctxSelf(ctx: *const anyopaque) *const SharedFilesProvider {
        return @ptrCast(@alignCast(ctx));
    }

    fn resolve(ctx: *const anyopaque, allocator: Allocator, kind: Identity.Kind) !?Identity {
        const self = ctxSelf(ctx);
        if (kind != .credentials) return null;

        var access_id: ?[]const u8 = null;
        var access_secret: ?[]const u8 = null;
        var session_token: ?[]const u8 = null;

        const file0 = try conf_profile.readCredsFile(allocator, if (self.override_paths) |p| p[0] else null);
        defer file0.deinit();

        if (file0.getProfile(self.profile_name)) |cfg| {
            access_id = cfg.access_id;
            access_secret = cfg.access_secret;
            session_token = cfg.session_token;
        }

        var file1: ?conf_profile.AwsConfigFile = null;
        defer if (file1) |f| f.deinit();

        if (session_token == null or access_secret == null or access_id == null) blk: {
            file1 = try conf_profile.readCredsFile(allocator, if (self.override_paths) |p| p[1] else null);
            const cfg = file1.?.getProfile(self.profile_name) orelse break :blk;
            if (access_id == null) access_id = cfg.access_id;
            if (access_secret == null) access_secret = cfg.access_secret;
            if (session_token == null) session_token = cfg.session_token;
        }

        if (access_id != null and session_token != null) {
            const creds_id = try allocator.dupe(u8, access_id.?);
            errdefer allocator.free(creds_id);

            const creds_secret = try allocator.dupe(u8, access_secret.?);
            errdefer allocator.free(creds_secret);

            const creds_token = if (session_token) |s| try allocator.dupe(u8, s) else null;
            errdefer if (creds_token) |token| allocator.free(token);

            const creds = try allocator.create(Credentials);
            creds.* = .{
                .access_id = creds_id,
                .access_secret = creds_secret,
                .session_token = creds_token,
            };

            return .{
                .data = creds,
                .kind = .credentials,
                .expiration = null,
                .resolver = self.identityResolver(),
            };
        } else {
            return null;
        }
    }

    fn destroy(_: *const anyopaque, identity: Identity, allocator: Allocator) void {
        const creds: *const Credentials = @ptrCast(@alignCast(identity.data));
        creds.deinit(allocator);
        allocator.destroy(creds);
    }
};

test SharedFilesProvider {
    var buff_1: [128]u8 = undefined;
    var buff_2: [128]u8 = undefined;
    const static: SharedFilesProvider = .{
        .override_paths = .{
            try std.fs.cwd().realpath("runtime/testing/aws_credentials", &buff_1),
            try std.fs.cwd().realpath("runtime/testing/aws_config", &buff_2),
        },
    };
    const static_resolver = static.identityResolver();

    const identity = (try static_resolver.resolve(test_alloc, .credentials)).?;
    defer static_resolver.destroy(identity, test_alloc);
    try testing.expectEqual(null, identity.expiration);
    try testing.expectEqual(.credentials, identity.kind);

    const creds = identity.as(.credentials);
    try testing.expectEqualStrings(TEST_ID, creds.access_id);
    try testing.expectEqualStrings(TEST_SECRET, creds.access_secret);
    try testing.expectEqualStrings(TEST_TOKEN, creds.session_token.?);
}
