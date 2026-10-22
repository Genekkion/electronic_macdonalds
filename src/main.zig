const std = @import("std");
const root = @import("root.zig");
const c = root.c;

const macos = @cImport({
    @cInclude("macos_window.h");
});

var g_active_buffer: ?*root.Buffer = null;
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

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("Initializing Electronic Macdonalds...\n", .{});

    // 1. Initialize Buffer Registry
    var registry = root.BufferRegistry.init(allocator);
    defer registry.deinit();

    const buf_id = try registry.create_buffer();
    const buf = registry.get(buf_id).?;
    g_active_buffer = buf;

    // Populate initial demo buffer text
    try buf.insert(0,
        \\-- Welcome to Electronic Macdonalds (Zig + Lua Native macOS GUI)
        \\-- Emacs reimagined without the Lisp VM.
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

    // Test Lua interacting with the buffer
    const test_script =
        \\local buf, err, msg = editor.create_buffer()
        \\buf:insert(0, "Scripted buffer created via embedded Lua 5.5!\n")
        \\print("Lua created buffer with line count: " .. buf:line_count())
    ;
    if (c.luaL_loadstring(L, test_script) == 0) {
        _ = c.lua_pcallk(L, 0, 0, 0, 0, null);
    }

    // 3. Initialize macOS Cocoa GUI
    if (!macos.macos_app_init()) return error.AppInitFailed;

    const window = macos.macos_window_create("Electronic Macdonalds", 1024, 768);
    if (window == null) return error.WindowCreateFailed;

    macos.macos_window_attach_editor_view(
        window,
        buf,
        getLineCallback,
        getLineCountCallback,
    );
    macos.macos_window_set_cursor(window, 0, 0);

    std.debug.print("Window ready with CoreText rendering. Running event loop...\n", .{});
    macos.macos_app_run();
}
