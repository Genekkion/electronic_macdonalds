const std = @import("std");
const c = @import("c.zig").c;

pub const EventType = enum {
    buf_new,
    buf_enter,
    buf_leave,
    buf_delete,
    buf_write_pre,
    buf_write_post,
    mode_changed,
    cursor_moved,

    pub fn to_str(self: EventType) []const u8 {
        return switch (self) {
            .buf_new => "BufNew",
            .buf_enter => "BufEnter",
            .buf_leave => "BufLeave",
            .buf_delete => "BufDelete",
            .buf_write_pre => "BufWritePre",
            .buf_write_post => "BufWritePost",
            .mode_changed => "ModeChanged",
            .cursor_moved => "CursorMoved",
        };
    }
};

pub const EventData = struct {
    buf_id: ?usize = null,
    buf_path: ?[]const u8 = null,
    from_mode: ?[]const u8 = null,
    to_mode: ?[]const u8 = null,
    line: ?usize = null,
    col: ?usize = null,
};

pub fn emit_event(L: ?*c.lua_State, event: EventType, data: EventData) void {
    const state = L orelse return;

    _ = c.lua_getglobal(state, "editor");
    if (!c.lua_istable(state, -1)) {
        c.lua_pop(state, 1);
        return;
    }

    _ = c.lua_getfield(state, -1, "emit");
    if (!c.lua_isfunction(state, -1)) {
        c.lua_pop(state, 2);
        return;
    }

    const event_name = event.to_str();
    _ = c.lua_pushlstring(state, event_name.ptr, event_name.len);

    c.lua_newtable(state);
    if (data.buf_id) |id| {
        c.lua_pushinteger(state, @intCast(id));
        c.lua_setfield(state, -2, "buf_id");
    }
    if (data.buf_path) |p| {
        _ = c.lua_pushlstring(state, p.ptr, p.len);
        c.lua_setfield(state, -2, "buf_path");
    }
    if (data.from_mode) |fm| {
        _ = c.lua_pushlstring(state, fm.ptr, fm.len);
        c.lua_setfield(state, -2, "from");
    }
    if (data.to_mode) |tm| {
        _ = c.lua_pushlstring(state, tm.ptr, tm.len);
        c.lua_setfield(state, -2, "to");
    }
    if (data.line) |l| {
        c.lua_pushinteger(state, @intCast(l));
        c.lua_setfield(state, -2, "line");
    }
    if (data.col) |col| {
        c.lua_pushinteger(state, @intCast(col));
        c.lua_setfield(state, -2, "col");
    }

    if (c.lua_pcallk(state, 2, 0, 0, 0, null) != 0) {
        c.lua_pop(state, 1); // pop error safely
    }
    c.lua_pop(state, 1); // pop editor table
}

const testing = std.testing;
const BufferRegistry = @import("../buffer/registry.zig").BufferRegistry;
const buffer_binding = @import("buffer_binding.zig");

test "test_events_emit_and_listen" {
    const L = c.luaL_newstate().?;
    defer c.lua_close(L);
    c.luaL_openlibs(L);

    var registry = BufferRegistry.init(testing.allocator);
    defer registry.deinit();
    buffer_binding.init_binding(L, &registry);

    _ = c.luaL_loadstring(L,
        \\_G.received_mode = {}
        \\editor.on("ModeChanged", function(ev)
        \\    _G.received_mode.from = ev.from
        \\    _G.received_mode.to = ev.to
        \\end)
    );
    _ = c.lua_pcallk(L, 0, 0, 0, 0, null);

    emit_event(L, .mode_changed, .{ .from_mode = "normal", .to_mode = "insert" });

    _ = c.lua_getglobal(L, "received_mode");
    _ = c.lua_getfield(L, -1, "from");
    const from_str = std.mem.span(c.lua_tolstring(L, -1, null).?);
    c.lua_pop(L, 1);
    _ = c.lua_getfield(L, -1, "to");
    const to_str = std.mem.span(c.lua_tolstring(L, -1, null).?);
    c.lua_pop(L, 2);

    try testing.expectEqualStrings("normal", from_str);
    try testing.expectEqualStrings("insert", to_str);
}
