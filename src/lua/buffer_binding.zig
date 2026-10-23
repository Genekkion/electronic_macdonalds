const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const result = @import("result.zig");
const Buffer = @import("../buffer/buffer.zig").Buffer;
const BufferRegistry = @import("../buffer/registry.zig").BufferRegistry;
const clipboard = @import("../platform/clipboard.zig");
const undo_mod = @import("../buffer/undo.zig");

pub const metatable_name = "ElectronicMacdonalds.BufferHandle";

pub const BufferHandle = struct {
    id: u64,
};

var global_registry: ?*BufferRegistry = null;

const lua_editor_init = @embedFile("../runtime/lua/editor/init.lua");
const lua_editor_commands = @embedFile("../runtime/lua/editor/commands.lua");
const lua_editor_keymap = @embedFile("../runtime/lua/editor/keymap.lua");
const lua_editor_buffers = @embedFile("../runtime/lua/editor/buffers.lua");
const lua_editor_events = @embedFile("../runtime/lua/editor/events.lua");
const lua_editor_oil = @embedFile("../runtime/lua/editor/oil.lua");
const events = @import("events.zig");
const fs = @import("fs.zig");

pub fn init_binding(L: ?*c.lua_State, registry: *BufferRegistry) void {
    global_registry = registry;

    // Create metatable for BufferHandle
    _ = c.luaL_newmetatable(L, metatable_name);
    c.lua_pushvalue(L, -1);
    c.lua_setfield(L, -2, "__index");

    const methods = [_]c.luaL_Reg{
        .{ .name = "len", .func = lua_len },
        .{ .name = "line_count", .func = lua_line_count },
        .{ .name = "insert", .func = lua_insert },
        .{ .name = "delete", .func = lua_delete },
        .{ .name = "get_slice", .func = lua_get_slice },
        .{ .name = "get_line", .func = lua_get_line },
        .{ .name = "is_dirty", .func = lua_is_dirty },
        .{ .name = "save", .func = lua_save },
        .{ .name = "get_id", .func = lua_get_id },
        .{ .name = "get_name", .func = lua_get_name },
        .{ .name = "get_path", .func = lua_get_path },
        .{ .name = "set_path", .func = lua_set_path },
        .{ .name = "replace", .func = lua_replace },
        .{ .name = "undo", .func = lua_buf_undo },
        .{ .name = "redo", .func = lua_buf_redo },
        .{ .name = null, .func = null },
    };
    c.luaL_setfuncs(L, &methods, 0);
    c.lua_pop(L, 1);

    // Register editor table
    c.lua_newtable(L);

    // Create internal keybindings table: editor._keybindings = {}
    c.lua_newtable(L);
    c.lua_setfield(L, -2, "_keybindings");

    // Create clipboard table: editor.clipboard = { get = ..., set = ... }
    c.lua_newtable(L);
    const clipboard_funcs = [_]c.luaL_Reg{
        .{ .name = "get", .func = lua_clipboard_get },
        .{ .name = "set", .func = lua_clipboard_set },
        .{ .name = null, .func = null },
    };
    c.luaL_setfuncs(L, &clipboard_funcs, 0);
    c.lua_setfield(L, -2, "clipboard");

    // Create undo table: editor.undo = { tree = ... }
    c.lua_newtable(L);
    const undo_funcs = [_]c.luaL_Reg{
        .{ .name = "tree", .func = lua_undo_tree },
        .{ .name = null, .func = null },
    };
    c.luaL_setfuncs(L, &undo_funcs, 0);
    c.lua_setfield(L, -2, "undo");

    const editor_funcs = [_]c.luaL_Reg{
        .{ .name = "create_buffer", .func = lua_create_buffer },
        .{ .name = "close_buffer", .func = lua_close_buffer },
        .{ .name = "read_file", .func = lua_read_file },
        .{ .name = "quit", .func = lua_quit },
        .{ .name = "is_quit_requested", .func = lua_is_quit_requested },
        .{ .name = "get_current_buffer", .func = lua_get_current_buffer },
        .{ .name = "set_current_buffer", .func = lua_set_current_buffer },
        .{ .name = "list_buffers", .func = lua_list_buffers },
        .{ .name = "get_buffer_by_id", .func = lua_get_buffer_by_id },
        .{ .name = "get_cursor", .func = lua_get_cursor },
        .{ .name = "set_cursor", .func = lua_set_cursor },
        .{ .name = "bind_key", .func = lua_bind_key },
        .{ .name = "dispatch_key_combo", .func = lua_dispatch_key_combo },
        .{ .name = "is_dir", .func = fs.lua_is_dir },
        .{ .name = "read_dir", .func = fs.lua_read_dir },
        .{ .name = "fs_rename", .func = fs.lua_fs_rename },
        .{ .name = "fs_delete", .func = fs.lua_fs_delete },
        .{ .name = "fs_mkdir", .func = fs.lua_fs_mkdir },
        .{ .name = "fs_touch", .func = fs.lua_fs_touch },
        .{ .name = null, .func = null },
    };
    c.luaL_setfuncs(L, &editor_funcs, 0);
    c.lua_setglobal(L, "editor");

    // Register embedded modules into package.preload so `require` finds them
    _ = c.lua_getglobal(L, "package");
    _ = c.lua_getfield(L, -1, "preload");

    _ = c.luaL_loadbufferx(L, lua_editor_commands.ptr, lua_editor_commands.len, "@editor.commands", null);
    c.lua_setfield(L, -2, "editor.commands");

    _ = c.luaL_loadbufferx(L, lua_editor_keymap.ptr, lua_editor_keymap.len, "@editor.keymap", null);
    c.lua_setfield(L, -2, "editor.keymap");

    _ = c.luaL_loadbufferx(L, lua_editor_buffers.ptr, lua_editor_buffers.len, "@editor.buffers", null);
    c.lua_setfield(L, -2, "editor.buffers");

    _ = c.luaL_loadbufferx(L, lua_editor_events.ptr, lua_editor_events.len, "@editor.events", null);
    c.lua_setfield(L, -2, "editor.events");

    _ = c.luaL_loadbufferx(L, lua_editor_oil.ptr, lua_editor_oil.len, "@editor.oil", null);
    c.lua_setfield(L, -2, "editor.oil");

    _ = c.luaL_loadbufferx(L, lua_editor_init.ptr, lua_editor_init.len, "@editor.init", null);
    c.lua_setfield(L, -2, "editor.init");

    c.lua_pop(L, 2); // pop preload, package

    // Bootstrap editor runtime via editor.init
    _ = c.luaL_loadbufferx(L, lua_editor_init.ptr, lua_editor_init.len, "@editor.init", null);
    if (c.lua_pcallk(L, 0, 0, 0, 0, null) != 0) {
        const err_msg = c.lua_tolstring(L, -1, null);
        std.debug.print("Failed to initialize Lua runtime: {s}\n", .{err_msg});
        c.lua_pop(L, 1);
    }
}

fn lua_bind_key(L: ?*c.lua_State) callconv(.c) c_int {
    if (c.lua_type(L, 1) != c.LUA_TSTRING or c.lua_type(L, 2) != c.LUA_TFUNCTION) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected (combo: string, callback: function)");
    }

    _ = c.lua_getglobal(L, "editor");
    _ = c.lua_getfield(L, -1, "_keybindings");

    // keybindings[combo] = func
    c.lua_pushvalue(L, 1);
    c.lua_pushvalue(L, 2);
    c.lua_settable(L, -3);

    c.lua_pop(L, 2); // pop _keybindings, editor
    return result.push_success_bool(L, true);
}

fn lua_dispatch_key_combo(L: ?*c.lua_State) callconv(.c) c_int {
    if (c.lua_type(L, 1) != c.LUA_TSTRING) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected (combo: string)");
    }

    _ = c.lua_getglobal(L, "editor");
    _ = c.lua_getfield(L, -1, "_keybindings");

    c.lua_pushvalue(L, 1);
    _ = c.lua_gettable(L, -2);

    if (c.lua_isfunction(L, -1)) {
        if (c.lua_pcallk(L, 0, 0, 0, 0, null) != 0) {
            c.lua_pop(L, 2); // pop error, editor
            return result.push_error(L, "LUA_ERROR", "error executing key handler");
        }
        c.lua_pop(L, 2); // pop _keybindings, editor
        return result.push_success_bool(L, true);
    }

    c.lua_pop(L, 3); // pop nil/value, _keybindings, editor
    return result.push_error(L, "UNBOUND_KEY", "no binding for key combo");
}

fn lua_clipboard_get(L: ?*c.lua_State) callconv(.c) c_int {
    if (clipboard.get()) |text| {
        _ = c.lua_pushlstring(L, text.ptr, text.len);
        return 1;
    }
    c.lua_pushnil(L);
    return 1;
}

fn lua_clipboard_set(L: ?*c.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const str = c.lua_tolstring(L, 1, &len);
    if (str != null) {
        clipboard.set(str[0..len]);
        return result.push_success_bool(L, true);
    }
    return result.push_error(L, "INVALID_ARGUMENT", "expected (text: string)");
}

fn lua_undo_tree(L: ?*c.lua_State) callconv(.c) c_int {
    const res = resolve_buffer(L, 1);
    const buf = switch (res) {
        .err_ret => |code| return code,
        .buf => |b| b,
    };

    c.lua_createtable(L, 0, 4);

    _ = c.lua_pushinteger(L, @intCast(buf.undo_tree.current.seq));
    c.lua_setfield(L, -2, "seq_cur");

    _ = c.lua_pushinteger(L, @intCast(if (buf.undo_tree.next_seq > 0) buf.undo_tree.next_seq - 1 else 0));
    c.lua_setfield(L, -2, "seq_last");

    if (buf.undo_tree.saved_seq) |s| {
        _ = c.lua_pushinteger(L, @intCast(s));
    } else {
        c.lua_pushnil(L);
    }
    c.lua_setfield(L, -2, "save_cur");

    const count = buf.undo_tree.all_nodes.count();
    const entries = std.heap.c_allocator.alloc(*undo_mod.UndoNode, count) catch return result.push_error(L, "OUT_OF_MEMORY", "failed to allocate entries");
    defer std.heap.c_allocator.free(entries);

    var it = buf.undo_tree.all_nodes.valueIterator();
    var i: usize = 0;
    while (it.next()) |node_ptr| {
        entries[i] = node_ptr.*;
        i += 1;
    }

    const sortFn = struct {
        fn lessThan(_: void, a: *undo_mod.UndoNode, b: *undo_mod.UndoNode) bool {
            return a.seq < b.seq;
        }
    }.lessThan;
    std.mem.sort(*undo_mod.UndoNode, entries, {}, sortFn);

    c.lua_createtable(L, @intCast(count), 0);
    var entry_idx: c_int = 1;
    for (entries) |node| {
        if (node.seq == 0) continue;

        c.lua_createtable(L, 0, 6);

        _ = c.lua_pushinteger(L, @intCast(node.seq));
        c.lua_setfield(L, -2, "seq");

        _ = c.lua_pushinteger(L, @intCast(node.timestamp));
        c.lua_setfield(L, -2, "time");

        if (node.parent) |p| {
            _ = c.lua_pushinteger(L, @intCast(p.seq));
        } else {
            _ = c.lua_pushinteger(L, 0);
        }
        c.lua_setfield(L, -2, "parent");

        _ = c.lua_pushinteger(L, @intCast(node.cursor_line));
        c.lua_setfield(L, -2, "cursor_line");

        _ = c.lua_pushinteger(L, @intCast(node.cursor_col));
        c.lua_setfield(L, -2, "cursor_col");

        c.lua_createtable(L, @intCast(node.children.items.len), 0);
        for (node.children.items, 0..) |child, c_idx| {
            _ = c.lua_pushinteger(L, @intCast(child.seq));
            c.lua_rawseti(L, -2, @intCast(c_idx + 1));
        }
        c.lua_setfield(L, -2, "children");

        c.lua_rawseti(L, -2, entry_idx);
        entry_idx += 1;
    }
    c.lua_setfield(L, -2, "entries");

    return 1;
}

fn get_handle_id(L: ?*c.lua_State, idx: c_int) ?u64 {
    const udata = c.luaL_testudata(L, idx, metatable_name);
    if (udata == null) return null;
    const handle: *const BufferHandle = @ptrCast(@alignCast(udata));
    return handle.id;
}

const GetBufResult = union(enum) {
    buf: *Buffer,
    err_ret: c_int,
};

fn resolve_buffer(L: ?*c.lua_State, idx: c_int) GetBufResult {
    const id = get_handle_id(L, idx) orelse {
        return .{ .err_ret = result.push_error(L, "INVALID_ARGUMENT", "expected BufferHandle") };
    };
    const registry = global_registry orelse {
        return .{ .err_ret = result.push_error(L, "INTERNAL_ERROR", "registry not initialized") };
    };
    const buf = registry.get(id) orelse {
        return .{ .err_ret = result.push_error(L, "INVALID_HANDLE", "buffer handle is invalid or closed") };
    };
    return .{ .buf = buf };
}

fn push_buffer_handle(L: ?*c.lua_State, id: u64) void {
    const ptr = c.lua_newuserdatauv(L, @sizeOf(BufferHandle), 0);
    const handle: *BufferHandle = @ptrCast(@alignCast(ptr));
    handle.* = .{ .id = id };
    _ = c.luaL_setmetatable(L, metatable_name);
}

fn lua_create_buffer(L: ?*c.lua_State) callconv(.c) c_int {
    const registry = global_registry orelse {
        return result.push_error(L, "INTERNAL_ERROR", "registry not initialized");
    };
    const id = registry.create_buffer() catch {
        return result.push_error(L, "OUT_OF_MEMORY", "failed to allocate buffer");
    };

    push_buffer_handle(L, id);
    c.lua_pushnil(L);
    c.lua_pushnil(L);
    return 3;
}

fn lua_read_file(L: ?*c.lua_State) callconv(.c) c_int {
    var str_len: usize = 0;
    const path_c = c.lua_tolstring(L, 1, &str_len);
    if (path_c == null) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected path string");
    }
    const path_slice = path_c[0..str_len];

    const registry = global_registry orelse {
        return result.push_error(L, "INTERNAL_ERROR", "registry not initialized");
    };

    const path_z = registry.allocator.dupeZ(u8, path_slice) catch {
        return result.push_error(L, "OUT_OF_MEMORY", "failed to allocate path");
    };
    defer registry.allocator.free(path_z);

    const id = registry.load_file(path_z) catch |err| switch (err) {
        error.FileNotFound => return result.push_error(L, "FILE_NOT_FOUND", "file does not exist"),
        error.FileOpenFailed => return result.push_error(L, "FILE_OPEN_FAILED", "could not open file"),
        error.ReadFailed => return result.push_error(L, "READ_FAILED", "failed to read file content"),
        error.WriteFailed => return result.push_error(L, "IO_ERROR", "io error"),
        error.OutOfMemory => return result.push_error(L, "OUT_OF_MEMORY", "out of memory loading file"),
        error.OutOfBounds => return result.push_error(L, "INTERNAL_ERROR", "buffer indexing error"),
    };

    push_buffer_handle(L, id);
    c.lua_pushnil(L);
    c.lua_pushnil(L);
    return 3;
}

var g_quit_requested: bool = false;

pub fn is_quit_requested() bool {
    return g_quit_requested;
}

fn lua_quit(L: ?*c.lua_State) callconv(.c) c_int {
    _ = L;
    g_quit_requested = true;
    return 0;
}

var current_buffer_id: ?u64 = null;

pub fn get_active_buffer_id() ?u64 {
    return current_buffer_id;
}

pub fn set_active_buffer_id(id: ?u64) void {
    current_buffer_id = id;
}

fn lua_get_current_buffer(L: ?*c.lua_State) callconv(.c) c_int {
    if (current_buffer_id) |id| {
        if (global_registry) |reg| {
            if (reg.get(id) != null) {
                push_buffer_handle(L, id);
                c.lua_pushnil(L);
                c.lua_pushnil(L);
                return 3;
            }
        }
    }
    c.lua_pushnil(L);
    c.lua_pushnil(L);
    c.lua_pushnil(L);
    return 3;
}

fn lua_set_current_buffer(L: ?*c.lua_State) callconv(.c) c_int {
    var id: u64 = 0;
    if (get_handle_id(L, 1)) |hid| {
        id = hid;
    } else if (c.lua_type(L, 1) == c.LUA_TNUMBER) {
        id = @intCast(c.lua_tointegerx(L, 1, null));
    } else {
        return result.push_error(L, "INVALID_ARGUMENT", "expected BufferHandle or buffer id number");
    }
    current_buffer_id = id;
    if (global_registry) |reg| {
        if (reg.get(id)) |buf| {
            events.emit_event(L, .buf_enter, .{ .buf_id = id, .buf_path = buf.file_path });
        }
    }
    return result.push_success_bool(L, true);
}

fn lua_is_quit_requested(L: ?*c.lua_State) callconv(.c) c_int {
    return result.push_success_bool(L, g_quit_requested);
}

var g_cursor_line: usize = 0;
var g_cursor_col: usize = 0;
var g_cursor_updated: bool = false;

pub fn set_internal_cursor(line: usize, col: usize) void {
    g_cursor_line = line;
    g_cursor_col = col;
    g_cursor_updated = false;
}

pub fn get_internal_cursor() struct { line: usize, col: usize, updated: bool } {
    return .{
        .line = g_cursor_line,
        .col = g_cursor_col,
        .updated = g_cursor_updated,
    };
}

fn lua_get_cursor(L: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushinteger(L, @intCast(g_cursor_line));
    c.lua_pushinteger(L, @intCast(g_cursor_col));
    return 2;
}

fn lua_set_cursor(L: ?*c.lua_State) callconv(.c) c_int {
    if (c.lua_type(L, 1) != c.LUA_TNUMBER or c.lua_type(L, 2) != c.LUA_TNUMBER) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected line and col numbers");
    }
    const line = c.lua_tointegerx(L, 1, null);
    const col = c.lua_tointegerx(L, 2, null);
    g_cursor_line = @intCast(@max(0, line));
    g_cursor_col = @intCast(@max(0, col));
    g_cursor_updated = true;
    return result.push_success_bool(L, true);
}

fn lua_close_buffer(L: ?*c.lua_State) callconv(.c) c_int {
    var id: u64 = 0;
    if (get_handle_id(L, 1)) |hid| {
        id = hid;
    } else if (c.lua_type(L, 1) == c.LUA_TNUMBER) {
        id = @intCast(c.lua_tointegerx(L, 1, null));
    } else {
        return result.push_error(L, "INVALID_ARGUMENT", "expected BufferHandle or buffer id number");
    }
    const registry = global_registry orelse {
        return result.push_error(L, "INTERNAL_ERROR", "registry not initialized");
    };
    if (registry.close_buffer(id)) {
        if (current_buffer_id == id) {
            current_buffer_id = null;
        }
        return result.push_success_bool(L, true);
    }
    return result.push_error(L, "INVALID_HANDLE", "buffer handle not found or already closed");
}

fn lua_get_id(L: ?*c.lua_State) callconv(.c) c_int {
    const id = get_handle_id(L, 1) orelse return result.push_error(L, "INVALID_ARGUMENT", "expected BufferHandle");
    _ = c.lua_pushinteger(L, @intCast(id));
    return 1;
}

fn lua_get_path(L: ?*c.lua_State) callconv(.c) c_int {
    const res = resolve_buffer(L, 1);
    const buf = switch (res) {
        .err_ret => |code| return code,
        .buf => |b| b,
    };
    if (buf.file_path) |p| {
        _ = c.lua_pushlstring(L, p.ptr, p.len);
        return 1;
    }
    c.lua_pushnil(L);
    return 1;
}

fn lua_set_path(L: ?*c.lua_State) callconv(.c) c_int {
    const res = resolve_buffer(L, 1);
    const buf = switch (res) {
        .err_ret => |code| return code,
        .buf => |b| b,
    };
    var len: usize = 0;
    const path_c = c.lua_tolstring(L, 2, &len);
    if (path_c == null) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected path string");
    }
    const path_slice = path_c[0..len];
    buf.set_file_path(path_slice) catch {
        return result.push_error(L, "OUT_OF_MEMORY", "failed to allocate path");
    };
    return result.push_success_bool(L, true);
}

fn lua_get_name(L: ?*c.lua_State) callconv(.c) c_int {
    const id = get_handle_id(L, 1) orelse return result.push_error(L, "INVALID_ARGUMENT", "expected BufferHandle");
    const res = resolve_buffer(L, 1);
    const buf = switch (res) {
        .err_ret => |code| return code,
        .buf => |b| b,
    };
    if (buf.file_path) |p| {
        const basename = std.fs.path.basename(p);
        _ = c.lua_pushlstring(L, basename.ptr, basename.len);
        return 1;
    }
    var name_buf: [64]u8 = undefined;
    const name_str = std.fmt.bufPrint(&name_buf, "[No Name] {d}", .{id}) catch "[No Name]";
    _ = c.lua_pushlstring(L, name_str.ptr, name_str.len);
    return 1;
}

fn lua_get_buffer_by_id(L: ?*c.lua_State) callconv(.c) c_int {
    const reg = global_registry orelse return result.push_error(L, "INTERNAL_ERROR", "registry not initialized");
    const id: u64 = @intCast(c.lua_tointegerx(L, 1, null));
    if (reg.get(id) != null) {
        push_buffer_handle(L, id);
        return 1;
    }
    c.lua_pushnil(L);
    return 1;
}

fn lua_list_buffers(L: ?*c.lua_State) callconv(.c) c_int {
    const reg = global_registry orelse return result.push_error(L, "INTERNAL_ERROR", "registry not initialized");

    const ids = reg.list_buffers(std.heap.c_allocator) catch return result.push_error(L, "OUT_OF_MEMORY", "failed to allocate buffer list");
    defer std.heap.c_allocator.free(ids);

    c.lua_createtable(L, @intCast(ids.len), 0);
    for (ids, 0..) |id, idx| {
        c.lua_createtable(L, 0, 5);

        _ = c.lua_pushinteger(L, @intCast(id));
        c.lua_setfield(L, -2, "id");

        if (reg.get(id)) |buf| {
            c.lua_pushboolean(L, if (buf.is_dirty) 1 else 0);
            c.lua_setfield(L, -2, "is_dirty");

            _ = c.lua_pushinteger(L, @intCast(buf.line_count()));
            c.lua_setfield(L, -2, "line_count");

            _ = c.lua_pushinteger(L, @intCast(buf.len()));
            c.lua_setfield(L, -2, "len");

            if (buf.file_path) |p| {
                _ = c.lua_pushlstring(L, p.ptr, p.len);
                c.lua_setfield(L, -2, "path");

                const basename = std.fs.path.basename(p);
                _ = c.lua_pushlstring(L, basename.ptr, basename.len);
                c.lua_setfield(L, -2, "name");
            } else {
                c.lua_pushnil(L);
                c.lua_setfield(L, -2, "path");

                var name_buf: [64]u8 = undefined;
                const name_str = std.fmt.bufPrint(&name_buf, "[No Name] {d}", .{id}) catch "[No Name]";
                _ = c.lua_pushlstring(L, name_str.ptr, name_str.len);
                c.lua_setfield(L, -2, "name");
            }
        }

        c.lua_rawseti(L, -2, @intCast(idx + 1));
    }
    return 1;
}

fn lua_len(L: ?*c.lua_State) callconv(.c) c_int {
    const res = resolve_buffer(L, 1);
    switch (res) {
        .err_ret => |code| return code,
        .buf => |b| return result.push_success_int(L, @intCast(b.len())),
    }
}

fn lua_line_count(L: ?*c.lua_State) callconv(.c) c_int {
    const res = resolve_buffer(L, 1);
    switch (res) {
        .err_ret => |code| return code,
        .buf => |b| return result.push_success_int(L, @intCast(b.line_count())),
    }
}

fn lua_insert(L: ?*c.lua_State) callconv(.c) c_int {
    const res = resolve_buffer(L, 1);
    const buf = switch (res) {
        .err_ret => |code| return code,
        .buf => |b| b,
    };

    if (c.lua_isinteger(L, 2) == 0 or c.lua_type(L, 3) != c.LUA_TSTRING) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected (offset: int, text: string)");
    }

    const offset_int = c.lua_tointegerx(L, 2, null);
    if (offset_int < 0) {
        return result.push_error(L, "OUT_OF_BOUNDS", "offset cannot be negative");
    }
    const offset: usize = @intCast(offset_int);

    var str_len: usize = 0;
    const str_ptr = c.lua_tolstring(L, 3, &str_len);
    const text = str_ptr[0..str_len];

    buf.insert(offset, text) catch |err| switch (err) {
        error.OutOfBounds => return result.push_error(L, "OUT_OF_BOUNDS", "offset exceeds buffer length"),
        error.OutOfMemory => return result.push_error(L, "OUT_OF_MEMORY", "failed to allocate memory"),
    };

    return result.push_success_bool(L, true);
}

fn lua_delete(L: ?*c.lua_State) callconv(.c) c_int {
    const res = resolve_buffer(L, 1);
    const buf = switch (res) {
        .err_ret => |code| return code,
        .buf => |b| b,
    };

    if (c.lua_isinteger(L, 2) == 0 or c.lua_isinteger(L, 3) == 0) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected (offset: int, count: int)");
    }

    const offset_int = c.lua_tointegerx(L, 2, null);
    const count_int = c.lua_tointegerx(L, 3, null);
    if (offset_int < 0 or count_int < 0) {
        return result.push_error(L, "OUT_OF_BOUNDS", "offset and count cannot be negative");
    }
    const offset: usize = @intCast(offset_int);
    const count: usize = @intCast(count_int);

    buf.delete(offset, count) catch |err| switch (err) {
        error.OutOfBounds => return result.push_error(L, "OUT_OF_BOUNDS", "delete range exceeds buffer length"),
        error.OutOfMemory => return result.push_error(L, "OUT_OF_MEMORY", "failed to allocate memory"),
    };

    return result.push_success_bool(L, true);
}

fn lua_get_slice(L: ?*c.lua_State) callconv(.c) c_int {
    const res = resolve_buffer(L, 1);
    const buf = switch (res) {
        .err_ret => |code| return code,
        .buf => |b| b,
    };

    if (c.lua_isinteger(L, 2) == 0 or c.lua_isinteger(L, 3) == 0) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected (start: int, end: int)");
    }

    const start_int = c.lua_tointegerx(L, 2, null);
    const end_int = c.lua_tointegerx(L, 3, null);
    if (start_int < 0 or end_int < 0 or start_int > end_int) {
        return result.push_error(L, "OUT_OF_BOUNDS", "invalid slice boundaries");
    }
    const start: usize = @intCast(start_int);
    const end: usize = @intCast(end_int);

    const registry = global_registry orelse {
        return result.push_error(L, "INTERNAL_ERROR", "registry not initialized");
    };

    const slice = buf.get_slice(registry.allocator, start, end) catch |err| switch (err) {
        error.OutOfBounds => return result.push_error(L, "OUT_OF_BOUNDS", "slice exceeds buffer length"),
        error.OutOfMemory => return result.push_error(L, "OUT_OF_MEMORY", "failed to allocate memory"),
    };
    defer registry.allocator.free(slice);

    return result.push_success_str(L, slice);
}

fn lua_get_line(L: ?*c.lua_State) callconv(.c) c_int {
    const res = resolve_buffer(L, 1);
    const buf = switch (res) {
        .err_ret => |code| return code,
        .buf => |b| b,
    };

    if (c.lua_isinteger(L, 2) == 0) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected (line_idx: int)");
    }

    const line_idx_int = c.lua_tointegerx(L, 2, null);
    if (line_idx_int < 0) {
        return result.push_error(L, "OUT_OF_BOUNDS", "line index cannot be negative");
    }
    const line_idx: usize = @intCast(line_idx_int);
    if (line_idx >= buf.line_count()) {
        return result.push_error(L, "OUT_OF_BOUNDS", "line index exceeds line count");
    }

    const registry = global_registry orelse {
        return result.push_error(L, "INTERNAL_ERROR", "registry not initialized");
    };

    const line_opt = buf.get_line(registry.allocator, line_idx) catch |err| switch (err) {
        error.OutOfBounds => return result.push_error(L, "OUT_OF_BOUNDS", "line index out of bounds"),
        error.OutOfMemory => return result.push_error(L, "OUT_OF_MEMORY", "failed to allocate memory"),
    };

    if (line_opt) |line| {
        defer registry.allocator.free(line);
        return result.push_success_str(L, line);
    } else {
        return result.push_error(L, "OUT_OF_BOUNDS", "line index out of bounds");
    }
}

fn lua_is_dirty(L: ?*c.lua_State) callconv(.c) c_int {
    const res = resolve_buffer(L, 1);
    const buf = switch (res) {
        .err_ret => |code| return code,
        .buf => |b| b,
    };
    return result.push_success_bool(L, buf.is_dirty);
}

fn lua_save(L: ?*c.lua_State) callconv(.c) c_int {
    const res = resolve_buffer(L, 1);
    const buf = switch (res) {
        .err_ret => |code| return code,
        .buf => |b| b,
    };

    var str_len: usize = 0;
    const path_c = c.lua_tolstring(L, 2, &str_len);
    if (path_c == null) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected path string");
    }
    const path_slice = path_c[0..str_len];
    const registry = global_registry orelse return result.push_error(L, "INTERNAL_ERROR", "registry not initialized");

    const path_z = registry.allocator.dupeZ(u8, path_slice) catch {
        return result.push_error(L, "OUT_OF_MEMORY", "failed to allocate path");
    };
    defer registry.allocator.free(path_z);

    const b_id: ?usize = if (get_handle_id(L, 1)) |hid| @intCast(hid) else null;
    events.emit_event(L, .buf_write_pre, .{ .buf_id = b_id, .buf_path = path_slice });

    buf.save_to_file(path_z) catch |err| switch (err) {
        error.FileOpenFailed => return result.push_error(L, "FILE_OPEN_FAILED", "could not create or open file"),
        error.WriteFailed => return result.push_error(L, "WRITE_FAILED", "failed to write to file"),
        error.OutOfMemory => return result.push_error(L, "OUT_OF_MEMORY", "out of memory"),
        else => return result.push_error(L, "IO_ERROR", "failed to save file"),
    };

    events.emit_event(L, .buf_write_post, .{ .buf_id = b_id, .buf_path = path_slice });

    return result.push_success_bool(L, true);
}

fn lua_replace(L: ?*c.lua_State) callconv(.c) c_int {
    const res = resolve_buffer(L, 1);
    const buf = switch (res) {
        .err_ret => |code| return code,
        .buf => |b| b,
    };

    var pat_len: usize = 0;
    const pat_ptr = c.lua_tolstring(L, 2, &pat_len);
    if (pat_ptr == null) return result.push_error(L, "INVALID_ARGUMENT", "expected pattern string");
    const pattern = pat_ptr[0..pat_len];

    var rep_len: usize = 0;
    const rep_ptr = c.lua_tolstring(L, 3, &rep_len);
    if (rep_ptr == null) return result.push_error(L, "INVALID_ARGUMENT", "expected replacement string");
    const replacement = rep_ptr[0..rep_len];

    const range_start: usize = if (c.lua_isinteger(L, 4) != 0) @intCast(@max(0, c.lua_tointegerx(L, 4, null))) else 0;
    const range_end: usize = if (c.lua_isinteger(L, 5) != 0) @intCast(@max(0, c.lua_tointegerx(L, 5, null))) else buf.len();
    const all = if (c.lua_isboolean(L, 6)) (c.lua_toboolean(L, 6) != 0) else true;

    const search_mod = @import("../buffer/search.zig");
    const replaced = search_mod.replace_in_range(
        buf,
        std.heap.c_allocator,
        pattern,
        replacement,
        range_start,
        range_end,
        all,
    ) catch |err| switch (err) {
        error.OutOfMemory => return result.push_error(L, "OUT_OF_MEMORY", "out of memory"),
        else => return result.push_error(L, "INTERNAL_ERROR", "replace failed"),
    };

    _ = c.lua_pushinteger(L, @intCast(replaced));
    c.lua_pushnil(L);
    c.lua_pushnil(L);
    return 3;
}

fn lua_buf_undo(L: ?*c.lua_State) callconv(.c) c_int {
    const res = resolve_buffer(L, 1);
    const buf = switch (res) {
        .err_ret => |code| return code,
        .buf => |b| b,
    };
    const step = buf.undo();
    return result.push_success_bool(L, step != null);
}

fn lua_buf_redo(L: ?*c.lua_State) callconv(.c) c_int {
    const res = resolve_buffer(L, 1);
    const buf = switch (res) {
        .err_ret => |code| return code,
        .buf => |b| b,
    };
    const step = buf.redo();
    return result.push_success_bool(L, step != null);
}

// -----------------------------------------------------------------------------
// Tests for Phase 2
// -----------------------------------------------------------------------------
const testing = std.testing;

fn run_lua_test(code: [:0]const u8) !void {
    const L = c.luaL_newstate();
    if (L == null) return error.LuaInitFailed;
    defer c.lua_close(L);
    c.luaL_openlibs(L);

    var registry = BufferRegistry.init(testing.allocator);
    defer registry.deinit();

    g_quit_requested = false;
    current_buffer_id = null;
    init_binding(L, &registry);

    if (c.luaL_loadstring(L, code) != 0) {
        const err_msg = c.lua_tolstring(L, -1, null);
        std.debug.print("Lua Load Error: {s}\n", .{err_msg});
        return error.LuaLoadError;
    }

    if (c.lua_pcallk(L, 0, 0, 0, 0, null) != 0) {
        const err_msg = c.lua_tolstring(L, -1, null);
        std.debug.print("Lua Runtime Error: {s}\n", .{err_msg});
        return error.LuaRuntimeError;
    }
}

test "test_lua_create_buffer" {
    const script =
        \\local buf, err, msg = editor.create_buffer()
        \\assert(buf ~= nil and err == nil and msg == nil)
        \\local len, err2, msg2 = buf:len()
        \\assert(len == 0 and err2 == nil and msg2 == nil)
        \\local lines, err3, msg3 = buf:line_count()
        \\assert(lines == 1 and err3 == nil and msg3 == nil)
    ;
    try run_lua_test(script);
}

test "test_lua_invalid_handle_safety" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\local ok, err, msg = editor.close_buffer(buf)
        \\assert(ok == true and err == nil and msg == nil)
        \\local res, err2, msg2 = buf:len()
        \\assert(res == nil)
        \\assert(err2 == "INVALID_HANDLE")
        \\assert(msg2 ~= nil)
    ;
    try run_lua_test(script);
}

test "test_lua_buffer_insert_and_slice" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\local ok, err, msg = buf:insert(0, "Hello, Lua!")
        \\assert(ok == true and err == nil and msg == nil)
        \\local slice, err2, msg2 = buf:get_slice(0, 5)
        \\assert(slice == "Hello" and err2 == nil and msg2 == nil)
    ;
    try run_lua_test(script);
}

test "test_lua_buffer_multibyte_utf8" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\local ok, _, _ = buf:insert(0, "日本語 🚀")
        \\assert(ok == true)
        \\local total_len, _, _ = buf:len()
        \\local slice, err, msg = buf:get_slice(0, total_len)
        \\assert(slice == "日本語 🚀" and err == nil and msg == nil)
    ;
    try run_lua_test(script);
}

test "test_lua_buffer_delete" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\buf:insert(0, "abcdef")
        \\local ok, err, msg = buf:delete(2, 2)
        \\assert(ok == true and err == nil and msg == nil)
        \\local total_len, _, _ = buf:len()
        \\local slice, _, _ = buf:get_slice(0, total_len)
        \\assert(slice == "abef")
    ;
    try run_lua_test(script);
}

test "test_lua_buffer_get_line" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\buf:insert(0, "alpha\nbeta\ngamma")
        \\local line, err, msg = buf:get_line(1)
        \\assert(line == "beta" and err == nil and msg == nil)
    ;
    try run_lua_test(script);
}

test "test_lua_buffer_get_invalid_line" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\local line, err, msg = buf:get_line(99)
        \\assert(line == nil)
        \\assert(err == "OUT_OF_BOUNDS")
        \\assert(msg ~= nil)
    ;
    try run_lua_test(script);
}

test "test_lua_buffer_out_of_bounds_insert_error" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\local ok, err, msg = buf:insert(10, "fail")
        \\assert(ok == nil)
        \\assert(err == "OUT_OF_BOUNDS")
        \\assert(msg ~= nil)
    ;
    try run_lua_test(script);
}

test "test_lua_buffer_out_of_bounds_delete_error" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\buf:insert(0, "abc")
        \\local ok, err, msg = buf:delete(2, 5)
        \\assert(ok == nil)
        \\assert(err == "OUT_OF_BOUNDS")
        \\assert(msg ~= nil)
    ;
    try run_lua_test(script);
}

test "test_lua_buffer_invalid_argument_types" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\local ok, err, msg = buf:insert("bad_offset", 123)
        \\assert(ok == nil)
        \\assert(err == "INVALID_ARGUMENT")
        \\assert(msg ~= nil)
    ;
    try run_lua_test(script);
}

test "test_lua_bind_key_and_trigger" {
    const script =
        \\local triggered = false
        \\editor.bind_key("<C-f>", function() triggered = true end)
        \\editor.dispatch_key_combo("<C-f>")
        \\assert(triggered == true)
    ;
    try run_lua_test(script);
}

test "test_lua_buffer_is_dirty" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\local dirty, _, _ = buf:is_dirty()
        \\assert(dirty == false)
        \\buf:insert(0, "edit")
        \\local dirty_after, _, _ = buf:is_dirty()
        \\assert(dirty_after == true)
    ;
    try run_lua_test(script);
}

test "test_lua_editor_read_write_file" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\buf:insert(0, "saved from lua")
        \\local ok, err, msg = buf:save("/tmp/em_lua_save.txt")
        \\assert(ok == true)
        \\local is_d, _, _ = buf:is_dirty()
        \\assert(is_d == false)
        \\
        \\local loaded, l_err, l_msg = editor.read_file("/tmp/em_lua_save.txt")
        \\assert(loaded ~= nil)
        \\local slice, _, _ = loaded:get_slice(0, 14)
        \\assert(slice == "saved from lua")
        \\os.remove("/tmp/em_lua_save.txt")
    ;
    try run_lua_test(script);
}

test "test_lua_command_registry_and_dispatch" {
    const script =
        \\local executed = false
        \\editor.create_command("testcmd", function(args)
        \\    assert(args == "hello world")
        \\    executed = true
        \\end)
        \\local ok = editor.dispatch_command(":testcmd hello world")
        \\assert(ok == true)
        \\assert(executed == true)
    ;
    try run_lua_test(script);
}

test "test_lua_builtin_commands_write_and_quit" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\editor.set_current_buffer(buf)
        \\buf:insert(0, "content")
        \\
        \\-- :q fails when buffer is dirty
        \\editor.dispatch_command(":q")
        \\assert(editor.get_last_error():find("No write since last change") ~= nil)
        \\assert(editor.is_quit_requested() == false)
        \\
        \\-- :w writes and cleans dirty
        \\editor.dispatch_command(":w /tmp/em_builtin_write.txt")
        \\assert(buf:is_dirty() == false)
        \\
        \\-- :q now succeeds
        \\editor.dispatch_command(":q")
        \\assert(editor.is_quit_requested() == true)
        \\os.remove("/tmp/em_builtin_write.txt")
    ;
    try run_lua_test(script);
}

test "test_lua_write_with_and_without_filepath" {
    const script =
        \\local path = "/tmp/em_test_w_path.txt"
        \\local buf, _, _ = editor.create_buffer()
        \\editor.set_current_buffer(buf)
        \\buf:insert(0, "first version")
        \\
        \\-- :w without path fails initially on untitled buffer
        \\local ok1 = editor.dispatch_command(":w")
        \\assert(ok1 == true)
        \\assert(editor.get_last_error() == "No file name")
        \\assert(buf:is_dirty() == true)
        \\
        \\-- :w with explicit filepath succeeds and sets buffer path
        \\local ok2 = editor.dispatch_command(":w " .. path)
        \\assert(ok2 == true)
        \\assert(editor.get_last_error() == "")
        \\assert(buf:is_dirty() == false)
        \\assert(buf:get_path() == path)
        \\
        \\-- make another edit
        \\buf:insert(13, " modified")
        \\assert(buf:is_dirty() == true)
        \\
        \\-- :w without path now succeeds using the established filepath
        \\local ok3 = editor.dispatch_command(":w")
        \\assert(ok3 == true)
        \\assert(editor.get_last_error() == "")
        \\assert(buf:is_dirty() == false)
        \\
        \\-- verify file content on disk
        \\local loaded, _, _ = editor.read_file(path)
        \\assert(loaded ~= nil)
        \\local content, _, _ = loaded:get_slice(0, loaded:len())
        \\assert(content == "first version modified")
        \\os.remove(path)
    ;
    try run_lua_test(script);
}

test "test_lua_keymap_set_and_lookup" {
    const script =
        \\local called = false
        \\editor.keymap.set("n", "gh", function() called = true end)
        \\local entry = editor.keymap.get("n", "gh")
        \\assert(entry ~= nil)
        \\assert(type(entry.rhs) == "function")
        \\entry.rhs()
        \\assert(called == true)
    ;
    try run_lua_test(script);
}

test "test_lua_keymap_leader_key_expansion" {
    const script =
        \\editor.g.mapleader = ","
        \\editor.keymap.set("n", "<leader>w", ":w<CR>")
        \\local entry = editor.keymap.get("n", ",w")
        \\assert(entry ~= nil)
        \\assert(entry.rhs == ":w<CR>")
        \\
        \\editor.g.mapleader = " "
        \\editor.keymap.set("n", "<leader>q", ":q<CR>")
        \\local entry_sp = editor.keymap.get("n", " q")
        \\assert(entry_sp ~= nil)
        \\assert(entry_sp.rhs == ":q<CR>")
    ;
    try run_lua_test(script);
}

test "test_lua_keymap_command_string_dispatch" {
    const script =
        \\editor.keymap.set("n", "gw", ":echo keymap_echo_test<CR>")
        \\local ok, kind = editor.keymap.dispatch("n", "gw")
        \\assert(ok == true)
        \\assert(kind == "command")
        \\assert(editor.get_last_message() == "keymap_echo_test")
    ;
    try run_lua_test(script);
}

test "test_lua_keymap_function_callback_dispatch" {
    const script =
        \\local count = 0
        \\editor.keymap.set("n", "gx", function() count = count + 1 end)
        \\local ok, kind = editor.keymap.dispatch("n", "gx")
        \\assert(ok == true)
        \\assert(kind == "executed")
        \\assert(count == 1)
    ;
    try run_lua_test(script);
}

test "test_lua_keymap_multi_key_sequence" {
    const script =
        \\local triggered = false
        \\editor.g.mapleader = " "
        \\editor.keymap.set("n", "<leader>ff", function() triggered = true end)
        \\
        \\local res1, val1 = editor.keymap.feed("n", " ")
        \\assert(res1 == "pending")
        \\assert(val1 == " ")
        \\
        \\local res2, val2 = editor.keymap.feed("n", "f")
        \\assert(res2 == "pending")
        \\assert(val2 == " f")
        \\
        \\local res3, val3 = editor.keymap.feed("n", "f")
        \\assert(res3 == "matched")
        \\assert(triggered == true)
    ;
    try run_lua_test(script);
}

test "test_lua_clipboard_get_and_set" {
    clipboard.enable_mock(true);
    defer clipboard.enable_mock(false);

    const script =
        \\editor.clipboard.set("lua clipboard text")
        \\local text = editor.clipboard.get()
        \\assert(text == "lua clipboard text")
    ;
    try run_lua_test(script);
}

test "test_lua_list_buffers" {
    const script =
        \\local b1, _, _ = editor.create_buffer()
        \\b1:insert(0, "first buffer")
        \\local b2, _, _ = editor.create_buffer()
        \\b2:insert(0, "second buffer")
        \\
        \\local list = editor.list_buffers()
        \\assert(#list >= 2)
        \\local found1, found2 = false, false
        \\for _, entry in ipairs(list) do
        \\    if entry.id == b1:get_id() then found1 = true; assert(entry.is_dirty == true) end
        \\    if entry.id == b2:get_id() then found2 = true end
        \\end
        \\assert(found1 and found2)
    ;
    try run_lua_test(script);
}

test "test_lua_buffer_next_and_prev" {
    const script =
        \\local b1, _, _ = editor.create_buffer()
        \\local b2, _, _ = editor.create_buffer()
        \\local b3, _, _ = editor.create_buffer()
        \\
        \\editor.set_current_buffer(b1)
        \\editor.dispatch_command(":bn")
        \\assert(editor.get_current_buffer():get_id() == b2:get_id())
        \\editor.dispatch_command(":bnext")
        \\assert(editor.get_current_buffer():get_id() == b3:get_id())
        \\editor.dispatch_command(":bn")
        \\assert(editor.get_current_buffer():get_id() == b1:get_id())
        \\
        \\editor.dispatch_command(":bp")
        \\assert(editor.get_current_buffer():get_id() == b3:get_id())
    ;
    try run_lua_test(script);
}

test "test_lua_buffer_switch_by_id_and_name" {
    const script =
        \\local b1, _, _ = editor.create_buffer()
        \\local b2, _, _ = editor.create_buffer()
        \\b2:save("/tmp/em_switch_test.lua")
        \\
        \\editor.set_current_buffer(b1)
        \\editor.dispatch_command(":b " .. tostring(b2:get_id()))
        \\assert(editor.get_current_buffer():get_id() == b2:get_id())
        \\
        \\editor.dispatch_command(":b " .. tostring(b1:get_id()))
        \\assert(editor.get_current_buffer():get_id() == b1:get_id())
        \\
        \\editor.dispatch_command(":b switch_test")
        \\assert(editor.get_current_buffer():get_id() == b2:get_id())
        \\os.remove("/tmp/em_switch_test.lua")
    ;
    try run_lua_test(script);
}

test "test_lua_buffer_delete_clean_and_dirty" {
    const script =
        \\local b1, _, _ = editor.create_buffer()
        \\local b2, _, _ = editor.create_buffer()
        \\editor.set_current_buffer(b1)
        \\b1:insert(0, "unsaved change")
        \\
        \\-- :bd fails on dirty
        \\editor.dispatch_command(":bd")
        \\assert(editor.get_last_error():find("No write since last change") ~= nil)
        \\assert(editor.get_current_buffer():get_id() == b1:get_id())
        \\
        \\-- :bd! forces deletion
        \\editor.dispatch_command(":bd!")
        \\assert(editor.get_current_buffer():get_id() == b2:get_id())
    ;
    try run_lua_test(script);
}

test "test_lua_buffer_delete_last_spawns_scratch" {
    const script =
        \\local b1, _, _ = editor.create_buffer()
        \\editor.set_current_buffer(b1)
        \\local list = editor.list_buffers()
        \\assert(#list >= 1)
        \\for _, entry in ipairs(list) do
        \\    editor.dispatch_command(":bd! " .. tostring(entry.id))
        \\end
        \\
        \\local cur = editor.get_current_buffer()
        \\assert(cur ~= nil)
        \\assert(cur:is_dirty() == false)
        \\assert(cur:len() == 0)
    ;
    try run_lua_test(script);
}

test "test_lua_undo_tree_query" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\editor.set_current_buffer(buf)
        \\buf:insert(0, "first")
        \\buf:insert(5, " second")
        \\
        \\local tree = editor.undo.tree(buf)
        \\assert(tree ~= nil)
        \\assert(tree.seq_cur == 2)
        \\assert(tree.seq_last == 2)
        \\assert(#tree.entries >= 2)
        \\assert(tree.entries[1].seq == 1)
        \\assert(tree.entries[2].seq == 2)
    ;
    try run_lua_test(script);
}

test "test_lua_undo_persistence_roundtrip" {
    const script =
        \\local test_file = "/tmp/em_lua_undo_persist.txt"
        \\local b1, _, _ = editor.create_buffer()
        \\b1:insert(0, "first modification\n")
        \\b1:insert(19, "second modification\n")
        \\local ok, err, msg = b1:save(test_file)
        \\assert(ok == true)
        \\
        \\local b2, err2, msg2 = editor.read_file(test_file)
        \\assert(b2 ~= nil)
        \\local tree = editor.undo.tree(b2)
        \\assert(tree ~= nil)
        \\assert(tree.seq_cur == 2)
        \\assert(#tree.entries >= 2)
        \\os.remove(test_file)
    ;
    try run_lua_test(script);
}

test "test_lua_substitute_commands" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\editor.set_current_buffer(buf)
        \\buf:insert(0, "alpha beta alpha gamma")
        \\
        \\-- Replace first occurrence without 'g'
        \\editor.dispatch_command(":s/alpha/OMEGA/")
        \\local s1, _, _ = buf:get_slice(0, buf:len())
        \\assert(s1 == "OMEGA beta alpha gamma")
        \\
        \\-- Replace all occurrences with 'g'
        \\editor.dispatch_command(":%s/alpha/ZETA/g")
        \\local s2, _, _ = buf:get_slice(0, buf:len())
        \\assert(s2 == "OMEGA beta ZETA gamma")
        \\
        \\-- Undo works in a single step
        \\local u_ok, _, _ = buf:undo()
        \\assert(u_ok == true)
        \\local s3, _, _ = buf:get_slice(0, buf:len())
        \\assert(s3 == "OMEGA beta alpha gamma")
    ;
    try run_lua_test(script);
}

test "test_vim_goto_line_colon_command" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\editor.set_current_buffer(buf)
        \\buf:insert(0, "line 1\nline 2\nline 3\nline 4\nline 5\n")
        \\
        \\editor.dispatch_command(":3")
        \\local l, c = editor.get_cursor()
        \\assert(l == 2)
        \\assert(c == 0)
        \\
        \\editor.dispatch_command(":$")
        \\local last_l, _ = editor.get_cursor()
        \\assert(last_l == 5)
    ;
    try run_lua_test(script);
}

test "test_lua_line_number_options" {
    const script =
        \\assert(editor.get_option("number") == true)
        \\assert(editor.get_option("relativenumber") == false)
        \\
        \\editor.dispatch_command(":set rnu")
        \\assert(editor.get_option("relativenumber") == true)
        \\
        \\editor.dispatch_command(":set nornu nonu")
        \\assert(editor.get_option("relativenumber") == false)
        \\assert(editor.get_option("number") == false)
    ;
    try run_lua_test(script);
}

test "test_lua_option_set_and_get" {
    const script =
        \\editor.set("number", false)
        \\assert(editor.get("number") == false)
        \\editor.set("relativenumber", true)
        \\assert(editor.get("relativenumber") == true)
        \\editor.set("scrolloff", 5)
        \\assert(editor.get("scrolloff") == 5)
        \\editor.set("tabstop", 4)
        \\assert(editor.get("tabstop") == 4)
    ;
    try run_lua_test(script);
}

test "test_lua_custom_command_registration" {
    const script =
        \\local called = false
        \\local passed_args = ""
        \\editor.command("Format", function(args)
        \\    called = true
        \\    passed_args = args
        \\end)
        \\local ok = editor.dispatch_command(":Format code --dry-run")
        \\assert(ok == true)
        \\assert(called == true)
        \\assert(passed_args == "code --dry-run")
    ;
    try run_lua_test(script);
}

test "test_lua_autocmd_buf_write_pre" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\editor.set_current_buffer(buf)
        \\buf:insert(0, "content to write")
        \\
        \\local pre_called = false
        \\local post_called = false
        \\editor.on("BufWritePre", function(ev)
        \\    pre_called = true
        \\    assert(ev.buf_id == buf:get_id())
        \\    assert(ev.buf_path == "/tmp/em_autocmd_test.txt")
        \\end)
        \\editor.on("BufWritePost", function(ev)
        \\    post_called = true
        \\    assert(ev.buf_id == buf:get_id())
        \\    assert(ev.buf_path == "/tmp/em_autocmd_test.txt")
        \\end)
        \\
        \\local ok, _, _ = buf:save("/tmp/em_autocmd_test.txt")
        \\assert(ok == true)
        \\assert(pre_called == true)
        \\assert(post_called == true)
    ;
    try run_lua_test(script);
}

test "test_lua_autocmd_mode_changed" {
    const script =
        \\local mode_info = {}
        \\editor.on("ModeChanged", function(ev)
        \\    mode_info.from = ev.from
        \\    mode_info.to = ev.to
        \\end)
        \\
        \\editor.emit("ModeChanged", { from = "normal", to = "insert" })
        \\assert(mode_info.from == "normal")
        \\assert(mode_info.to == "insert")
    ;
    try run_lua_test(script);
}

test "test_lua_autocmd_error_isolation" {
    const script =
        \\local buf, _, _ = editor.create_buffer()
        \\editor.set_current_buffer(buf)
        \\buf:insert(0, "content")
        \\
        \\editor.on("BufWritePre", function(ev)
        \\    error("intentional plugin error during save hook")
        \\end)
        \\
        \\local ok, _, _ = buf:save("/tmp/em_err_isolate.txt")
        \\assert(ok == true)
        \\assert(editor.get_last_error():find("intentional plugin error") ~= nil)
    ;
    try run_lua_test(script);
}

test "test_lua_fs_primitives" {
    const script =
        \\-- Ensure test directory clean
        \\pcall(function() editor.fs_delete("/tmp/em_fs_test_dir/file2.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_fs_test_dir/file1.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_fs_test_dir", true) end)
        \\
        \\local ok, _, _ = editor.fs_mkdir("/tmp/em_fs_test_dir")
        \\assert(ok == true)
        \\assert(editor.is_dir("/tmp/em_fs_test_dir") == true)
        \\
        \\local ok2, _, _ = editor.fs_touch("/tmp/em_fs_test_dir/file1.txt")
        \\assert(ok2 == true)
        \\assert(editor.is_dir("/tmp/em_fs_test_dir/file1.txt") == false)
        \\
        \\local entries = editor.read_dir("/tmp/em_fs_test_dir")
        \\assert(#entries == 1)
        \\assert(entries[1].name == "file1.txt")
        \\assert(entries[1].is_dir == false)
        \\
        \\local ok3, _, _ = editor.fs_rename("/tmp/em_fs_test_dir/file1.txt", "/tmp/em_fs_test_dir/file2.txt")
        \\assert(ok3 == true)
        \\local entries2 = editor.read_dir("/tmp/em_fs_test_dir")
        \\assert(#entries2 == 1)
        \\assert(entries2[1].name == "file2.txt")
        \\
        \\local ok4, _, _ = editor.fs_delete("/tmp/em_fs_test_dir/file2.txt", false)
        \\assert(ok4 == true)
        \\local entries3 = editor.read_dir("/tmp/em_fs_test_dir")
        \\assert(#entries3 == 0)
        \\
        \\local ok5, _, _ = editor.fs_delete("/tmp/em_fs_test_dir", true)
        \\assert(ok5 == true)
        \\assert(editor.is_dir("/tmp/em_fs_test_dir") == false)
    ;
    try run_lua_test(script);
}

test "test_lua_edit_existing_file" {
    const script =
        \\pcall(function() editor.fs_delete("/tmp/em_edit_test.txt", false) end)
        \\editor.fs_touch("/tmp/em_edit_test.txt")
        \\local buf, _, _ = editor.create_buffer()
        \\buf:insert(0, "saved file content")
        \\buf:save("/tmp/em_edit_test.txt")
        \\
        \\editor.dispatch_command(":e /tmp/em_edit_test.txt")
        \\local cur = editor.get_current_buffer()
        \\assert(cur ~= nil)
        \\assert(cur:get_path() == "/tmp/em_edit_test.txt")
        \\local s, _, _ = cur:get_slice(0, cur:len())
        \\assert(s == "saved file content")
    ;
    try run_lua_test(script);
}

test "test_lua_edit_already_open_file" {
    const script =
        \\editor.fs_touch("/tmp/em_edit_test.txt")
        \\local b1, _, _ = editor.read_file("/tmp/em_edit_test.txt")
        \\local b1_id = b1:get_id()
        \\local b2, _, _ = editor.create_buffer()
        \\editor.set_current_buffer(b2)
        \\assert(editor.get_current_buffer():get_id() == b2:get_id())
        \\
        \\editor.dispatch_command(":e /tmp/em_edit_test.txt")
        \\assert(editor.get_current_buffer():get_id() == b1_id)
    ;
    try run_lua_test(script);
}

test "test_lua_edit_new_file" {
    const script =
        \\pcall(function() editor.fs_delete("/tmp/em_nonexistent.txt", false) end)
        \\editor.dispatch_command(":e /tmp/em_nonexistent.txt")
        \\local cur = editor.get_current_buffer()
        \\assert(cur ~= nil)
        \\assert(cur:get_path() == "/tmp/em_nonexistent.txt")
        \\assert(cur:len() == 0)
        \\cur:insert(0, "new content")
        \\editor.dispatch_command(":w")
        \\assert(editor.read_file("/tmp/em_nonexistent.txt") ~= nil)
        \\pcall(function() editor.fs_delete("/tmp/em_nonexistent.txt", false) end)
    ;
    try run_lua_test(script);
}

test "test_lua_oil_open_directory" {
    const script =
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/sub", true) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/b.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/a.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test", true) end)
        \\
        \\editor.fs_mkdir("/tmp/em_oil_test")
        \\editor.fs_mkdir("/tmp/em_oil_test/sub")
        \\editor.fs_touch("/tmp/em_oil_test/b.txt")
        \\editor.fs_touch("/tmp/em_oil_test/a.txt")
        \\
        \\editor.dispatch_command(":e /tmp/em_oil_test")
        \\local cur = editor.get_current_buffer()
        \\assert(editor.oil.is_oil_buffer(cur) == true)
        \\local s, _, _ = cur:get_slice(0, cur:len())
        \\assert(s == "sub/\na.txt\nb.txt\n")
    ;
    try run_lua_test(script);
}

test "test_lua_oil_navigation" {
    const script =
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/sub", true) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/b.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/a.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test", true) end)
        \\editor.fs_mkdir("/tmp/em_oil_test")
        \\editor.fs_mkdir("/tmp/em_oil_test/sub")
        \\editor.fs_touch("/tmp/em_oil_test/b.txt")
        \\editor.fs_touch("/tmp/em_oil_test/a.txt")
        \\
        \\editor.dispatch_command(":e /tmp/em_oil_test")
        \\editor.set_cursor(0, 0)
        \\editor.oil.select_entry()
        \\local cur = editor.get_current_buffer()
        \\assert(cur:get_path() == "/tmp/em_oil_test/sub/")
        \\
        \\editor.oil.parent_dir()
        \\local cur2 = editor.get_current_buffer()
        \\assert(cur2:get_path() == "/tmp/em_oil_test/")
    ;
    try run_lua_test(script);
}

test "test_lua_oil_save_rename" {
    const script =
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/sub", true) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/b.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/a.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/alpha.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test", true) end)
        \\editor.fs_mkdir("/tmp/em_oil_test")
        \\editor.fs_mkdir("/tmp/em_oil_test/sub")
        \\editor.fs_touch("/tmp/em_oil_test/b.txt")
        \\editor.fs_touch("/tmp/em_oil_test/a.txt")
        \\
        \\editor.dispatch_command(":e /tmp/em_oil_test")
        \\local cur = editor.get_current_buffer()
        \\cur:delete(0, cur:len())
        \\cur:insert(0, "sub/\nalpha.txt\nb.txt\n")
        \\
        \\editor.dispatch_command(":w")
        \\
        \\assert(editor.read_file("/tmp/em_oil_test/alpha.txt") ~= nil)
        \\assert(editor.read_file("/tmp/em_oil_test/a.txt") == nil)
    ;
    try run_lua_test(script);
}

test "test_lua_oil_save_delete" {
    const script =
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/sub", true) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/b.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/a.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/alpha.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test", true) end)
        \\editor.fs_mkdir("/tmp/em_oil_test")
        \\editor.fs_mkdir("/tmp/em_oil_test/sub")
        \\editor.fs_touch("/tmp/em_oil_test/b.txt")
        \\editor.fs_touch("/tmp/em_oil_test/alpha.txt")
        \\
        \\editor.dispatch_command(":e /tmp/em_oil_test")
        \\local cur = editor.get_current_buffer()
        \\cur:delete(0, cur:len())
        \\cur:insert(0, "sub/\nalpha.txt\n")
        \\
        \\editor.dispatch_command(":w")
        \\
        \\assert(editor.read_file("/tmp/em_oil_test/b.txt") == nil)
    ;
    try run_lua_test(script);
}

test "test_lua_oil_save_create" {
    const script =
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/sub", true) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/new_dir", true) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/b.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/a.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/alpha.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/gamma.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test", true) end)
        \\editor.fs_mkdir("/tmp/em_oil_test")
        \\editor.fs_mkdir("/tmp/em_oil_test/sub")
        \\editor.fs_touch("/tmp/em_oil_test/alpha.txt")
        \\
        \\editor.dispatch_command(":e /tmp/em_oil_test")
        \\local cur = editor.get_current_buffer()
        \\cur:delete(0, cur:len())
        \\cur:insert(0, "sub/\nnew_dir/\nalpha.txt\ngamma.txt\n")
        \\
        \\editor.dispatch_command(":w")
        \\
        \\assert(editor.is_dir("/tmp/em_oil_test/new_dir") == true)
        \\assert(editor.read_file("/tmp/em_oil_test/gamma.txt") ~= nil)
        \\
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/sub", true) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/new_dir", true) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/alpha.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test/gamma.txt", false) end)
        \\pcall(function() editor.fs_delete("/tmp/em_oil_test", true) end)
    ;
    try run_lua_test(script);
}
