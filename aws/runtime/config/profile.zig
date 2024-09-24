//! https://docs.aws.amazon.com/sdkref/latest/guide/file-format.html
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ZigType = std.builtin.Type;
const testing = std.testing;
const test_alloc = testing.allocator;
const Entry = @import("entries.zig").Entry;
const entries = @import("entries.zig").profile_entries;
const Region = @import("../infra/region.gen.zig").Region;
const Credentials = @import("../auth/identity.zig").Credentials;
const fs = @import("../utils/fs.zig");

const log = std.log.scoped(.aws_sdk);

/// If `path` is empty will use the defaule credentials file.
pub fn readCredsFile(allocator: Allocator, override_path: ?[]const u8) !AwsCredsFile {
    var buffer: [4096]u8 = undefined;
    const source = try readFile(&buffer, override_path, "~/.aws/credentials", "%USERPROFILE%\\.aws\\credentials");
    return parseCredsIni(allocator, source);
}

/// If `path` is empty will use the defaule configuration file.
pub fn readConfigFile(allocator: Allocator, override_path: ?[]const u8) !AwsConfigFile {
    var buffer: [4096]u8 = undefined;
    const source = try readFile(&buffer, override_path, "~/.aws/config", "%USERPROFILE%\\.aws\\config");
    return parseConfigIni(allocator, source);
}

fn readFile(
    buffer: []u8,
    override_path: ?[]const u8,
    comptime nix_path: []const u8,
    comptime windows_path: []const u8,
) ![]const u8 {
    const os = comptime @import("builtin").os.tag;
    var fixed = std.heap.FixedBufferAllocator.init(buffer);
    const fixed_alloc = fixed.allocator();

    var path = override_path orelse switch (os) {
        .windows => windows_path,
        .linux, .macos => nix_path,
        else => @compileError("unsupported os"),
    };

    if (mem.startsWith(u8, path, "~/") or (os == .windows and mem.startsWith(u8, path, "~\\"))) {
        const s = (try fs.getPath(.{}, fixed_alloc, .home)) orelse return error.CanNotResolveHome;
        const src_len = path.len - 1;
        _ = try fixed_alloc.dupe(u8, path[1..][0..src_len]);
        path = buffer[0 .. s.len + src_len];
    } else if (os == .windows and mem.startsWith(u8, path, "%USERPROFILE%\\")) {
        const s = (try fs.getPath(.{}, fixed_alloc, .home)) orelse return error.CanNotResolveHome;
        const src_len = path.len - 13;
        _ = try fixed_alloc.dupe(u8, path[13..][0..src_len]);
        path = buffer[0 .. s.len + src_len];
    }

    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const max_size = fixed.buffer.len - fixed.end_index;
    return file.readToEndAllocOptions(fixed_alloc, max_size, max_size, @alignOf(u8), null);
}

pub const AwsCredsFile = struct {
    allocator: Allocator,
    creds: std.StringHashMapUnmanaged(Credentials),

    pub fn deinit(self: *AwsCredsFile) void {
        var it = self.creds.valueIterator();
        while (it.next()) |creds| creds.deinit(self.allocator);
        self.creds.deinit(self.allocator);
    }

    /// Leave `name` empty to use the default profile.
    pub fn getCreds(self: AwsCredsFile, name: ?[]const u8) ?Credentials {
        return self.creds.get(name orelse "default");
    }

    /// Allocates the string values.
    /// Leave `name` empty to use the default profile.
    pub fn getCredsAlloc(self: AwsCredsFile, allocator: Allocator, name: ?[]const u8) !?Credentials {
        const creds = self.creds.get(name orelse "default") orelse return null;
        return try creds.clone(allocator);
    }
};

fn parseCredsIni(allocator: Allocator, source: []const u8) !AwsCredsFile {
    var partial: PartialCreds = .{};
    var map: std.StringHashMapUnmanaged(Credentials) = .{};

    errdefer {
        var it = map.valueIterator();
        while (it.next()) |creds| creds.deinit(allocator);
        map.deinit(allocator);
        partial.deinit(allocator);
    }

    var fragments = IniFragmenter.init(source);
    while (fragments.next()) |fragment| {
        switch (fragment) {
            inline .section, .section_default => |s, g| {
                if (!partial.isEmpty()) {
                    const name, const creds = try partial.consume();
                    try map.put(allocator, name, creds);
                }

                partial.name = if (g == .section) s else null;
            },
            .setting => |entry| {
                if (mem.eql(u8, "aws_access_key_id", entry.key)) {
                    partial.access_id = try allocator.dupe(u8, entry.value);
                } else if (mem.eql(u8, "aws_secret_access_key", entry.key)) {
                    partial.access_secret = try allocator.dupe(u8, entry.value);
                } else if (mem.eql(u8, "aws_session_token", entry.key)) {
                    partial.session_token = try allocator.dupe(u8, entry.value);
                } else {
                    return error.InvalidCredsFileSetting;
                }
            },
            else => return error.InvalidCredsFileSetting,
        }
    } else if (!partial.isEmpty()) {
        const name, const creds = try partial.consume();
        try map.put(allocator, name, creds);
    }

    return .{
        .allocator = allocator,
        .creds = map.move(),
    };
}

const PartialCreds = struct {
    name: ?[]const u8 = null,
    access_id: ?[]const u8 = null,
    access_secret: ?[]const u8 = null,
    session_token: ?[]const u8 = null,

    pub fn deinit(self: PartialCreds, allocator: Allocator) void {
        if (self.name) |s| allocator.free(s);
        if (self.access_id) |s| allocator.free(s);
        if (self.access_secret) |s| allocator.free(s);
        if (self.session_token) |s| allocator.free(s);
    }

    pub fn isEmpty(self: PartialCreds) bool {
        return self.name == null and
            self.access_id == null and
            self.access_secret == null and
            self.session_token == null;
    }

    pub fn consume(self: *PartialCreds) !struct { []const u8, Credentials } {
        const creds = Credentials{
            .access_id = self.access_id orelse return error.IncompleteCredsFile,
            .access_secret = self.access_secret orelse return error.IncompleteCredsFile,
            .session_token = self.session_token,
        };

        defer self.* = .{};
        return .{ self.name orelse "default", creds };
    }
};

test parseCredsIni {
    const settings =
        \\aws_access_key_id=AKIAIOSFODNN7EXAMPLE
        \\aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
    ;
    const source = "[default]\n" ++ settings ++ "\n\n# Comment\n[foo]\n" ++ settings ++
        "\naws_session_token=IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZVERYLONGSTRINGEXAMPLE";

    var config = try parseCredsIni(test_alloc, source);
    defer config.deinit();

    try testing.expectEqual(null, config.getCreds(""));

    try testing.expectEqualDeep(Credentials{
        .access_id = "AKIAIOSFODNN7EXAMPLE",
        .access_secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    }, config.getCreds(null).?);

    try testing.expectEqualDeep(Credentials{
        .access_id = "AKIAIOSFODNN7EXAMPLE",
        .access_secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        .session_token = "IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZVERYLONGSTRINGEXAMPLE",
    }, config.getCreds("foo").?);
}

pub const AwsConfigFile = struct {
    arena: std.heap.ArenaAllocator,
    profiles: std.StringHashMapUnmanaged(Profile),
    sso_sessions: std.StringHashMapUnmanaged(SsoSession),
    services: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(Service)),

    pub fn deinit(self: AwsConfigFile) void {
        self.arena.deinit();
    }

    /// Leave `name` empty to use the default profile.
    pub fn getProfile(self: AwsConfigFile, name: ?[]const u8) ?Profile {
        return self.profiles.get(name orelse "default");
    }

    pub fn getSsoSession(self: AwsConfigFile, name: []const u8) ?SsoSession {
        return self.sso_sessions.get(name);
    }

    pub fn getService(self: AwsConfigFile, profile: []const u8, service: []const u8) ?Service {
        const services = self.services.get(profile) orelse return null;
        return services.get(service);
    }

    pub const SsoSession = struct {
        region: ?Region = null,
        role_name: ?[]const u8 = null,
        start_url: ?[]const u8 = null,
        account_id: ?[]const u8 = null,
        scopes: ?[]const u8 = null,
    };

    pub const Service = struct {
        endpoint_url: ?[]const u8 = null,
    };

    pub const Profile: type = blk: {
        var fields_len: usize = 0;
        var fields: [entries.kvs.len + 2]ZigType.StructField = undefined;

        for (0..entries.kvs.len) |i| {
            const entry = entries.kvs.values[i];

            var name: [entry.field.len:0]u8 = undefined;
            @memcpy(name[0..entry.field.len], entry.field);

            const T = entry.Type();
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

        const default_opt_str: ?[]const u8 = null;
        for (.{ "services", "sso_session" }) |field| {
            fields[fields_len] = ZigType.StructField{
                .name = field,
                .type = ?[]const u8,
                .default_value = &default_opt_str,
                .is_comptime = false,
                .alignment = @alignOf(?[]const u8),
            };
            fields_len += 1;
        }

        break :blk @Type(.{ .@"struct" = .{
            .layout = .auto,
            .fields = fields[0..fields_len],
            .decls = &.{},
            .is_tuple = false,
        } });
    };
};

fn parseConfigIni(allocator: Allocator, source: []const u8) !AwsConfigFile {
    var arena = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();
    errdefer arena.deinit();

    var profiles: std.StringHashMapUnmanaged(AwsConfigFile.Profile) = .{};
    defer profiles.deinit(allocator);

    var sso_sessions: std.StringHashMapUnmanaged(AwsConfigFile.SsoSession) = .{};
    defer sso_sessions.deinit(allocator);

    var services: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(AwsConfigFile.Service)) = .{};
    defer services.deinit(allocator);

    var fragments = IniFragmenter.init(source);
    if (fragments.peek()) |f| if (f.isAnySettings()) {
        const profile = try parseConfigProfile(arena_alloc, &fragments);
        try profiles.putNoClobber(allocator, "default", profile);
    };

    while (fragments.next()) |fragment| {
        switch (fragment) {
            inline .section_default, .section_profile => |s, g| {
                const name: []const u8 = if (g == .section_profile) s else "default";
                const profile = try parseConfigProfile(arena_alloc, &fragments);
                try profiles.put(allocator, name, profile);
            },
            .section_services => |name| {
                const service = try parseConfigServices(allocator, arena_alloc, &fragments);
                try services.put(allocator, name, service);
            },
            .section_sso => |name| {
                const session = try parseConfigSsoSession(arena_alloc, &fragments);
                try sso_sessions.put(allocator, name, session);
            },
            else => return error.InvalidConfigFileSection,
        }
    }

    var dupe_profiles = try profiles.clone(arena_alloc);
    errdefer dupe_profiles.deinit(allocator);

    var dupe_services = try services.clone(arena_alloc);
    errdefer dupe_services.deinit(allocator);

    return .{
        .arena = arena,
        .profiles = dupe_profiles,
        .services = dupe_services,
        .sso_sessions = try sso_sessions.clone(arena_alloc),
    };
}

fn parseConfigProfile(allocator: Allocator, fragments: *IniFragmenter) !AwsConfigFile.Profile {
    var profile: AwsConfigFile.Profile = .{};

    while (fragments.peek()) |f| {
        if (f != .setting) break;
        const setting = fragments.next().?.setting;
        if (entries.get(setting.key)) |entry| {
            inline for (comptime entries.values()) |e| {
                if (mem.eql(u8, e.field, entry.field)) {
                    @field(profile, e.field) = try e.parseAlloc(allocator, setting.value);
                    break;
                }
            }
        } else if (mem.eql(u8, "sso_session", setting.key)) {
            profile.sso_session = try allocator.dupe(u8, setting.value);
        } else if (mem.eql(u8, "services", setting.key)) {
            profile.services = try allocator.dupe(u8, setting.value);
        } else {
            log.warn("Unknown service setting: `{s}`", .{setting.key});
            return error.InvalidProfileSetting;
        }
    }

    return profile;
}

fn parseConfigSsoSession(allocator: Allocator, fragments: *IniFragmenter) !AwsConfigFile.SsoSession {
    var session: AwsConfigFile.SsoSession = .{};
    while (fragments.peek()) |f| {
        if (f != .setting) break;
        const setting = fragments.next().?.setting;
        if (mem.eql(u8, "sso_region", setting.key)) {
            session.region = Region.parse(setting.value).?;
        } else if (mem.eql(u8, "sso_start_url", setting.key)) {
            session.start_url = try allocator.dupe(u8, setting.value);
        } else if (mem.eql(u8, "sso_registration_scopes", setting.key)) {
            session.scopes = try allocator.dupe(u8, setting.value);
        } else if (mem.eql(u8, "sso_account_id", setting.key)) {
            session.account_id = try allocator.dupe(u8, setting.value);
        } else if (mem.eql(u8, "sso_role_name", setting.key)) {
            session.role_name = try allocator.dupe(u8, setting.value);
        } else {
            log.warn("Unknown service setting: `{s}`", .{setting.key});
            return error.InvalidProfileSetting;
        }
    }
    return session;
}

fn parseConfigServices(
    gpa_alloc: Allocator,
    arena_alloc: Allocator,
    fragments: *IniFragmenter,
) !std.StringHashMapUnmanaged(AwsConfigFile.Service) {
    var services: std.StringHashMapUnmanaged(AwsConfigFile.Service) = .{};
    defer services.deinit(gpa_alloc);

    var name: ?[]const u8 = null;
    var service: AwsConfigFile.Service = .{};

    while (fragments.peek()) |f| {
        if (!f.isAnySettings()) break;
        switch (fragments.next().?) {
            .setting_scope => |s| {
                if (name) |n| try services.put(gpa_alloc, n, service);
                name = s;
                service = .{};
            },
            .setting_nested => |setting| {
                if (name == null) return error.InvalidConfigFileSetting;
                if (mem.eql(u8, "endpoint_url", setting.key)) {
                    service.endpoint_url = try arena_alloc.dupe(u8, setting.value);
                } else {
                    log.warn("Unknown service setting: `{s}`", .{setting.key});
                    return error.InvalidProfileSetting;
                }
            },
            else => unreachable,
        }
    } else if (name) |n| {
        try services.put(gpa_alloc, n, service);
    }

    return services.clone(arena_alloc);
}

test parseConfigIni {
    const source =
        \\#Full line comment, this text is ignored.
        \\region = us-east-2
        \\
        \\[profile foo]
        \\region = il-central-1
        \\services = local-srvc
        \\sso_session = my-sso
        \\sso_role_name = SampleRole
        \\
        \\[sso-session my-sso]
        \\sso_region = us-east-1
        \\sso_start_url = https://my-sso-portal.awsapps.com/start
        \\
        \\[services local-srvc]
        \\dynamodb =
        \\  endpoint_url = http://localhost:8000
    ;
    var config = try parseConfigIni(test_alloc, source);
    defer config.deinit();

    try testing.expectEqual(null, config.getProfile(""));
    try testing.expectEqual(null, config.getSsoSession(""));
    try testing.expectEqual(null, config.getService("", "dynamodb"));
    try testing.expectEqual(null, config.getService("local-srvc", ""));

    try testing.expectEqualDeep(AwsConfigFile.Profile{
        .region = .us_east_2,
    }, config.getProfile(null).?);

    try testing.expectEqualDeep(AwsConfigFile.Profile{
        .region = .il_central_1,
        .sso_session = "my-sso",
        .sso_role_name = "SampleRole",
        .services = "local-srvc",
    }, config.getProfile("foo").?);

    try testing.expectEqualDeep(AwsConfigFile.Service{
        .endpoint_url = "http://localhost:8000",
    }, config.getService("local-srvc", "dynamodb").?);

    try testing.expectEqualDeep(AwsConfigFile.SsoSession{
        .region = .us_east_1,
        .start_url = "https://my-sso-portal.awsapps.com/start",
    }, config.getSsoSession("my-sso").?);
}

const IniFragment = union(enum) {
    invalid,
    section: []const u8,
    section_default,
    section_sso: []const u8,
    section_profile: []const u8,
    section_services: []const u8,
    setting: struct { key: []const u8, value: []const u8 },
    setting_nested: struct { key: []const u8, value: []const u8 },
    setting_scope: []const u8,

    pub fn isAnySettings(self: IniFragment) bool {
        return switch (self) {
            .setting, .setting_nested, .setting_scope => true,
            else => false,
        };
    }
};

const IniFragmenter = struct {
    tokens: mem.TokenIterator(u8, .scalar),
    nested_scope: bool = false,

    pub fn init(source: []const u8) IniFragmenter {
        return .{ .tokens = mem.tokenizeScalar(u8, source, '\n') };
    }

    pub fn next(self: *IniFragmenter) ?IniFragment {
        while (self.tokens.next()) |s| {
            if (s.len > 0 and s[0] != '#') return self.parseFragment(true, s);
        } else {
            return null;
        }
    }

    pub fn peek(self: *IniFragmenter) ?IniFragment {
        while (self.tokens.peek()) |s| {
            if (s.len > 0 and s[0] != '#') {
                return self.parseFragment(false, s);
            } else {
                self.tokens.index += s.len;
            }
        } else {
            return null;
        }
    }

    fn parseFragment(self: *IniFragmenter, comptime mutate: bool, ln: []const u8) IniFragment {
        const nested_line = mem.indexOf(u8, &std.ascii.whitespace, ln[0..1]) != null;
        const line = mem.trim(u8, ln, &std.ascii.whitespace);

        if (line[0] == '[' and line[line.len - 1] == ']') {
            if (mutate) self.nested_scope = false;
            return parseSection(line);
        } else if (mem.indexOfScalar(u8, line, '=')) |i| {
            const key = mem.trimRight(u8, line[0..i], &std.ascii.whitespace);
            const value = if (line.len == i + 1) "" else mem.trimLeft(u8, line[i + 1 .. line.len], &std.ascii.whitespace);
            if (key.len == 0) return .invalid;

            if (value.len == 0) {
                // Scope
                if (self.nested_scope or nested_line) {
                    return .invalid;
                } else {
                    if (mutate) self.nested_scope = true;
                    return .{ .setting_scope = key };
                }
            } else if (nested_line) {
                // Scoped setting
                if (!self.nested_scope) return .invalid;
                return .{ .setting_nested = .{ .key = key, .value = value } };
            } else {
                // Setting (standard)
                if (mutate and self.nested_scope) self.nested_scope = false;
                return .{ .setting = .{ .key = key, .value = value } };
            }
        } else {
            return .invalid;
        }
    }

    fn parseSection(line: []const u8) IniFragment {
        // Remove brackets
        var value = mem.trim(u8, line[1 .. line.len - 1], &std.ascii.whitespace);

        var space_pos: ?usize = null;
        for (value, 0..) |c, i| {
            switch (c) {
                '0'...'9', 'A'...'Z', 'a'...'z', '-', '_' => {},
                ' ' => {
                    if (space_pos == null) space_pos = i else return .invalid;
                },
                else => return .invalid,
            }
        }

        if (space_pos) |i| blk: {
            const typ = value[0..i];
            const name = mem.trimLeft(u8, value[i + 1 .. value.len], &std.ascii.whitespace);
            if (name.len == 0) {
                value = typ;
                break :blk;
            }

            if (mem.eql(u8, "profile", typ)) {
                return .{ .section_profile = name };
            } else if (mem.eql(u8, "services", typ)) {
                return .{ .section_services = name };
            } else if (mem.eql(u8, "sso-session", typ)) {
                return .{ .section_sso = name };
            } else {
                log.warn("Unknown section profile type: `{s}`", .{typ});
                return .invalid;
            }
        }

        if (mem.eql(u8, "default", value)) {
            return .section_default;
        } else {
            return .{ .section = value };
        }
    }
};
