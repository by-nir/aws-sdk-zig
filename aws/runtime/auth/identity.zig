//! https://github.com/awslabs/aws-c-auth
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const SharedResource = @import("../utils/SharedResource.zig");

const log = std.log.scoped(.aws_sdk);

pub const CREDS_ID_LEN = 20;
pub const CREDS_SECRET_LEN = 40;

pub const TEST_ID: []const u8 = "AKIAIOSFODNN7EXAMPLE";
pub const TEST_SECRET: []const u8 = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
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

    /// Use the standard identity resoulution chain.
    pub fn initStandard(allocator: Allocator) SharedManager {
        return .{
            .allocator = allocator,
            .resolvers = &.{},
        };
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
    shared: ?*SharedManager = null,

    pub fn init(allocator: Allocator, resolvers: []const IdentityResolver) Manager {
        return .{
            .allocator = allocator,
            .resolvers = resolvers,
        };
    }

    pub fn deinit(self: *Manager) void {
        if (self.shared) |p| p.release(self) else self.forceDeinit();
    }

    fn forceDeinit(self: *Manager) void {
        _ = self; // autofix
    }

    pub fn TEMP_resolve(self: *Manager) !Identity {
        if (self.resolvers.len == 0) {
            return error.TEMP_MissingCredentials;
        } else {
            return self.resolvers[0].resolve(self.allocator);
        }
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
        resolve: *const fn (ctx: *const anyopaque, allocator: Allocator) anyerror!Identity,
        destroy: *const fn (ctx: *const anyopaque, identity: Identity, allocator: Allocator) void,
    };

    pub inline fn resolve(self: IdentityResolver, allocator: Allocator) anyerror!Identity {
        return self.vtable.resolve(self.ctx, allocator);
    }

    pub inline fn destroy(self: IdentityResolver, identity: Identity, allocator: Allocator) void {
        self.vtable.destroy(self.ctx, identity, allocator);
    }
};

pub const StaticCredentialsResolver = struct {
    creds: Credentials,

    pub fn from(id: []const u8, secret: []const u8) StaticCredentialsResolver {
        assert(id.len == CREDS_ID_LEN);
        assert(secret.len == CREDS_SECRET_LEN);

        return .{ .creds = .{
            .access_id = id,
            .access_secret = secret,
        } };
    }

    pub fn identityResolver(self: *const StaticCredentialsResolver) IdentityResolver {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    const vtable = IdentityResolver.VTable{
        .resolve = resolve,
        .destroy = destroy,
    };

    fn ctxSelf(ctx: *const anyopaque) *const StaticCredentialsResolver {
        return @ptrCast(@alignCast(ctx));
    }

    fn resolve(ctx: *const anyopaque, _: Allocator) anyerror!Identity {
        const self = ctxSelf(ctx);
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

test StaticCredentialsResolver {
    var static = StaticCredentialsResolver.from(TEST_ID, TEST_SECRET);
    const static_resolver = static.identityResolver();

    const identity = try static_resolver.resolve(test_alloc);
    defer static_resolver.destroy(identity, test_alloc);
    try testing.expectEqual(null, identity.expiration);
    try testing.expectEqual(.credentials, identity.kind);

    const creds = identity.as(.credentials);
    try testing.expectEqualStrings(TEST_ID, creds.access_id);
    try testing.expectEqualStrings(TEST_SECRET, creds.access_secret);
    try testing.expectEqual(null, creds.session_token);
}
