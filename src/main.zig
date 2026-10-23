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
    } else if (g_editor.last_cmd_len > 0) {
        const last = g_editor.get_last_cmd();
        const base_status = format_status_line(
            std.heap.c_allocator,
            g_editor.mode,
            "main.lua",
            g_editor.cursor.line,
            g_editor.cursor.col,
            buf.line_count(),
        ) catch return;
        defer std.heap.c_allocator.free(base_status);

        const status_slice = std.fmt.allocPrint(
            std.heap.c_allocator,
            "{s}   [echo: {s}]",
            .{ base_status, last },
        ) catch return;
        defer std.heap.c_allocator.free(status_slice);
        const status_z = std.heap.c_allocator.dupeZ(u8, status_slice) catch return;
        defer std.heap.c_allocator.free(status_z);

        macos.macos_window_set_status_line(win, status_z.ptr);
    } else {
        const status = format_status_line(
            std.heap.c_allocator,
            g_editor.mode,
            "main.lua",
            g_editor.cursor.line,
            g_editor.cursor.col,
            buf.line_count(),
        ) catch return;
        defer std.heap.c_allocator.free(status);
        macos.macos_window_set_status_line(win, status.ptr);
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

    g_editor.handle_key(buf, ev) catch {};
    updateUi();
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("Initializing Electronic Macdonalds...\n", .{});

    // 1. Initialize Buffer Registry
    var registry = root.BufferRegistry.init(allocator);
    defer registry.deinit();

    const buf_id = try registry.create_buffer();
    const buf = registry.get(buf_id).?;
    g_active_buffer = buf;

    // Populate initial interactive buffer text
    try buf.insert(0,
        \\-- Welcome to Electronic Macdonalds (Native Zig + Lua Cocoa GUI)
        \\-- Vim modal keybindings active:
        \\--   Normal Mode: h/j/k/l, 0/$, w/b, x, dd, i, a, o
        \\--   Insert Mode: typing, Enter, Backspace, Esc (returns to Normal)
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

    std.debug.print("Window ready with Vim modal editing and dynamic status line.\n", .{});
    macos.macos_app_run();
}
