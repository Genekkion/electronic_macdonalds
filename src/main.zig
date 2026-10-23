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
var g_viewport = root.viewport.Viewport{
    .pixel_width = 1024.0,
    .pixel_height = 768.0 - 22.0,
    .metrics = .{
        .char_width = 8.4,
        .line_height = 17.0,
        .ascent = 12.0,
    },
};
var g_line_buffer: [4096]u8 = undefined;
var g_lua: ?*c.lua_State = null;
var g_registry: ?*root.BufferRegistry = null;

fn macosClipboardSet(text: []const u8) void {
    macos.macos_clipboard_set(text.ptr, @intCast(text.len));
}

fn macosClipboardGet() ?[]const u8 {
    var out_len: c_int = 0;
    const ptr = macos.macos_clipboard_get(&out_len);
    if (ptr != null and out_len > 0) {
        return ptr[0..@intCast(out_len)];
    }
    return null;
}

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

fn getLuaPendingKey(allocator: std.mem.Allocator) ?[:0]u8 {
    const L = g_lua orelse return null;
    _ = c.lua_getglobal(L, "editor");
    _ = c.lua_getfield(L, -1, "keymap");
    _ = c.lua_getfield(L, -1, "get_pending");
    if (c.lua_pcallk(L, 0, 1, 0, 0, null) == 0) {
        var len: usize = 0;
        const str = c.lua_tolstring(L, -1, &len);
        if (str != null and len > 0) {
            const res = allocator.dupeZ(u8, str[0..len]) catch null;
            c.lua_pop(L, 3);
            return res;
        }
    }
    c.lua_pop(L, 3);
    return null;
}

const FeedResult = enum { matched, pending, nomatch };

fn feedKeyToLuaKeymap(mode: root.mode.Mode, key_char: ?u8, key_code: root.event.KeyCode) FeedResult {
    const L = g_lua orelse return .nomatch;

    const mode_str: [*c]const u8 = switch (mode) {
        .normal => "n",
        .insert => "i",
        .visual, .visual_line => "v",
        .command_line => "c",
    };

    var key_buf: [4]u8 = undefined;
    var key_len: usize = 0;
    if (key_char) |ch| {
        key_buf[0] = ch;
        key_len = 1;
    } else {
        switch (key_code) {
            .escape => {
                key_buf[0] = 0x1b;
                key_len = 1;
            },
            .enter => {
                key_buf[0] = '\n';
                key_len = 1;
            },
            .backspace => {
                key_buf[0] = 0x08;
                key_len = 1;
            },
            .tab => {
                key_buf[0] = '\t';
                key_len = 1;
            },
            else => return .nomatch,
        }
    }

    _ = c.lua_getglobal(L, "editor");
    _ = c.lua_getfield(L, -1, "keymap");
    _ = c.lua_getfield(L, -1, "feed");
    _ = c.lua_pushstring(L, mode_str);
    _ = c.lua_pushlstring(L, &key_buf, key_len);

    if (c.lua_pcallk(L, 2, 2, 0, 0, null) == 0) {
        const status_str = c.lua_tolstring(L, -2, null);
        var result_enum: FeedResult = .nomatch;
        if (status_str != null) {
            if (std.mem.eql(u8, std.mem.span(status_str), "matched")) {
                result_enum = .matched;
            } else if (std.mem.eql(u8, std.mem.span(status_str), "pending")) {
                result_enum = .pending;
            }
        }
        c.lua_pop(L, 4); // pop status, val, keymap, editor
        return result_enum;
    } else {
        c.lua_pop(L, 3); // pop err, keymap, editor
        return .nomatch;
    }
}

fn getLuaOptionBool(opt_name: [:0]const u8, default_val: bool) bool {
    const L = g_lua orelse return default_val;
    _ = c.lua_getglobal(L, "editor");
    if (c.lua_istable(L, -1)) {
        _ = c.lua_getfield(L, -1, "get_option");
        if (c.lua_isfunction(L, -1)) {
            _ = c.lua_pushstring(L, opt_name.ptr);
            if (c.lua_pcallk(L, 1, 1, 0, 0, null) == 0) {
                if (c.lua_isboolean(L, -1)) {
                    const res = (c.lua_toboolean(L, -1) != 0);
                    c.lua_pop(L, 2);
                    return res;
                }
                c.lua_pop(L, 1);
            }
        } else {
            c.lua_pop(L, 1);
        }
    }
    c.lua_pop(L, 1);
    return default_val;
}

fn updateUi() void {
    const win = g_window orelse return;
    const buf = g_active_buffer orelse return;

    const show_nu = getLuaOptionBool("number", true);
    const rel_nu = getLuaOptionBool("relativenumber", false);
    macos.macos_window_set_line_numbers(win, show_nu, rel_nu);

    // Update scrolling with dynamic padding
    g_viewport.update_scroll_with_padding(g_editor.cursor.line, buf.line_count(), 4);
    macos.macos_window_set_scroll_top(win, @intCast(g_viewport.scroll_top_line));

    const mode_int: c_int = switch (g_editor.mode) {
        .normal => 0,
        .insert => 1,
        .visual, .visual_line => 2,
        .command_line => 3,
    };

    macos.macos_window_set_cursor_mode(
        win,
        @intCast(g_editor.cursor.line),
        @intCast(g_editor.cursor.col),
        mode_int,
    );

    if (g_editor.get_selection_range(buf)) |sel| {
        macos.macos_window_set_selection(
            win,
            @intCast(sel.start_line),
            @intCast(sel.start_col),
            @intCast(sel.end_line),
            @intCast(sel.end_col),
            true,
            sel.is_line,
        );
    } else {
        macos.macos_window_set_selection(win, 0, 0, 0, 0, false, false);
    }

    if (g_editor.hlsearch and g_editor.get_search_pattern().len > 0) {
        const matches = root.search.find_in_range(buf, 0, buf.len(), g_editor.get_search_pattern(), std.heap.c_allocator) catch null;
        if (matches) |m_list| {
            defer std.heap.c_allocator.free(m_list);
            var triplets: [256 * 3]c_int = undefined;
            var r_count: usize = 0;
            for (m_list) |m| {
                if (r_count >= 256) break;
                const m_line = buf.lines.get_line_at_offset(m.offset) orelse continue;
                const line_start = buf.lines.get_line_start(m_line) orelse 0;
                const m_col = if (m.offset >= line_start) m.offset - line_start else 0;

                triplets[r_count * 3 + 0] = @intCast(m_line);
                triplets[r_count * 3 + 1] = @intCast(m_col);
                triplets[r_count * 3 + 2] = @intCast(m.len);
                r_count += 1;
            }
            macos.macos_window_set_search_highlights(win, true, &triplets, @intCast(r_count));
        } else {
            macos.macos_window_set_search_highlights(win, false, null, 0);
        }
    } else {
        macos.macos_window_set_search_highlights(win, false, null, 0);
    }

    if (g_editor.mode == .command_line) {
        const cmd_str = g_editor.get_cmd_line();
        const status = root.status_line.format_command_line(
            std.heap.c_allocator,
            g_editor.cmd_prefix,
            cmd_str,
        ) catch return;
        defer std.heap.c_allocator.free(status);
        macos.macos_window_set_status_line(win, status.ptr);
        macos.macos_window_set_command_cursor(win, @intCast(1 + g_editor.cmd_cursor));
    } else {
        macos.macos_window_set_command_cursor(win, -1);
        const maybe_pending = getLuaPendingKey(std.heap.c_allocator);
        if (maybe_pending) |p| {
            defer std.heap.c_allocator.free(p);
            const text = std.fmt.allocPrint(std.heap.c_allocator, "-- KEYMAP: {s} --", .{p}) catch null;
            if (text) |t| {
                defer std.heap.c_allocator.free(t);
                const status = std.heap.c_allocator.dupeZ(u8, t) catch null;
                if (status) |st| {
                    defer std.heap.c_allocator.free(st);
                    macos.macos_window_set_status_line(win, st.ptr);
                }
            }
        } else {
            const maybe_lua_msg = getLuaStatusMessage(std.heap.c_allocator);
            if (maybe_lua_msg) |msg| {
                defer std.heap.c_allocator.free(msg);
                macos.macos_window_set_status_line(win, msg.ptr);
            } else {
            const buf_name = if (buf.file_path) |p| std.fs.path.basename(p) else (if (buf.name) |n| n else "scratch.lua");
            const status = format_status_line(
                std.heap.c_allocator,
                g_editor.mode,
                buf_name,
                g_editor.cursor.line,
                g_editor.cursor.col,
                buf.line_count(),
            ) catch return;
                defer std.heap.c_allocator.free(status);
                macos.macos_window_set_status_line(win, status.ptr);
            }
        }
    }
}

fn saveHistory(allocator: std.mem.Allocator) void {
    if (root.history.HistoryStore.get_default_path(allocator)) |hist_path| {
        defer allocator.free(hist_path);
        g_editor.history.save_to_file(allocator, hist_path) catch {};
    } else |_| {}
}

fn onWindowClose() callconv(.c) void {
    saveHistory(std.heap.c_allocator);
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
        117 => ev.code = .delete,
        115 => ev.code = .home,
        119 => ev.code = .end,
        else => {
            if (chars != null and chars[0] != 0) {
                ev.code = .character;
                ev.char = chars[0];
            } else {
                return;
            }
        },
    }

    // Intercept keys via Lua Keymap Engine if not in command-line mode
    if (g_editor.mode != .command_line and g_lua != null) {
        const feed_res = feedKeyToLuaKeymap(
            g_editor.mode,
            if (ev.code == .character) ev.char else null,
            ev.code,
        );
        switch (feed_res) {
            .matched => {
                if (root.lua.is_quit_requested()) {
                    saveHistory(std.heap.c_allocator);
                    std.c.exit(0);
                }
                if (root.lua.get_active_buffer_id()) |new_id| {
                    if (g_registry) |reg| {
                        if (reg.get(new_id)) |new_buf| {
                            if (g_active_buffer != new_buf) {
                                g_active_buffer = new_buf;
                                g_editor.cursor = .{};
                            }
                        }
                    }
                }
                updateUi();
                return;
            },
            .pending => {
                updateUi();
                return;
            },
            .nomatch => {},
        }
    }

    const was_cmd_line = (g_editor.mode == .command_line);
    const was_colon_cmd = (was_cmd_line and g_editor.cmd_prefix == ':');
    const was_search_cmd = (was_cmd_line and (g_editor.cmd_prefix == '/' or g_editor.cmd_prefix == '?'));
    var cmd_copy: [256]u8 = undefined;
    var cmd_len: usize = 0;
    if (was_colon_cmd and ev.code == .enter) {
        const raw_cmd = g_editor.get_cmd_line();
        cmd_len = @min(raw_cmd.len, cmd_copy.len);
        @memcpy(cmd_copy[0..cmd_len], raw_cmd[0..cmd_len]);
    }

    g_editor.handle_key(buf, ev) catch {};

    if ((was_colon_cmd or was_search_cmd) and ev.code == .enter) {
        saveHistory(std.heap.c_allocator);
    }

    if (was_colon_cmd and ev.code == .enter and g_lua != null) {
        root.lua.set_internal_cursor(g_editor.cursor.line, g_editor.cursor.col);
        const L = g_lua.?;
        _ = c.lua_getglobal(L, "editor");
        _ = c.lua_getfield(L, -1, "dispatch_command");
        _ = c.lua_pushlstring(L, cmd_copy[0..cmd_len].ptr, cmd_len);
        if (c.lua_pcallk(L, 1, 1, 0, 0, null) == 0) {
            c.lua_pop(L, 2);
        } else {
            c.lua_pop(L, 2);
        }

        const cur_info = root.lua.get_internal_cursor();
        if (cur_info.updated) {
            g_editor.cursor.line = cur_info.line;
            g_editor.cursor.col = cur_info.col;
            g_editor.cursor.desired_col = cur_info.col;
        }

        if (root.lua.is_quit_requested()) {
            saveHistory(std.heap.c_allocator);
            std.c.exit(0);
        }

        if (root.lua.get_active_buffer_id()) |new_id| {
            if (g_registry) |reg| {
                if (reg.get(new_id)) |new_buf| {
                    if (g_active_buffer != new_buf) {
                        g_active_buffer = new_buf;
                        g_editor.cursor = .{};
                    }
                }
            }
        }
    }

    updateUi();
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("Initializing Electronic Macdonalds...\n", .{});

    // 0. Load Command and Search History
    if (root.history.HistoryStore.get_default_path(allocator)) |hist_path| {
        defer allocator.free(hist_path);
        g_editor.history.load_from_file(allocator, hist_path) catch {};
    } else |_| {}

    // Initialize system clipboard handlers
    root.clipboard.set_handlers(macosClipboardSet, macosClipboardGet);

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
        \\--   Normal Mode: h/j/k/l, 0/$, w/b, x, dd, i, a, o, p/P
        \\--   Visual Mode: v (char-wise), V (line-wise), y (yank), d (delete)
        \\--   Leader Maps: <Space>w (Save), <Space>q (Quit), <Space>bn/:bp
        \\--   Buffers:
        \\--     :ls / :buffers  (List active buffers)
        \\--     :bn / :bp       (Next / Prev buffer)
        \\--     :b <id_or_name> (Switch to buffer)
        \\--     :bd / :bd!      (Delete buffer)
        \\--   Commands:
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
    macos.macos_window_set_close_callback(window, onWindowClose);

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
