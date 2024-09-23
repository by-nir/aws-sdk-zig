// Extracted from:
// https://github.com/ziglibs/known-folders/blob/1cceeb70e77dec941a4178160ff6c8d05a74de6f/known-folders.zig

// MIT License
//
// Copyright (c) 2020 ziglibs
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

const std = @import("std");
const builtin = @import("builtin");

pub const KnownFolder = enum {
    /// Windows default: `%SystemDrive%\Users\%USERNAME%`
    ///   MacOS default: `$HOME`
    ///    *nix default: `$HOME`
    home,
    /// Windows default: `%USERPROFILE%\Documents`
    ///   MacOS default: `$HOME/Documents`
    ///    *nix default: `$HOME/Documents`
    ///   XDG directory: `XDG_DOCUMENTS_DIR`
    documents,
    /// Windows default: `%USERPROFILE%\Pictures`
    ///   MacOS default: `$HOME/Pictures`
    ///    *nix default: `$HOME/Pictures`
    ///   XDG directory: `XDG_PICTURES_DIR`
    pictures,
    /// Windows default: `%USERPROFILE%\Music`
    ///   MacOS default: `$HOME/Music`
    ///    *nix default: `$HOME/Music`
    ///   XDG directory: `XDG_MUSIC_DIR`
    music,
    /// Windows default: `%USERPROFILE%\Videos`
    ///   MacOS default: `$HOME/Movies`
    ///    *nix default: `$HOME/Videos`
    ///   XDG directory: `XDG_VIDEOS_DIR`
    videos,
    /// Windows default: `%USERPROFILE%\Desktop`
    ///   MacOS default: `$HOME/Desktop`
    ///    *nix default: `$HOME/Desktop`
    ///   XDG directory: `XDG_DESKTOP_DIR`
    desktop,
    /// Windows default: `%USERPROFILE%\Downloads`
    ///   MacOS default: `$HOME/Downloads`
    ///    *nix default: `$HOME/Downloads`
    ///   XDG directory: `XDG_DOWNLOAD_DIR`
    downloads,
    /// Windows default: `%PUBLIC%` (`%SystemDrive%\Users\Public`)
    ///   MacOS default: `$HOME/Public`
    ///    *nix default: `$HOME/Public`
    ///   XDG directory: `XDG_PUBLICSHARE_DIR`
    public,
    /// Windows default: `%windir%\Fonts`
    ///   MacOS default: `$HOME/Library/Fonts`
    ///    *nix default: `$HOME/.local/share/fonts`
    ///   XDG directory: `XDG_DATA_HOME/fonts`
    fonts,
    /// Windows default: `%APPDATA%\Microsoft\Windows\Start Menu`
    ///   MacOS default: `$HOME/Applications`
    ///    *nix default: `$HOME/.local/share/applications`
    ///   XDG directory: `XDG_DATA_HOME/applications`
    app_menu,
    /// The base directory relative to which user-specific non-essential (cached) data should be written.
    ///
    /// Windows:       `%LOCALAPPDATA%\Temp`
    ///   MacOS default: HOME/Library/Caches`
    ///    *nix default: HOME/.cache`
    ///   XDG directory: `XDG_CACHE_HOME`
    cache,
    /// The base directory relative to which user-specific configuration files should be written.
    ///
    /// Windows default: %APPDATA% (%USERPROFILE%\AppData\Roaming)
    ///   MacOS default: `$HOME/Library/Preferences`
    ///    *nix default: `$HOME/.config`
    ///   XDG directory: `XDG_CONFIG_HOME`
    roaming_configuration,
    /// The base directory relative to which user-specific configuration files should be written.
    ///
    /// Windows default: `%LOCALAPPDATA%` (`%USERPROFILE%\AppData\Local`)
    ///   MacOS default: `$HOME/Library/Application Support`
    ///    *nix default: `$HOME/.config`
    ///   XDG directory: `XDG_CONFIG_HOME`
    local_configuration,
    /// The base directory relative to which global configuration files should be searched.
    ///
    /// Windows default: `%ALLUSERSPROFILE%` (`%ProgramData%`, `%SystemDrive%\ProgramData`)
    ///   MacOS default: `/Library/Preferences`
    ///    *nix default: `/etc`
    ///   XDG directory: `XDG_CONFIG_DIRS` (first directory)
    global_configuration,
    /// The base directory relative to which user-specific data files should be written.
    ///
    /// Windows:       `%LOCALAPPDATA%\Temp`
    /// MacOS default: `$HOME/Library/Application Support`
    ///  *nix default: `$HOME/.local/share`
    /// XDG directory: `XDG_DATA_HOME`
    ///
    /// XDG's definition of `XDG_DATA_HOME`: There is a set of preference ordered base directories
    data,
    /// The base directory relative to which user-specific runtime files and other file objects should be placed.
    ///
    /// Windows:       `%LOCALAPPDATA%\Temp`
    /// MacOS default: `$HOME/Library/Application Support`
    ///  *nix default: no default (only set with `XDG_RUNTIME_DIR`)
    /// XDG directory: `XDG_RUNTIME_DIR`
    ///
    runtime,
    /// Get the directory that contains the current executable.
    executable_dir,
};

// Explicitly define possible errors to make it clearer what callers need to handle
pub const Error = error{ ParseError, OutOfMemory };

pub const KnownFolderConfig = struct {
    xdg_force_default: bool = false,
    xdg_on_mac: bool = false,
};

const OpenOptions = std.fs.Dir.OpenOptions;

/// Returns a directory handle, or, if the folder does not exist, `null`.
pub fn open(comptime config: KnownFolderConfig, allocator: std.mem.Allocator, folder: KnownFolder, args: OpenOptions) (std.fs.Dir.OpenError || Error)!?std.fs.Dir {
    const path = try getPath(config, allocator, folder) orelse return null;
    defer allocator.free(path);
    return try std.fs.cwd().openDir(path, args);
}

/// Returns the path to the folder or, if the folder does not exist, `null`.
pub fn getPath(comptime config: KnownFolderConfig, allocator: std.mem.Allocator, folder: KnownFolder) Error!?[]const u8 {
    var system: DefaultSystem = .{
        .config = config,
    };
    defer system.deinit();
    return getPathInner(DefaultSystem, &system, allocator, folder);
}

fn getPathInner(
    /// `DefaultDefaultSystem` or `TestingDefaultSystem`
    comptime System: type,
    system: *System,
    allocator: std.mem.Allocator,
    folder: KnownFolder,
) Error!?[]const u8 {
    if (folder == .executable_dir) {
        if (builtin.os.tag == .wasi) return null;
        return std.fs.selfExeDirPathAlloc(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
    }

    switch (builtin.os.tag) {
        .windows => {
            const funcs = struct {
                extern "shell32" fn SHGetKnownFolderPath(
                    rfid: *const std.os.windows.GUID,
                    dwFlags: std.os.windows.DWORD,
                    hToken: ?std.os.windows.HANDLE,
                    ppszPathL: *std.os.windows.PWSTR,
                ) callconv(std.os.windows.WINAPI) std.os.windows.HRESULT;
                extern "ole32" fn CoTaskMemFree(pv: std.os.windows.LPVOID) callconv(std.os.windows.WINAPI) void;
            };

            switch (getWindowsFolderSpec(folder)) {
                .by_guid => |guid| {
                    var dir_path_ptr: [*:0]u16 = undefined;
                    switch (funcs.SHGetKnownFolderPath(
                        &guid,
                        std.os.windows.KF_FLAG_CREATE,
                        null,
                        &dir_path_ptr,
                    )) {
                        std.os.windows.S_OK => {
                            defer funcs.CoTaskMemFree(@ptrCast(dir_path_ptr));
                            const global_dir = std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(dir_path_ptr)) catch |err| switch (err) {
                                error.UnexpectedSecondSurrogateHalf => return null,
                                error.ExpectedSecondSurrogateHalf => return null,
                                error.DanglingSurrogateHalf => return null,
                                error.OutOfMemory => return error.OutOfMemory,
                            };
                            return global_dir;
                        },
                        std.os.windows.E_OUTOFMEMORY => return error.OutOfMemory,
                        else => return null,
                    }
                },
                .by_env => |env_path| {
                    const env_var = std.process.getEnvVarOwned(allocator, env_path.env_var) catch |err| switch (err) {
                        error.EnvironmentVariableNotFound => return null,
                        error.InvalidWtf8 => return null,
                        error.OutOfMemory => |e| return e,
                    };

                    if (env_path.subdir) |sub_dir| {
                        defer allocator.free(env_var);
                        return try std.fs.path.join(allocator, &[_][]const u8{ env_var, sub_dir });
                    } else {
                        return env_var;
                    }
                },
            }
        },
        .macos => {
            if (system.config.xdg_on_mac) return try getPathXdg(System, system, allocator, folder);

            if (folder == .global_configuration) {
                // special case because the returned path is absolute
                return try allocator.dupe(u8, comptime getMacFolderSpec(.global_configuration));
            }

            const home_dir = try system.getenv(allocator, "HOME") orelse return null;

            if (folder == .home) {
                return try allocator.dupe(u8, home_dir);
            }

            const path = getMacFolderSpec(folder);
            return try std.fs.path.join(allocator, &.{ home_dir, path });
        },

        // Assume unix derivatives with XDG
        else => return try getPathXdg(System, system, allocator, folder),
    }
}

fn getPathXdg(
    /// `DefaultDefaultSystem` or `TestingDefaultSystem`
    comptime System: type,
    system: *System,
    allocator: std.mem.Allocator,
    folder: KnownFolder,
) Error!?[]const u8 {
    const folder_spec = getXdgFolderSpec(folder);

    fallback: {
        if (system.config.xdg_force_default and folder != .home)
            break :fallback;

        const env: []const u8, var env_owned: bool = env_opt: {
            if (try system.getenv(allocator, folder_spec.env.name)) |env_opt|
                break :env_opt .{ env_opt, false };

            if (system.config.xdg_force_default)
                break :fallback;

            if (!folder_spec.env.user_dir)
                break :fallback;

            const env = xdgUserDirLookup(System, system, allocator, folder_spec.env.name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break :fallback,
            } orelse break :fallback;

            break :env_opt .{ env, true };
        };
        defer if (env_owned) allocator.free(env);

        if (folder_spec.env.suffix) |suffix| {
            return try std.fs.path.join(allocator, &.{ env, suffix });
        }

        // XDG_CONFIG_DIRS is a sequence of directories that are separated with ':'
        if (folder == .global_configuration) {
            std.debug.assert(std.mem.eql(u8, folder_spec.env.name, "XDG_CONFIG_DIRS"));
            var iter = std.mem.splitScalar(u8, env, ':');
            return try allocator.dupe(u8, iter.first());
        }

        if (env_owned) {
            env_owned = false;
            return env;
        }

        return try allocator.dupe(u8, env);
    }

    const default = folder_spec.default orelse return null;
    if (default[0] == '~') {
        const home = try system.getenv(allocator, "HOME") orelse return null;
        return try std.fs.path.join(allocator, &.{ home, default[1..] });
    } else {
        return try allocator.dupe(u8, default);
    }
}

/// Encapsulates all operating system interactions
const DefaultSystem = struct {
    config: KnownFolderConfig, // = .{},
    envmap: if (builtin.os.tag == .wasi and !builtin.link_libc) ?std.process.EnvMap else ?void = null,

    pub fn deinit(system: *DefaultSystem) void {
        if (builtin.os.tag == .wasi and !builtin.link_libc) {
            if (system.envmap) |*envmap| envmap.deinit();
        }
    }

    /// Caller does **not** owns the returned memory.
    pub fn getenv(system: *DefaultSystem, allocator: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error!?[]const u8 {
        if (builtin.os.tag == .wasi and !builtin.link_libc) {
            if (system.envmap == null) {
                system.envmap = std.process.getEnvMap(allocator) catch return error.OutOfMemory;
            }
            return system.envmap.?.get(key);
        }
        return std.posix.getenv(key);
    }

    pub fn openFile(_: *DefaultSystem, dir_path: []const u8, sub_path: []const u8) std.fs.File.OpenError!std.fs.File {
        var dir = try std.fs.cwd().openDir(dir_path, .{});
        defer dir.close();
        return try dir.openFile(sub_path, .{});
    }
};

/// Encapsulates all operating system interactions which can be overriden for testing purposes.
const TestingSystem = struct {
    config: KnownFolderConfig,
    /// Specifies all accessible environment variables.
    ///
    /// Notable environment variables are `HOME`, `XDG_CONFIG_HOME` or `XDG_${FOLDER_NAME}_DIR`.
    env_map: []const struct { key: []const u8, value: ?[]const u8 } = &.{},
    /// Specifies all accessible files.
    ///
    /// This is only used for the `user-dirs.dirs` file but can easily be applied to any other file.
    files: []const struct { path: []const u8, data: ?[]const u8 } = &.{},

    tmp_dir: ?std.testing.TmpDir = null,

    comptime {
        std.debug.assert(builtin.os.tag != .windows);
    }

    pub fn deinit(impl: *TestingSystem) void {
        if (impl.tmp_dir) |*tmp_dir| tmp_dir.cleanup();
    }

    /// Asserts that the environment variable is specified in `TestingSystem.env_map`.
    ///
    /// Caller does **not** owns the returned memory.
    pub fn getenv(system: *TestingSystem, allocator: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error!?[]const u8 {
        {
            // This allocation will simulate the possibility of allocation failure using `std.testing.checkAllAllocationFailures`
            allocator.free(try allocator.alloc(u8, 1));
        }

        for (system.env_map) |kv| {
            if (std.mem.eql(u8, key, kv.key)) return kv.value;
        }
        system.deinit();
        std.debug.panic("the result of `getenv(\"{}\")` must explicitly specified in the TestingSystem", .{std.zig.fmtEscapes(key)});
    }

    /// Asserts that the file is specified in `TestingSystem.files`.
    pub fn openFile(system: *TestingSystem, dir_path: []const u8, sub_path: []const u8) std.fs.File.OpenError!std.fs.File {
        const file_path = std.fs.path.join(std.testing.allocator, &.{ dir_path, sub_path }) catch @panic("OOM");
        defer std.testing.allocator.free(file_path);

        const kv = for (system.files) |kv| {
            if (std.mem.eql(u8, file_path, kv.path)) break kv;
        } else {
            system.deinit();
            std.debug.panic("`openFile(\"{0}\", \"{1}\")` has been called on an unexpected file", .{ std.zig.fmtEscapes(dir_path), std.zig.fmtEscapes(sub_path) });
        };

        const data = kv.data orelse return error.FileNotFound;

        const tmp_dir = if (system.tmp_dir) |*tmp_dir| tmp_dir else blk: {
            system.tmp_dir = std.testing.tmpDir(.{});
            break :blk &system.tmp_dir.?;
        };

        const buffer_size = std.base64.standard.Encoder.calcSize(kv.path.len);
        const buffer = std.testing.allocator.alloc(u8, buffer_size) catch @panic("OOM");
        defer std.testing.allocator.free(buffer);

        const prefix = std.base64.standard.Encoder.encode(buffer, kv.path);

        const writeFile = if (comptime builtin.zig_version.order(std.SemanticVersion.parse("0.13.0-dev.68+b86c4bde6") catch unreachable) == .lt)
            std.fs.Dir.writeFile2
        else
            std.fs.Dir.writeFile;

        writeFile(tmp_dir.dir, .{
            .sub_path = prefix,
            .data = data,
        }) catch |err| {
            tmp_dir.cleanup();
            std.debug.panic("failed to create file './{s}/{s}' which represents '{s}': {}", .{ &tmp_dir.sub_path, prefix, kv.path, err });
        };

        return try tmp_dir.dir.openFile(prefix, .{});
    }
};

const UserDirLookupError =
    std.mem.Allocator.Error ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError;

const xdg_user_dir_lookup_line_buffer_size: usize = 511;

/// Looks up a XDG user directory of the specified type.
///
/// Caller owns the returned memory.
//
/// Ported of xdg-user-dir-lookup.c from xdg-user-dirs, which is licensed under the MIT license:
/// https://cgit.freedesktop.org/xdg/xdg-user-dirs/tree/xdg-user-dir-lookup.c
fn xdgUserDirLookup(
    /// `DefaultDefaultSystem` or `TestingDefaultSystem`
    comptime System: type,
    system: *System,
    allocator: std.mem.Allocator,
    /// A string that specifies the type of directory.
    ///
    /// Asserts that the folder type is should be one of the following:
    /// - `XDG_DESKTOP_DIR`
    /// - `XDG_DOWNLOAD_DIR`
    /// - `XDG_TEMPLATES_DIR`
    /// - `XDG_PUBLICSHARE_DIR`
    /// - `XDG_DOCUMENTS_DIR`
    /// - `XDG_MUSIC_DIR`
    /// - `XDG_PICTURES_DIR`
    /// - `XDG_VIDEOS_DIR`
    folder_type: []const u8,
) UserDirLookupError!?[]u8 {
    if (builtin.mode == .Debug) {
        std.debug.assert(std.mem.startsWith(u8, folder_type, "XDG_"));
        std.debug.assert(std.mem.endsWith(u8, folder_type, "_DIR"));

        const folder_name = folder_type["XDG_".len .. folder_type.len - "_DIR".len];
        std.debug.assert( //
            std.mem.eql(u8, folder_name, "DESKTOP") or
            std.mem.eql(u8, folder_name, "DOWNLOAD") or
            std.mem.eql(u8, folder_name, "TEMPLATES") or
            std.mem.eql(u8, folder_name, "PUBLICSHARE") or
            std.mem.eql(u8, folder_name, "DOCUMENTS") or
            std.mem.eql(u8, folder_name, "MUSIC") or
            std.mem.eql(u8, folder_name, "PICTURES") or
            std.mem.eql(u8, folder_name, "VIDEOS"));
    }

    const home_dir: []const u8 = try system.getenv(allocator, "HOME") orelse return null;
    const maybe_config_home: ?[]const u8 = if (try system.getenv(allocator, "XDG_CONFIG_HOME")) |value|
        if (value.len != 0) value else null
    else
        null;

    const file: std.fs.File = if (maybe_config_home) |config_home|
        try system.openFile(config_home, "user-dirs.dirs")
    else
        try system.openFile(home_dir, ".config/user-dirs.dirs");
    defer file.close();

    var fbr = std.io.bufferedReaderSize(512, file.reader());
    const reader = fbr.reader();

    var user_dir: ?[]u8 = null;
    outer: while (true) {
        var buffer: [xdg_user_dir_lookup_line_buffer_size + 1]u8 = undefined;

        // Similar to `readUntilDelimiterOrEof` but also writes a null-terminator
        var line: [:0]u8 = for (&buffer, 0..) |*out, index| {
            const byte = reader.readByte() catch |err| switch (err) {
                error.EndOfStream => if (index == 0) break :outer else '\n',
                else => |e| return e,
            };
            if (byte == '\n') {
                out.* = 0;
                break buffer[0..index :0];
            }
            out.* = byte;
        } else blk: {
            // This happens when the line is longer than 511 characters
            // There are four possible ways to handle this:
            //  - use dynamic allocation to acquire enough storage
            //  - return an error
            //  - skip the line
            //  - truncate the line
            //
            // The xdg-user-dir implementation chooses to trunacte the line.
            // See "getPath - user-dirs.dirs - very long line" test

            try reader.skipUntilDelimiterOrEof('\n');

            buffer[buffer.len - 1] = 0;
            break :blk buffer[0 .. buffer.len - 1 :0];
        };

        while (line[0] == ' ' or line[0] == '\t')
            line = line[1..];

        if (!std.mem.startsWith(u8, line, folder_type))
            continue;
        line = line[folder_type.len..];

        while (line[0] == ' ' or line[0] == '\t') line = line[1..];

        if (line[0] != '=')
            continue;
        line = line["=".len..];

        while (line[0] == ' ' or line[0] == '\t') line = line[1..];

        if (line[0] != '\"')
            continue;
        line = line["\"".len..];

        if (user_dir) |path| {
            allocator.free(path);
            user_dir = null;
        }

        var is_relative = false;
        if (std.mem.startsWith(u8, line, "$HOME/")) {
            line = line["$HOME/".len..];
            is_relative = true;
        } else if (line[0] != '/') {
            continue;
        }

        var escaped_character_count: usize = 0;

        var index: usize = 0;
        const end_index: usize = while (index < line.len) : (index += 1) {
            if (line[index] == '\"')
                break index;
            if (line[index] == '\\' and line[index + 1] != 0) {
                // escaped character
                escaped_character_count += 1;
                index += 1;
            }
        } else line.len;

        const new_user_dir_len = (if (is_relative) home_dir.len + "/".len else 0) + end_index - escaped_character_count;
        const new_user_dir = try allocator.alloc(u8, new_user_dir_len);
        errdefer @compileError("");

        var out_index: usize = 0;
        if (is_relative) {
            @memcpy(new_user_dir[0..home_dir.len], home_dir);
            new_user_dir[home_dir.len] = '/';
            out_index = home_dir.len + 1;
        }

        index = 0;
        while (index < end_index) : (index += 1) {
            const ch1 = line[index];
            const ch2 = line[index + 1];
            if (ch1 == '\\' and ch2 != 0) {
                // escaped character
                new_user_dir[out_index] = ch2;
                out_index += 1;
                index += 1;
            } else {
                new_user_dir[out_index] = ch1;
                out_index += 1;
            }
        }

        std.debug.assert(out_index == new_user_dir.len);
        std.debug.assert(user_dir == null);
        user_dir = new_user_dir;
    }

    return user_dir;
}

/// Contains the GUIDs for each available known-folder on windows
const WindowsFolderSpec = union(enum) {
    by_guid: std.os.windows.GUID,
    by_env: struct {
        env_var: []const u8,
        subdir: ?[]const u8,
    },
};

fn getWindowsFolderSpec(folder: KnownFolder) WindowsFolderSpec {
    return switch (folder) {
        .executable_dir => unreachable,
        .home => .{ .by_guid = comptime std.os.windows.GUID.parse("{5E6C858F-0E22-4760-9AFE-EA3317B67173}") }, // FOLDERID_Profile
        .documents => .{ .by_guid = comptime std.os.windows.GUID.parse("{FDD39AD0-238F-46AF-ADB4-6C85480369C7}") }, // FOLDERID_Documents
        .pictures => .{ .by_guid = comptime std.os.windows.GUID.parse("{33E28130-4E1E-4676-835A-98395C3BC3BB}") }, // FOLDERID_Pictures
        .music => .{ .by_guid = comptime std.os.windows.GUID.parse("{4BD8D571-6D19-48D3-BE97-422220080E43}") }, // FOLDERID_Music
        .videos => .{ .by_guid = comptime std.os.windows.GUID.parse("{18989B1D-99B5-455B-841C-AB7C74E4DDFC}") }, // FOLDERID_Videos
        .desktop => .{ .by_guid = comptime std.os.windows.GUID.parse("{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}") }, // FOLDERID_Desktop
        .downloads => .{ .by_guid = comptime std.os.windows.GUID.parse("{374DE290-123F-4565-9164-39C4925E467B}") }, // FOLDERID_Downloads
        .public => .{ .by_guid = comptime std.os.windows.GUID.parse("{DFDF76A2-C82A-4D63-906A-5644AC457385}") }, // FOLDERID_Public
        .fonts => .{ .by_guid = comptime std.os.windows.GUID.parse("{FD228CB7-AE11-4AE3-864C-16F3910AB8FE}") }, // FOLDERID_Fonts
        .app_menu => .{ .by_guid = comptime std.os.windows.GUID.parse("{625B53C3-AB48-4EC1-BA1F-A1EF4146FC19}") }, // FOLDERID_StartMenu
        .cache => .{ .by_env = .{ .env_var = "LOCALAPPDATA", .subdir = "Temp" } }, // %LOCALAPPDATA%\Temp
        .roaming_configuration => .{ .by_guid = comptime std.os.windows.GUID.parse("{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}") }, // FOLDERID_RoamingAppData
        .local_configuration => .{ .by_guid = comptime std.os.windows.GUID.parse("{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}") }, // FOLDERID_LocalAppData
        .global_configuration => .{ .by_guid = comptime std.os.windows.GUID.parse("{62AB5D82-FDC1-4DC3-A9DD-070D1D495D97}") }, // FOLDERID_ProgramData
        .data => .{ .by_env = .{ .env_var = "APPDATA", .subdir = null } }, // %LOCALAPPDATA%\Temp
        .runtime => .{ .by_env = .{ .env_var = "LOCALAPPDATA", .subdir = "Temp" } },
    };
}

/// The default value for `KnownFolder.global_configuration` is the only absolute path. All others default values are relative to the home directory.
fn getMacFolderSpec(folder: KnownFolder) []const u8 {
    return switch (folder) {
        .executable_dir => unreachable,
        .home => unreachable,
        .documents => "Documents",
        .pictures => "Pictures",
        .music => "Music",
        .videos => "Movies",
        .desktop => "Desktop",
        .downloads => "Downloads",
        .public => "Public",
        .fonts => "Library/Fonts",
        .app_menu => "Applications",
        .cache => "Library/Caches",
        .roaming_configuration => "Library/Preferences",
        .local_configuration => "Library/Application Support",
        .global_configuration => "/Library/Preferences", // absolute path
        .data => "Library/Application Support",
        .runtime => "Library/Application Support",
    };
}

/// Contains the xdg environment variable and the default value for each available known-folder
const XdgFolderSpec = struct {
    env: struct {
        /// Name of the environment variable.
        name: []const u8,
        /// `true` means that the folder is a user directory that can be overriden in the `user-dirs.dirs`. See `xdgUserDirLookup`.
        /// `false` means that the folder is system directory.
        user_dir: bool,
        suffix: ?[]const u8,
    },
    default: ?[]const u8,
};

/// The default value for `KnownFolder.global_configuration` is the only absolute path. All others default values are relative to the home directory.
fn getXdgFolderSpec(folder: KnownFolder) XdgFolderSpec {
    return switch (folder) {
        .executable_dir => unreachable,
        .home => .{ .env = .{ .name = "HOME", .user_dir = false, .suffix = null }, .default = null },
        .documents => .{ .env = .{ .name = "XDG_DOCUMENTS_DIR", .user_dir = true, .suffix = null }, .default = "~/Documents" },
        .pictures => .{ .env = .{ .name = "XDG_PICTURES_DIR", .user_dir = true, .suffix = null }, .default = "~/Pictures" },
        .music => .{ .env = .{ .name = "XDG_MUSIC_DIR", .user_dir = true, .suffix = null }, .default = "~/Music" },
        .videos => .{ .env = .{ .name = "XDG_VIDEOS_DIR", .user_dir = true, .suffix = null }, .default = "~/Videos" },
        .desktop => .{ .env = .{ .name = "XDG_DESKTOP_DIR", .user_dir = true, .suffix = null }, .default = "~/Desktop" },
        .downloads => .{ .env = .{ .name = "XDG_DOWNLOAD_DIR", .user_dir = true, .suffix = null }, .default = "~/Downloads" },
        .public => .{ .env = .{ .name = "XDG_PUBLICSHARE_DIR", .user_dir = true, .suffix = null }, .default = "~/Public" },
        .fonts => .{ .env = .{ .name = "XDG_DATA_HOME", .user_dir = false, .suffix = "/fonts" }, .default = "~/.local/share/fonts" },
        .app_menu => .{ .env = .{ .name = "XDG_DATA_HOME", .user_dir = false, .suffix = "/applications" }, .default = "~/.local/share/applications" },
        .cache => .{ .env = .{ .name = "XDG_CACHE_HOME", .user_dir = false, .suffix = null }, .default = "~/.cache" },
        .roaming_configuration => .{ .env = .{ .name = "XDG_CONFIG_HOME", .user_dir = false, .suffix = null }, .default = "~/.config" },
        .local_configuration => .{ .env = .{ .name = "XDG_CONFIG_HOME", .user_dir = false, .suffix = null }, .default = "~/.config" },
        .global_configuration => .{ .env = .{ .name = "XDG_CONFIG_DIRS", .user_dir = false, .suffix = null }, .default = "/etc" }, // absolute path
        .data => .{ .env = .{ .name = "XDG_DATA_HOME", .user_dir = false, .suffix = null }, .default = "~/.local/share" },
        .runtime => .{ .env = .{ .name = "XDG_RUNTIME_DIR", .user_dir = false, .suffix = null }, .default = null },
    };
}

const GetPathTestParams = struct {
    system: TestingSystem,
    folder: KnownFolder,
    expected: ?[]const u8,
};
