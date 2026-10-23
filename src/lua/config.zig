const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;

const posix_c = @cImport({
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn unlink(path: [*c]const u8) c_int;
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;

pub fn get_config_dir(allocator: Allocator) ![:0]u8 {
    if (getenv("XDG_CONFIG_HOME")) |cfg_home| {
        return try std.fs.path.joinZ(allocator, &[_][]const u8{ std.mem.span(cfg_home), "electronic_macdonalds" });
    }
    if (getenv("HOME")) |home| {
        return try std.fs.path.joinZ(allocator, &[_][]const u8{ std.mem.span(home), ".config", "electronic_macdonalds" });
    }
    return try allocator.dupeZ(u8, ".");
}

pub fn get_config_path(allocator: Allocator) ![:0]u8 {
    const dir = try get_config_dir(allocator);
    defer allocator.free(dir);
    return try std.fs.path.joinZ(allocator, &[_][]const u8{ dir, "init.lua" });
}

pub fn get_plugins_dir(allocator: Allocator) ![:0]u8 {
    if (getenv("XDG_DATA_HOME")) |data_home| {
        return try std.fs.path.joinZ(allocator, &[_][]const u8{ std.mem.span(data_home), "electronic_macdonalds", "plugins" });
    }
    if (getenv("HOME")) |home| {
        return try std.fs.path.joinZ(allocator, &[_][]const u8{ std.mem.span(home), ".local", "share", "electronic_macdonalds", "plugins" });
    }
    return try allocator.dupeZ(u8, "plugins");
}

pub fn setup_package_path(L: *c.lua_State, allocator: Allocator, config_dir: []const u8, plugins_dir: ?[]const u8) !void {
    _ = c.lua_getglobal(L, "package");
    if (!c.lua_istable(L, -1)) {
        c.lua_pop(L, 1);
        return;
    }

    _ = c.lua_getfield(L, -1, "path");
    const cur_path = if (c.lua_tolstring(L, -1, null)) |ptr| std.mem.span(ptr) else "";
    c.lua_pop(L, 1);

    var extra_paths = std.ArrayList([]const u8).empty;
    defer {
        for (extra_paths.items) |item| {
            allocator.free(item);
        }
        extra_paths.deinit(allocator);
    }

    // 1. Add <config_dir>/lua/?.lua and <config_dir>/lua/?/init.lua
    const p1 = try std.fmt.allocPrint(allocator, "{s}/lua/?.lua", .{config_dir});
    const p2 = try std.fmt.allocPrint(allocator, "{s}/lua/?/init.lua", .{config_dir});
    try extra_paths.append(allocator, p1);
    try extra_paths.append(allocator, p2);

    // 2. Add plugin directories if present
    if (plugins_dir) |pdir| {
        const pdir_z = try allocator.dupeZ(u8, pdir);
        defer allocator.free(pdir_z);

        const dir_handle = posix_c.opendir(pdir_z.ptr);
        if (dir_handle != null) {
            defer _ = posix_c.closedir(dir_handle);
            while (posix_c.readdir(dir_handle)) |entry| {
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

                const plug_p1 = try std.fmt.allocPrint(allocator, "{s}/{s}/lua/?.lua", .{ pdir, name });
                const plug_p2 = try std.fmt.allocPrint(allocator, "{s}/{s}/lua/?/init.lua", .{ pdir, name });
                try extra_paths.append(allocator, plug_p1);
                try extra_paths.append(allocator, plug_p2);
            }
        }
    }

    // Join extra paths with semicolon
    var combined = std.ArrayList(u8).empty;
    defer combined.deinit(allocator);

    for (extra_paths.items) |p| {
        try combined.appendSlice(allocator, p);
        try combined.append(allocator, ';');
    }
    try combined.appendSlice(allocator, cur_path);

    _ = c.lua_pushlstring(L, combined.items.ptr, combined.items.len);
    _ = c.lua_setfield(L, -2, "path");
    c.lua_pop(L, 1); // pop package table
}

pub fn load_user_config(L: *c.lua_State, allocator: Allocator, path: []const u8) !?[:0]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const f = std.c.fopen(path_z.ptr, "rb") orelse return null; // File does not exist, silent fallback
    defer _ = std.c.fclose(f);

    _ = fseek(f, 0, SEEK_END);
    const sz = ftell(f);
    if (sz <= 0) return null;
    _ = fseek(f, 0, SEEK_SET);

    const buf = try allocator.alloc(u8, @intCast(sz));
    defer allocator.free(buf);

    const read_bytes = std.c.fread(buf.ptr, 1, buf.len, f);
    if (read_bytes != buf.len) return null;

    if (c.luaL_loadbufferx(L, buf.ptr, buf.len, path_z.ptr, null) != 0) {
        const err_str = if (c.lua_tolstring(L, -1, null)) |ptr| std.mem.span(ptr) else "syntax error";
        const err_dupe = try allocator.dupeZ(u8, err_str);
        c.lua_pop(L, 1);
        return err_dupe;
    }

    if (c.lua_pcallk(L, 0, 0, 0, 0, null) != 0) {
        const err_str = if (c.lua_tolstring(L, -1, null)) |ptr| std.mem.span(ptr) else "runtime error";
        const err_dupe = try allocator.dupeZ(u8, err_str);
        c.lua_pop(L, 1);
        return err_dupe;
    }

    return null;
}

pub fn load_plugin_scripts(L: *c.lua_State, allocator: Allocator, plugins_dir: ?[]const u8) void {
    const pdir = plugins_dir orelse return;
    const pdir_z = allocator.dupeZ(u8, pdir) catch return;
    defer allocator.free(pdir_z);

    const dir_handle = posix_c.opendir(pdir_z.ptr);
    if (dir_handle == null) return;
    defer _ = posix_c.closedir(dir_handle);

    while (posix_c.readdir(dir_handle)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const plugin_dir = std.fmt.allocPrint(allocator, "{s}/{s}/plugin", .{ pdir, name }) catch continue;
        defer allocator.free(plugin_dir);

        const plugin_dir_z = allocator.dupeZ(u8, plugin_dir) catch continue;
        defer allocator.free(plugin_dir_z);

        const psub_handle = posix_c.opendir(plugin_dir_z.ptr);
        if (psub_handle == null) continue;
        defer _ = posix_c.closedir(psub_handle);

        while (posix_c.readdir(psub_handle)) |script_entry| {
            const script_name = std.mem.span(@as([*:0]const u8, @ptrCast(&script_entry.*.d_name)));
            if (std.mem.endsWith(u8, script_name, ".lua")) {
                const full_script_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugin_dir, script_name }) catch continue;
                defer allocator.free(full_script_path);

                _ = load_user_config(L, allocator, full_script_path) catch null;
            }
        }
    }
}

const testing = std.testing;

test "test_config_path_resolution" {
    const cfg_path = try get_config_path(testing.allocator);
    defer testing.allocator.free(cfg_path);
    try testing.expect(std.mem.endsWith(u8, cfg_path, "electronic_macdonalds/init.lua"));

    const plug_dir = try get_plugins_dir(testing.allocator);
    defer testing.allocator.free(plug_dir);
    try testing.expect(std.mem.endsWith(u8, plug_dir, "electronic_macdonalds/plugins"));
}

test "test_config_package_path_setup" {
    const L = c.luaL_newstate().?;
    defer c.lua_close(L);
    c.luaL_openlibs(L);

    try setup_package_path(L, testing.allocator, "/dummy/config", null);

    _ = c.lua_getglobal(L, "package");
    _ = c.lua_getfield(L, -1, "path");
    const path_str = std.mem.span(c.lua_tolstring(L, -1, null).?);
    c.lua_pop(L, 2);

    try testing.expect(std.mem.indexOf(u8, path_str, "/dummy/config/lua/?.lua") != null);
    try testing.expect(std.mem.indexOf(u8, path_str, "/dummy/config/lua/?/init.lua") != null);
}

test "test_config_protected_load_syntax_error" {
    const L = c.luaL_newstate().?;
    defer c.lua_close(L);
    c.luaL_openlibs(L);

    const tmp_path = "tmp_bad_syntax_init.lua";
    {
        const f = std.c.fopen(tmp_path, "wb").?;
        defer _ = std.c.fclose(f);
        const bad_code = "this is not valid lua code !@#$";
        _ = std.c.fwrite(bad_code.ptr, 1, bad_code.len, f);
    }
    defer _ = unlink(tmp_path);

    const err_opt = try load_user_config(L, testing.allocator, tmp_path);
    try testing.expect(err_opt != null);
    if (err_opt) |err_msg| {
        defer testing.allocator.free(err_msg);
        try testing.expect(err_msg.len > 0);
    }
}

test "test_config_protected_load_success" {
    const L = c.luaL_newstate().?;
    defer c.lua_close(L);
    c.luaL_openlibs(L);

    const tmp_path = "tmp_good_init.lua";
    {
        const f = std.c.fopen(tmp_path, "wb").?;
        defer _ = std.c.fclose(f);
        const good_code = "_G.__test_cfg_var = 12345\n";
        _ = std.c.fwrite(good_code.ptr, 1, good_code.len, f);
    }
    defer _ = unlink(tmp_path);

    const err_opt = try load_user_config(L, testing.allocator, tmp_path);
    try testing.expect(err_opt == null);

    _ = c.lua_getglobal(L, "__test_cfg_var");
    const val = c.lua_tointegerx(L, -1, null);
    c.lua_pop(L, 1);
    try testing.expectEqual(@as(c_longlong, 12345), val);
}
