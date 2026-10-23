const c = @import("c.zig").c;

pub fn push_success_nil(L: ?*c.lua_State) c_int {
    c.lua_pushnil(L);
    c.lua_pushnil(L);
    c.lua_pushnil(L);
    return 3;
}

pub fn push_success_bool(L: ?*c.lua_State, val: bool) c_int {
    c.lua_pushboolean(L, if (val) 1 else 0);
    c.lua_pushnil(L);
    c.lua_pushnil(L);
    return 3;
}

pub fn push_success_int(L: ?*c.lua_State, val: isize) c_int {
    c.lua_pushinteger(L, @intCast(val));
    c.lua_pushnil(L);
    c.lua_pushnil(L);
    return 3;
}

pub fn push_success_str(L: ?*c.lua_State, bytes: []const u8) c_int {
    _ = c.lua_pushlstring(L, bytes.ptr, bytes.len);
    c.lua_pushnil(L);
    c.lua_pushnil(L);
    return 3;
}

pub fn push_error(L: ?*c.lua_State, code: [:0]const u8, msg: [:0]const u8) c_int {
    c.lua_pushnil(L);
    _ = c.lua_pushstring(L, code.ptr);
    _ = c.lua_pushstring(L, msg.ptr);
    return 3;
}
