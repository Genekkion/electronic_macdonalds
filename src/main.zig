const std = @import("std");
const root = @import("root.zig");
const c = root.c;
const EditorState = root.vim.EditorState;
const KeyEvent = root.event.KeyEvent;
const format_status_line = root.status_line.format_status_line;

const macos = @cImport({
    @cInclude("macos_window.h");
});

var g_active_buffer: ?*root.Buffer = null;
var g_editor = EditorState{};
var g_window: ?*anyopaque = null;
var g_line_buffer: [4096]u8 = undefined;
var g_lua: ?*c.lua_State = null;
var g_registry: ?*root.BufferRegistry = null;

fn getLuaStatusMessage(allocator: std.mem.Allocator) ?[:0]u8 {
    const L = g_lua orelse return null;
    _ = c.lua_getglobal(L, "editor");
    _ = c.lua_getfield(L, -1, "get_last_message");
    if (c.lua_pcallk(L, 0, 1, 0, 0, null) == 0) {
        var len: usize = 0;
        const str = c.lua_tolstring(L, -1, &len);
        if (str != null and len > 0) {
            const res = allocator.dupeZ(u8, str[0..len]) catch null;
            c.lua_pop(L, 2);
            return res;
        }
    }
    c.lua_pop(L, 2);
    return null;
}

fn updateUi() void {
    const win = g_window orelse return;
    const buf = g_active_buffer orelse return;

    const mode_int: c_int = switch (g_editor.mode) {
        .normal => 0,
        .insert => 1,
        .visual => 2,
        .command_line => 3,
    };

    macos.macos_window_set_cursor_mode(
        win,
        @intCast(g_editor.cursor.line),
        @intCast(g_editor.cursor.col),
        mode_int,
    );

    if (g_editor.mode == .command_line) {
        const cmd_str = g_editor.get_cmd_line();
        const status = root.status_line.format_command_line(
            std.heap.c_allocator,
            cmd_str,
        ) catch return;
        defer std.heap.c_allocator.free(status);
        macos.macos_window_set_status_line(win, status.ptr);
    } else {
        const maybe_lua_msg = getLuaStatusMessage(std.heap.c_allocator);
        if (maybe_lua_msg) |msg| {
            defer std.heap.c_allocator.free(msg);
            macos.macos_window_set_status_line(win, msg.ptr);
        } else {
            const status = format_status_line(
                std.heap.c_allocator,
                g_editor.mode,
                "scratch.lua",
                g_editor.cursor.line,
                g_editor.cursor.col,
                buf.line_count(),
            ) catch return;
            defer std.heap.c_allocator.free(status);
            macos.macos_window_set_status_line(win, status.ptr);
        }
    }
}

fn getLineCallback(ctx: ?*anyopaque, line_idx: c_int, out_len: ?*c_int) callconv(.c) [*c]const u8 {
    _ = ctx;
    const buf = g_active_buffer orelse return null;
    if (line_idx < 0) return null;

    const line_opt = buf.get_line(std.heap.c_allocator, @intCast(line_idx)) catch return null;
    if (line_opt) |line| {
        defer std.heap.c_allocator.free(line);
        const len = @min(line.len, g_line_buffer.len);
        @memcpy(g_line_buffer[0..len], line[0..len]);
        if (out_len) |ol| ol.* = @intCast(len);
        return g_line_buffer[0..len].ptr;
    }
    return null;
}

fn getLineCountCallback(ctx: ?*anyopaque) callconv(.c) c_int {
    _ = ctx;
    const buf = g_active_buffer orelse return 0;
    return @intCast(buf.line_count());
}

fn onKeyDownCallback(ctx: ?*anyopaque, chars: [*c]const u8, key_code: c_int, mods: c_int) callconv(.c) void {
    _ = ctx;
    const buf = g_active_buffer orelse return;
    _ = mods;

    var ev = KeyEvent{ .code = .character };
    switch (key_code) {
        53 => ev.code = .escape,
        51 => ev.code = .backspace,
        36 => ev.code = .enter,
        48 => ev.code = .tab,
        123 => ev.code = .left,
        124 => ev.code = .right,
        125 => ev.code = .down,
        126 => ev.code = .up,
        else => {
            if (chars != null and chars[0] != 0) {
                ev.code = .character;
                ev.char = chars[0];
            } else {
                return;
            }
        },
    }

    const was_cmd = (g_editor.mode == .command_line);
    var cmd_copy: [256]u8 = undefined;
    var cmd_len: usize = 0;
    if (was_cmd and ev.code == .enter) {
        const raw_cmd = g_editor.get_cmd_line();
        cmd_len = @min(raw_cmd.len, cmd_copy.len);
        @memcpy(cmd_copy[0..cmd_len], raw_cmd[0..cmd_len]);
    }

    g_editor.handle_key(buf, ev) catch {};

    if (was_cmd and ev.code == .enter and g_lua != null) {
        const L = g_lua.?;
        _ = c.lua_getglobal(L, "editor");
        _ = c.lua_getfield(L, -1, "dispatch_command");
        _ = c.lua_pushlstring(L, cmd_copy[0..cmd_len].ptr, cmd_len);
        if (c.lua_pcallk(L, 1, 1, 0, 0, null) == 0) {
            c.lua_pop(L, 2);
        } else {
            c.lua_pop(L, 2);
        }

        if (root.lua.is_quit_requested()) {
            std.c.exit(0);
        }

        if (root.lua.get_active_buffer_id()) |new_id| {
            if (g_registry) |reg| {
                if (reg.get(new_id)) |new_buf| {
                    g_active_buffer = new_buf;
                }
            }
        }
    }

    updateUi();
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("Initializing Electronic Macdonalds...\n", .{});

    // 1. Initialize Buffer Registry
    var registry = root.BufferRegistry.init(allocator);
    defer registry.deinit();
    g_registry = &registry;

    const buf_id = try registry.create_buffer();
    const buf = registry.get(buf_id).?;
    g_active_buffer = buf;

    // Populate initial interactive buffer text
    try buf.insert(0,
        \\-- Welcome to Electronic Macdonalds (Native Zig Core + Lua Engine)
        \\-- Vim modal keybindings active:
        \\--   Normal Mode: h/j/k/l, 0/$, w/b, x, dd, i, a, o
        \\--   Insert Mode: typing, Enter, Backspace, Esc
        \\--   Command Mode (:):
        \\--     :w [path]   (Save buffer to disk)
        \\--     :q          (Quit editor, checks dirty flag)
        \\--     :q!         (Force quit editor)
        \\--     :echo <msg> (Echo message to status line)
        \\
        \\local function fibonacci(n)
        \\    if n <= 1 then return n end
        \\    return fibonacci(n - 1) + fibonacci(n - 2)
        \\end
        \\
        \\print("Fibonacci(10) = " .. fibonacci(10))
    );

    // 2. Initialize Lua VM & Bindings
    const L = c.luaL_newstate();
    if (L == null) return error.LuaInitFailed;
    defer c.lua_close(L);
    c.luaL_openlibs(L);

    root.lua.init_binding(L, &registry);
    root.lua.set_active_buffer_id(buf_id);
    g_lua = L;

    // 3. Initialize macOS Cocoa GUI
    if (!macos.macos_app_init()) return error.AppInitFailed;

    const window = macos.macos_window_create("Electronic Macdonalds", 1024, 768);
    if (window == null) return error.WindowCreateFailed;
    g_window = window;

    macos.macos_window_attach_editor_view(
        window,
        buf,
        getLineCallback,
        getLineCountCallback,
        onKeyDownCallback,
    );
    updateUi();

    std.debug.print("Window ready with Lua-powered Vim commands (:w, :q, :q!, :echo).\n", .{});
    macos.macos_app_run();
}
