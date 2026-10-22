const std = @import("std");
const root = @import("root.zig");
const c = root.c;
const Cursor = root.cursor.Cursor;

const macos = @cImport({
    @cInclude("macos_window.h");
});

var g_active_buffer: ?*root.Buffer = null;
var g_cursor = Cursor{};
var g_window: ?*anyopaque = null;
var g_line_buffer: [4096]u8 = undefined;

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
    const is_ctrl = (mods & 2) != 0;

    // Emacs navigation bindings (Ctrl + ...)
    if (is_ctrl) {
        if (chars != null and chars[0] != 0) {
            switch (chars[0]) {
                6, 'f' => g_cursor.move_forward(buf), // C-f
                2, 'b' => g_cursor.move_backward(buf), // C-b
                14, 'n' => g_cursor.move_down(buf), // C-n
                16, 'p' => g_cursor.move_up(buf), // C-p
                1, 'a' => { // C-a (line start)
                    g_cursor.col = 0;
                    g_cursor.desired_col = 0;
                },
                5, 'e' => { // C-e (line end)
                    const start = buf.lines.get_line_start(g_cursor.line) orelse 0;
                    const end = buf.lines.get_line_end(g_cursor.line, buf.len()) orelse 0;
                    g_cursor.col = end - start;
                    g_cursor.desired_col = g_cursor.col;
                },
                else => {},
            }
        }
    } else {
        switch (key_code) {
            123 => g_cursor.move_backward(buf), // Left Arrow
            124 => g_cursor.move_forward(buf), // Right Arrow
            125 => g_cursor.move_down(buf), // Down Arrow
            126 => g_cursor.move_up(buf), // Up Arrow
            51 => { // Backspace
                if (g_cursor.col > 0 or g_cursor.line > 0) {
                    const line_start = buf.lines.get_line_start(g_cursor.line) orelse 0;
                    if (g_cursor.col > 0) {
                        const del_pos = line_start + g_cursor.col - 1;
                        buf.delete(del_pos, 1) catch {};
                        g_cursor.col -= 1;
                        g_cursor.desired_col = g_cursor.col;
                    } else if (g_cursor.line > 0) {
                        // Merge with previous line
                        const prev_line_start = buf.lines.get_line_start(g_cursor.line - 1) orelse 0;
                        const prev_line_end = buf.lines.get_line_end(g_cursor.line - 1, buf.len()) orelse 0;
                        const prev_len = prev_line_end - prev_line_start;

                        buf.delete(line_start - 1, 1) catch {};
                        g_cursor.line -= 1;
                        g_cursor.col = prev_len;
                        g_cursor.desired_col = prev_len;
                    }
                }
            },
            36 => { // Return
                const line_start = buf.lines.get_line_start(g_cursor.line) orelse 0;
                const insert_pos = line_start + g_cursor.col;
                buf.insert(insert_pos, "\n") catch {};
                g_cursor.line += 1;
                g_cursor.col = 0;
                g_cursor.desired_col = 0;
            },
            48 => { // Tab -> 4 spaces
                const line_start = buf.lines.get_line_start(g_cursor.line) orelse 0;
                const insert_pos = line_start + g_cursor.col;
                buf.insert(insert_pos, "    ") catch {};
                g_cursor.col += 4;
                g_cursor.desired_col = g_cursor.col;
            },
            else => {
                // Printable character typing
                if (chars != null and chars[0] != 0) {
                    const str_len = std.mem.sliceTo(chars, 0).len;
                    if (str_len > 0 and chars[0] >= 32) {
                        const line_start = buf.lines.get_line_start(g_cursor.line) orelse 0;
                        const insert_pos = line_start + g_cursor.col;
                        buf.insert(insert_pos, chars[0..str_len]) catch {};
                        g_cursor.col += str_len;
                        g_cursor.desired_col = g_cursor.col;
                    }
                }
            },
        }
    }

    if (g_window) |win| {
        macos.macos_window_set_cursor(win, @intCast(g_cursor.line), @intCast(g_cursor.col));
    }
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
        \\-- Emacs keybindings: C-f, C-b, C-n, C-p, C-a, C-e, Arrow keys, typing & backspace!
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

    // Set up initial Lua key bindings
    const init_keymap_script =
        \\editor.bind_key("<C-f>", function() print("Lua hook: forward-char triggered") end)
        \\editor.bind_key("<C-b>", function() print("Lua hook: backward-char triggered") end)
    ;
    if (c.luaL_loadstring(L, init_keymap_script) == 0) {
        _ = c.lua_pcallk(L, 0, 0, 0, 0, null);
    }

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
    macos.macos_window_set_cursor(window, 0, 0);

    std.debug.print("Window ready with interactive keyboard input and blinking cursor.\n", .{});
    macos.macos_app_run();
}
