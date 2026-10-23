const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn default_io() Io {
    return Io.Threaded.global_single_threaded.io();
}

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
        const io = default_io();
        if (Io.Dir.cwd().openDir(io, pdir, .{ .iterate = true })) |dir_val| {
            var dir = dir_val;
            defer dir.close(io);
            var iter = dir.iterate();
            while (iter.next(io) catch null) |entry| {
                const plug_p1 = try std.fmt.allocPrint(allocator, "{s}/{s}/lua/?.lua", .{ pdir, entry.name });
                const plug_p2 = try std.fmt.allocPrint(allocator, "{s}/{s}/lua/?/init.lua", .{ pdir, entry.name });
                try extra_paths.append(allocator, plug_p1);
                try extra_paths.append(allocator, plug_p2);
            }
        } else |_| {}
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
    const io = default_io();
    const buf = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch return null;
    defer allocator.free(buf);
    if (buf.len == 0) return null;

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

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
    const io = default_io();

    var dir = Io.Dir.cwd().openDir(io, pdir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const plugin_dir = std.fmt.allocPrint(allocator, "{s}/{s}/plugin", .{ pdir, entry.name }) catch continue;
        defer allocator.free(plugin_dir);

        var psub = Io.Dir.cwd().openDir(io, plugin_dir, .{ .iterate = true }) catch continue;
        defer psub.close(io);

        var sub_iter = psub.iterate();
        while (sub_iter.next(io) catch null) |script_entry| {
            if (std.mem.endsWith(u8, script_entry.name, ".lua")) {
                const full_script_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugin_dir, script_entry.name }) catch continue;
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

    const io = testing.io;
    const tmp_path = "tmp_bad_syntax_init.lua";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = "this is not valid lua code !@#$" });
    defer Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

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

    const io = testing.io;
    const tmp_path = "tmp_good_init.lua";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = "_G.__test_cfg_var = 12345\n" });
    defer Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    const err_opt = try load_user_config(L, testing.allocator, tmp_path);
    try testing.expect(err_opt == null);

    _ = c.lua_getglobal(L, "__test_cfg_var");
    const val = c.lua_tointegerx(L, -1, null);
    c.lua_pop(L, 1);
    try testing.expectEqual(@as(c_longlong, 12345), val);
}
