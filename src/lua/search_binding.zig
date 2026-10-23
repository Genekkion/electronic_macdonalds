const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const c = @import("c.zig").c;
const search_engine = @import("../search/engine.zig");

pub fn lua_find_files(L: ?*c.lua_State) callconv(.c) c_int {
    const allocator = std.heap.c_allocator;
    var opts = search_engine.FindOptions{};

    if (c.lua_gettop(L) >= 1 and c.lua_istable(L, 1)) {
        opts.root_path = get_table_string(L, 1, "cwd") orelse ".";
        opts.query = get_table_string(L, 1, "query") orelse "";
        if (get_table_bool(L, 1, "hidden")) |h| opts.hidden = h;
        if (get_table_bool(L, 1, "ignored")) |ig| opts.ignored = ig;
        if (get_table_usize(L, 1, "max_results")) |mr| opts.max_results = mr;
    }

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = if (builtin.is_test) std.testing.io else threaded.io();

    const files = search_engine.find_files(io, allocator, opts) catch {
        c.lua_newtable(L);
        return 1;
    };
    defer search_engine.free_file_list(allocator, files);

    c.lua_newtable(L);
    for (files, 0..) |file_path, i| {
        _ = c.lua_pushlstring(L, file_path.ptr, file_path.len);
        c.lua_rawseti(L, -2, @intCast(i + 1));
    }
    return 1;
}

pub fn lua_live_grep(L: ?*c.lua_State) callconv(.c) c_int {
    const allocator = std.heap.c_allocator;
    var opts = search_engine.GrepOptions{};

    if (c.lua_gettop(L) >= 1 and c.lua_istable(L, 1)) {
        opts.root_path = get_table_string(L, 1, "cwd") orelse ".";
        opts.pattern = get_table_string(L, 1, "pattern") orelse (get_table_string(L, 1, "query") orelse "");
        if (get_table_bool(L, 1, "hidden")) |h| opts.hidden = h;
        if (get_table_bool(L, 1, "ignored")) |ig| opts.ignored = ig;
        if (get_table_usize(L, 1, "max_results")) |mr| opts.max_results = mr;
    }

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = if (builtin.is_test) std.testing.io else threaded.io();

    const matches = search_engine.live_grep(io, allocator, opts) catch {
        c.lua_newtable(L);
        return 1;
    };
    defer search_engine.free_grep_matches(allocator, matches);

    c.lua_newtable(L);
    for (matches, 0..) |m, i| {
        c.lua_newtable(L);

        _ = c.lua_pushlstring(L, m.path.ptr, m.path.len);
        c.lua_setfield(L, -2, "path");

        c.lua_pushinteger(L, @intCast(m.line));
        c.lua_setfield(L, -2, "line");

        c.lua_pushinteger(L, @intCast(m.col));
        c.lua_setfield(L, -2, "col");

        _ = c.lua_pushlstring(L, m.text.ptr, m.text.len);
        c.lua_setfield(L, -2, "text");

        c.lua_rawseti(L, -2, @intCast(i + 1));
    }
    return 1;
}

fn get_table_string(L: ?*c.lua_State, idx: c_int, key: [:0]const u8) ?[]const u8 {
    _ = c.lua_getfield(L, idx, key.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return null;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len);
    if (ptr == null) return null;
    return ptr[0..len];
}

fn get_table_bool(L: ?*c.lua_State, idx: c_int, key: [:0]const u8) ?bool {
    _ = c.lua_getfield(L, idx, key.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TBOOLEAN) return null;
    return c.lua_toboolean(L, -1) != 0;
}

fn get_table_usize(L: ?*c.lua_State, idx: c_int, key: [:0]const u8) ?usize {
    _ = c.lua_getfield(L, idx, key.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TNUMBER) return null;
    const val = c.lua_tointegerx(L, -1, null);
    if (val < 0) return null;
    return @intCast(val);
}
