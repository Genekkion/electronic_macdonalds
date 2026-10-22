const std = @import("std");

const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
    @cInclude("macos_window.h");
});

fn luaDoString(L: ?*c.lua_State, code: [:0]const u8) c_int {
    if (c.luaL_loadstring(L, code) != 0) return 1;
    return c.lua_pcallk(L, 0, c.LUA_MULTRET, 0, 0, null);
}

fn luaToString(L: ?*c.lua_State, idx: c_int) ?[*:0]const u8 {
    return c.lua_tolstring(L, idx, null);
}

pub fn main() !void {
    std.debug.print("Initializing Electronic Macdonalds...\n", .{});

    // 1. Initialize Lua VM
    const L = c.luaL_newstate();
    if (L == null) {
        std.debug.print("Failed to initialize Lua state\n", .{});
        return error.LuaInitFailed;
    }
    defer c.lua_close(L);
    c.luaL_openlibs(L);

    // Test Lua execution
    const test_script = "print(\"Hello from embedded Lua! Version: \" .. _VERSION)";
    if (luaDoString(L, test_script) != c.LUA_OK) {
        if (luaToString(L, -1)) |err_msg| {
            std.debug.print("Lua Error: {s}\n", .{err_msg});
        }
    }

    // 2. Initialize macOS AppKit GUI
    if (!c.macos_app_init()) {
        std.debug.print("Failed to initialize macOS application\n", .{});
        return error.AppInitFailed;
    }

    const window = c.macos_window_create("Electronic Macdonalds", 1024, 768);
    if (window == null) {
        std.debug.print("Failed to create window\n", .{});
        return error.WindowCreateFailed;
    }

    std.debug.print("Window created successfully (1024x768). Running event loop...\n", .{});
    c.macos_app_run();
}
