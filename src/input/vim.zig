const std = @import("std");
const Buffer = @import("../buffer/buffer.zig").Buffer;
const Cursor = @import("cursor.zig").Cursor;
const Mode = @import("mode.zig").Mode;
const KeyEvent = @import("event.zig").KeyEvent;
const KeyCode = @import("event.zig").KeyCode;
const clipboard = @import("../platform/clipboard.zig");
const search_mod = @import("../buffer/search.zig");

fn get_line_len(buf: *const Buffer, line_idx: usize) usize {
    const start = buf.lines.get_line_start(line_idx) orelse return 0;
    const end = buf.lines.get_line_end(line_idx, buf.len()) orelse return 0;
    return if (end >= start) end - start else 0;
}

fn is_word_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn char_kind(c: u8) enum { word, space, punct } {
    if (std.ascii.isWhitespace(c)) return .space;
    if (is_word_char(c)) return .word;
    return .punct;
}

pub const SelectionRange = struct {
    start_line: usize,
    start_col: usize,
    end_line: usize,
    end_col: usize,
    is_line: bool,
};

pub const EditorState = struct {
    mode: Mode = .normal,
    cursor: Cursor = .{},
    anchor: ?Cursor = null,
    pending_cmd: ?u8 = null,
    cmd_line: [256]u8 = [_]u8{0} ** 256,
    cmd_len: usize = 0,
    cmd_cursor: usize = 0,
    last_cmd: [256]u8 = [_]u8{0} ** 256,
    last_cmd_len: usize = 0,
    register: [4096]u8 = [_]u8{0} ** 4096,
    register_len: usize = 0,
    register_is_line: bool = false,
    cmd_prefix: u8 = ':',
    search_pattern: [256]u8 = [_]u8{0} ** 256,
    search_len: usize = 0,
    search_dir: search_mod.Direction = .forward,
    hlsearch: bool = false,
    search_origin: Cursor = .{},

    pub fn get_search_pattern(self: *const EditorState) []const u8 {
        return self.search_pattern[0..self.search_len];
    }

    pub fn jump_to_match(self: *EditorState, buf: *const Buffer, dir: search_mod.Direction, advance: bool) bool {
        const pat = self.get_search_pattern();
        if (pat.len == 0) return false;

        const cur_off = self.cursor.to_offset(buf) orelse 0;
        const from_off = if (advance and dir == .forward) cur_off + 1 else cur_off;

        const match_opt = switch (dir) {
            .forward => search_mod.find_next(buf, from_off, pat),
            .backward => search_mod.find_prev(buf, cur_off, pat),
        };

        if (match_opt) |m| {
            if (self.cursor.from_offset(buf, m.offset)) {
                return true;
            }
        }
        return false;
    }

    pub fn search_word_under_cursor(self: *EditorState, buf: *const Buffer, dir: search_mod.Direction) void {
        const line_idx = self.cursor.line;
        const start = buf.lines.get_line_start(line_idx) orelse return;
        const end = buf.lines.get_line_end(line_idx, buf.len()) orelse return;
        if (start >= end) return;

        var line_buf: [1024]u8 = undefined;
        const line_len = @min(end - start, line_buf.len);
        for (0..line_len) |i| {
            line_buf[i] = buf.byte_at(start + i) orelse break;
        }
        const line_text = line_buf[0..line_len];

        const col = @min(self.cursor.col, if (line_len > 0) line_len - 1 else 0);
        if (line_len == 0 or !is_word_char(line_text[col])) return;

        var word_start = col;
        while (word_start > 0 and is_word_char(line_text[word_start - 1])) {
            word_start -= 1;
        }

        var word_end = col;
        while (word_end < line_len and is_word_char(line_text[word_end])) {
            word_end += 1;
        }

        const word = line_text[word_start..word_end];
        if (word.len == 0) return;

        const copy_len = @min(word.len, self.search_pattern.len);
        @memcpy(self.search_pattern[0..copy_len], word[0..copy_len]);
        self.search_len = copy_len;
        self.search_dir = dir;
        self.hlsearch = true;

        _ = self.jump_to_match(buf, dir, true);
    }

    pub fn get_cmd_line(self: *const EditorState) []const u8 {
        return self.cmd_line[0..self.cmd_len];
    }

    pub fn get_last_cmd(self: *const EditorState) []const u8 {
        return self.last_cmd[0..self.last_cmd_len];
    }

    pub fn get_register(self: *const EditorState) []const u8 {
        return self.register[0..self.register_len];
    }

    pub fn get_selection_range(self: *const EditorState, buf: *const Buffer) ?SelectionRange {
        if (self.mode != .visual and self.mode != .visual_line) return null;
        const anc = self.anchor orelse return null;
        const is_line = (self.mode == .visual_line);

        var start_l = anc.line;
        var start_c = anc.col;
        var end_l = self.cursor.line;
        var end_c = self.cursor.col;

        if (start_l > end_l or (start_l == end_l and start_c > end_c)) {
            std.mem.swap(usize, &start_l, &end_l);
            std.mem.swap(usize, &start_c, &end_c);
        }

        if (is_line) {
            start_c = 0;
            const cur_len = get_line_len(buf, end_l);
            end_c = cur_len;
        }

        return .{
            .start_line = start_l,
            .start_col = start_c,
            .end_line = end_l,
            .end_col = end_c,
            .is_line = is_line,
        };
    }

    fn get_selection_offsets(self: *const EditorState, buf: *const Buffer) ?struct { start: usize, end: usize, is_line: bool } {
        const range = self.get_selection_range(buf) orelse return null;
        const start_line_start = buf.lines.get_line_start(range.start_line) orelse 0;
        const end_line_start = buf.lines.get_line_start(range.end_line) orelse 0;

        var start_offset: usize = 0;
        var end_offset: usize = 0;

        if (range.is_line) {
            start_offset = start_line_start;
            if (range.end_line + 1 < buf.line_count()) {
                end_offset = buf.lines.get_line_start(range.end_line + 1).?;
            } else {
                end_offset = buf.len();
            }
        } else {
            start_offset = start_line_start + range.start_col;
            const end_line_len = get_line_len(buf, range.end_line);
            const clamped_end_col = if (end_line_len > 0) @min(range.end_col, end_line_len - 1) else 0;
            end_offset = end_line_start + clamped_end_col + 1;
        }

        if (start_offset > buf.len()) start_offset = buf.len();
        if (end_offset > buf.len()) end_offset = buf.len();
        if (end_offset < start_offset) end_offset = start_offset;

        return .{ .start = start_offset, .end = end_offset, .is_line = range.is_line };
    }

    fn yank_selection(self: *EditorState, buf: *Buffer) !void {
        const offsets = self.get_selection_offsets(buf) orelse return;
        if (offsets.end > offsets.start) {
            const slice = try buf.get_slice(buf.allocator, offsets.start, offsets.end);
            defer buf.allocator.free(slice);
            const copy_len = @min(slice.len, self.register.len);
            @memcpy(self.register[0..copy_len], slice[0..copy_len]);
            self.register_len = copy_len;
            self.register_is_line = offsets.is_line;
            clipboard.set(self.get_register());
        }
        if (self.get_selection_range(buf)) |r| {
            self.cursor.line = r.start_line;
            self.cursor.col = r.start_col;
            self.cursor.desired_col = self.cursor.col;
        }
        self.mode = .normal;
        self.anchor = null;
    }

    fn delete_selection(self: *EditorState, buf: *Buffer) !void {
        const offsets = self.get_selection_offsets(buf) orelse return;
        const sel_range = self.get_selection_range(buf);
        if (offsets.end > offsets.start) {
            const count = offsets.end - offsets.start;
            const slice = try buf.get_slice(buf.allocator, offsets.start, offsets.end);
            defer buf.allocator.free(slice);
            const copy_len = @min(slice.len, self.register.len);
            @memcpy(self.register[0..copy_len], slice[0..copy_len]);
            self.register_len = copy_len;
            self.register_is_line = offsets.is_line;
            clipboard.set(self.get_register());

            try buf.delete(offsets.start, count);
        }
        if (sel_range) |r| {
            self.cursor.line = if (r.start_line < buf.line_count()) r.start_line else (if (buf.line_count() > 0) buf.line_count() - 1 else 0);
            const cur_len = get_line_len(buf, self.cursor.line);
            self.cursor.col = if (cur_len > 0) @min(r.start_col, cur_len - 1) else 0;
            self.cursor.desired_col = self.cursor.col;
        }
        self.mode = .normal;
        self.anchor = null;
    }

    fn set_cursor_from_offset(self: *EditorState, buf: *const Buffer, offset: usize) void {
        const line_count = buf.line_count();
        var i: usize = line_count;
        while (i > 0) {
            i -= 1;
            if (buf.lines.get_line_start(i)) |start| {
                if (start <= offset) {
                    self.cursor.line = i;
                    self.cursor.col = offset - start;
                    self.cursor.desired_col = self.cursor.col;
                    return;
                }
            }
        }
        self.cursor.line = 0;
        self.cursor.col = offset;
        self.cursor.desired_col = self.cursor.col;
    }

    fn move_word_forward(self: *EditorState, buf: *const Buffer) void {
        const total_len = buf.len();
        if (total_len == 0) return;

        const line_start = buf.lines.get_line_start(self.cursor.line) orelse 0;
        var offset = line_start + self.cursor.col;
        if (offset >= total_len) return;

        const start_ch = buf.byte_at(offset) orelse return;
        const initial_kind = char_kind(start_ch);

        if (initial_kind != .space) {
            while (offset < total_len) {
                const ch = buf.byte_at(offset) orelse break;
                if (char_kind(ch) != initial_kind) break;
                offset += 1;
            }
        }

        while (offset < total_len) {
            const ch = buf.byte_at(offset) orelse break;
            if (char_kind(ch) != .space) break;
            offset += 1;
        }

        self.set_cursor_from_offset(buf, offset);
    }

    fn move_word_backward(self: *EditorState, buf: *const Buffer) void {
        const total_len = buf.len();
        if (total_len == 0) return;

        const line_start = buf.lines.get_line_start(self.cursor.line) orelse 0;
        var offset = line_start + self.cursor.col;
        if (offset == 0) return;

        offset -= 1;

        while (offset > 0) {
            const ch = buf.byte_at(offset) orelse break;
            if (char_kind(ch) != .space) break;
            offset -= 1;
        }

        const cur_ch = buf.byte_at(offset) orelse return;
        const kind = char_kind(cur_ch);
        if (kind != .space) {
            while (offset > 0) {
                const prev_ch = buf.byte_at(offset - 1) orelse break;
                if (char_kind(prev_ch) != kind) break;
                offset -= 1;
            }
        }

        self.set_cursor_from_offset(buf, offset);
    }

    pub fn handle_key(self: *EditorState, buf: *Buffer, ev: KeyEvent) !void {
        switch (self.mode) {
            .normal => try self.handle_normal_key(buf, ev),
            .insert => try self.handle_insert_key(buf, ev),
            .visual, .visual_line => try self.handle_visual_key(buf, ev),
            .command_line => self.handle_command_line_key(buf, ev),
        }
    }

    fn handle_visual_key(self: *EditorState, buf: *Buffer, ev: KeyEvent) !void {
        switch (ev.code) {
            .escape => {
                self.mode = .normal;
                self.anchor = null;
            },
            .character => {
                if (ev.char) |ch| switch (ch) {
                    'y' => try self.yank_selection(buf),
                    'd', 'x' => try self.delete_selection(buf),
                    'h', 'l', 'j', 'k', '0', '$', 'w', 'b' => self.handle_motion_key(buf, ch),
                    else => {},
                };
            },
            .left, .right, .down, .up => self.handle_arrow_key(buf, ev.code),
            else => {},
        }
    }

    fn handle_motion_key(self: *EditorState, buf: *const Buffer, char: u8) void {
        switch (char) {
            'h' => {
                if (self.cursor.col > 0) {
                    self.cursor.col -= 1;
                    self.cursor.desired_col = self.cursor.col;
                }
            },
            'l' => {
                const len = get_line_len(buf, self.cursor.line);
                const max_col = if (len > 0) len - 1 else 0;
                if (self.cursor.col < max_col) {
                    self.cursor.col += 1;
                    self.cursor.desired_col = self.cursor.col;
                }
            },
            'j' => {
                if (self.cursor.line + 1 < buf.line_count()) {
                    self.cursor.line += 1;
                    const len = get_line_len(buf, self.cursor.line);
                    const max_col = if (len > 0) len - 1 else 0;
                    self.cursor.col = @min(self.cursor.desired_col, max_col);
                }
            },
            'k' => {
                if (self.cursor.line > 0) {
                    self.cursor.line -= 1;
                    const len = get_line_len(buf, self.cursor.line);
                    const max_col = if (len > 0) len - 1 else 0;
                    self.cursor.col = @min(self.cursor.desired_col, max_col);
                }
            },
            '0' => {
                self.cursor.col = 0;
                self.cursor.desired_col = 0;
            },
            '$' => {
                const len = get_line_len(buf, self.cursor.line);
                const max_col = if (len > 0) len - 1 else 0;
                self.cursor.col = max_col;
                self.cursor.desired_col = max_col;
            },
            'w' => {
                self.move_word_forward(buf);
            },
            'b' => {
                self.move_word_backward(buf);
            },
            else => {},
        }
    }

    fn handle_arrow_key(self: *EditorState, buf: *const Buffer, code: KeyCode) void {
        switch (code) {
            .left => self.handle_motion_key(buf, 'h'),
            .right => self.handle_motion_key(buf, 'l'),
            .down => self.handle_motion_key(buf, 'j'),
            .up => self.handle_motion_key(buf, 'k'),
            else => {},
        }
    }

    fn handle_command_line_key(self: *EditorState, buf: *Buffer, ev: KeyEvent) void {
        switch (ev.code) {
            .escape => {
                if (self.cmd_prefix == '/' or self.cmd_prefix == '?') {
                    self.cursor = self.search_origin;
                    self.hlsearch = false;
                }
                self.mode = .normal;
                self.cmd_len = 0;
                self.cmd_cursor = 0;
            },
            .left => {
                if (self.cmd_cursor > 0) {
                    self.cmd_cursor -= 1;
                }
            },
            .right => {
                if (self.cmd_cursor < self.cmd_len) {
                    self.cmd_cursor += 1;
                }
            },
            .home => {
                self.cmd_cursor = 0;
            },
            .end => {
                self.cmd_cursor = self.cmd_len;
            },
            .delete => {
                if (self.cmd_cursor < self.cmd_len) {
                    var i: usize = self.cmd_cursor;
                    while (i + 1 < self.cmd_len) : (i += 1) {
                        self.cmd_line[i] = self.cmd_line[i + 1];
                    }
                    self.cmd_len -= 1;
                    if (self.cmd_prefix == '/' or self.cmd_prefix == '?') {
                        if (self.cmd_len > 0) {
                            @memcpy(self.search_pattern[0..self.cmd_len], self.cmd_line[0..self.cmd_len]);
                            self.search_len = self.cmd_len;
                            self.hlsearch = true;
                            self.cursor = self.search_origin;
                            _ = self.jump_to_match(buf, self.search_dir, false);
                        } else {
                            self.search_len = 0;
                            self.hlsearch = false;
                            self.cursor = self.search_origin;
                        }
                    }
                }
            },
            .backspace => {
                if (self.cmd_cursor > 0) {
                    var i: usize = self.cmd_cursor - 1;
                    while (i + 1 < self.cmd_len) : (i += 1) {
                        self.cmd_line[i] = self.cmd_line[i + 1];
                    }
                    self.cmd_len -= 1;
                    self.cmd_cursor -= 1;
                    if (self.cmd_prefix == '/' or self.cmd_prefix == '?') {
                        if (self.cmd_len > 0) {
                            @memcpy(self.search_pattern[0..self.cmd_len], self.cmd_line[0..self.cmd_len]);
                            self.search_len = self.cmd_len;
                            self.hlsearch = true;
                            self.cursor = self.search_origin;
                            _ = self.jump_to_match(buf, self.search_dir, false);
                        } else {
                            self.search_len = 0;
                            self.hlsearch = false;
                            self.cursor = self.search_origin;
                        }
                    }
                } else if (self.cmd_len == 0) {
                    if (self.cmd_prefix == '/' or self.cmd_prefix == '?') {
                        self.cursor = self.search_origin;
                        self.hlsearch = false;
                    }
                    self.mode = .normal;
                    self.cmd_cursor = 0;
                }
            },
            .enter => {
                if (self.cmd_prefix == ':') {
                    self.last_cmd[0] = ':';
                    @memcpy(self.last_cmd[1 .. 1 + self.cmd_len], self.cmd_line[0..self.cmd_len]);
                    self.last_cmd_len = 1 + self.cmd_len;
                    self.cmd_len = 0;
                    self.cmd_cursor = 0;
                    self.mode = .normal;
                } else if (self.cmd_prefix == '/' or self.cmd_prefix == '?') {
                    if (self.cmd_len > 0) {
                        @memcpy(self.search_pattern[0..self.cmd_len], self.cmd_line[0..self.cmd_len]);
                        self.search_len = self.cmd_len;
                        self.hlsearch = true;
                    }
                    self.cmd_len = 0;
                    self.cmd_cursor = 0;
                    self.mode = .normal;
                    _ = self.jump_to_match(buf, self.search_dir, false);
                }
            },
            .character => {
                if (ev.char) |ch| {
                    if (ch == 1) { // Ctrl-A
                        self.cmd_cursor = 0;
                    } else if (ch == 5) { // Ctrl-E
                        self.cmd_cursor = self.cmd_len;
                    } else if (ch == 3) { // Ctrl-C
                        if (self.cmd_prefix == '/' or self.cmd_prefix == '?') {
                            self.cursor = self.search_origin;
                            self.hlsearch = false;
                        }
                        self.mode = .normal;
                        self.cmd_len = 0;
                        self.cmd_cursor = 0;
                    } else if (ch >= 32) {
                        if (self.cmd_len < self.cmd_line.len) {
                            var i: usize = self.cmd_len;
                            while (i > self.cmd_cursor) : (i -= 1) {
                                self.cmd_line[i] = self.cmd_line[i - 1];
                            }
                            self.cmd_line[self.cmd_cursor] = ch;
                            self.cmd_len += 1;
                            self.cmd_cursor += 1;
                            if (self.cmd_prefix == '/' or self.cmd_prefix == '?') {
                                @memcpy(self.search_pattern[0..self.cmd_len], self.cmd_line[0..self.cmd_len]);
                                self.search_len = self.cmd_len;
                                self.hlsearch = true;
                                self.cursor = self.search_origin;
                                _ = self.jump_to_match(buf, self.search_dir, false);
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    fn handle_normal_key(self: *EditorState, buf: *Buffer, ev: KeyEvent) !void {
        if (self.pending_cmd) |pending| {
            self.pending_cmd = null;
            if (pending == 'd' and ev.code == .character and ev.char == 'd') {
                try self.delete_current_line(buf);
            }
            return;
        }

        switch (ev.code) {
            .character => {
                if (ev.char) |char| switch (char) {
                    'i' => {
                        buf.begin_undo_group(self.cursor.line, self.cursor.col);
                        self.mode = .insert;
                    },
                    'a' => {
                        const len = get_line_len(buf, self.cursor.line);
                        if (self.cursor.col < len) {
                            self.cursor.col += 1;
                        }
                        self.cursor.desired_col = self.cursor.col;
                        buf.begin_undo_group(self.cursor.line, self.cursor.col);
                        self.mode = .insert;
                    },
                    'o' => {
                        buf.begin_undo_group(self.cursor.line, self.cursor.col);
                        if (self.cursor.line + 1 < buf.line_count()) {
                            const next_start = buf.lines.get_line_start(self.cursor.line + 1).?;
                            const insert_pos = if (next_start > 0) next_start - 1 else 0;
                            try buf.insert(insert_pos, "\n");
                        } else {
                            try buf.insert(buf.len(), "\n");
                        }
                        self.cursor.line += 1;
                        self.cursor.col = 0;
                        self.cursor.desired_col = 0;
                        self.mode = .insert;
                    },
                    'v' => {
                        self.mode = .visual;
                        self.anchor = self.cursor;
                    },
                    'V' => {
                        self.mode = .visual_line;
                        self.anchor = self.cursor;
                    },
                    'p' => {
                        if (clipboard.get()) |clip_text| {
                            if (clip_text.len > 0) {
                                const copy_len = @min(clip_text.len, self.register.len);
                                @memcpy(self.register[0..copy_len], clip_text[0..copy_len]);
                                self.register_len = copy_len;
                                self.register_is_line = (clip_text[clip_text.len - 1] == '\n');
                            }
                        }
                        if (self.register_len > 0) {
                            if (self.register_is_line) {
                                if (self.cursor.line + 1 < buf.line_count()) {
                                    const next_start = buf.lines.get_line_start(self.cursor.line + 1).?;
                                    try buf.insert(next_start, self.get_register());
                                } else {
                                    try buf.insert(buf.len(), "\n");
                                    try buf.insert(buf.len(), self.get_register());
                                }
                                self.cursor.line += 1;
                                self.cursor.col = 0;
                                self.cursor.desired_col = 0;
                            } else {
                                const line_start = buf.lines.get_line_start(self.cursor.line) orelse 0;
                                const line_len = get_line_len(buf, self.cursor.line);
                                const insert_pos = if (line_len > 0) line_start + @min(self.cursor.col + 1, line_len) else line_start;
                                try buf.insert(insert_pos, self.get_register());
                                self.cursor.col = @min(self.cursor.col + self.register_len, get_line_len(buf, self.cursor.line));
                                self.cursor.desired_col = self.cursor.col;
                            }
                        }
                    },
                    'h', 'l', 'j', 'k', '0', '$', 'w', 'b' => self.handle_motion_key(buf, char),
                    'x' => {
                        const cur_len = get_line_len(buf, self.cursor.line);
                        if (cur_len > 0 and self.cursor.col < cur_len) {
                            const line_start = buf.lines.get_line_start(self.cursor.line) orelse 0;
                            try buf.delete(line_start + self.cursor.col, 1);
                            const new_len = cur_len - 1;
                            if (new_len > 0 and self.cursor.col >= new_len) {
                                self.cursor.col = new_len - 1;
                            }
                            self.cursor.desired_col = self.cursor.col;
                        }
                    },
                    'd' => {
                        self.pending_cmd = 'd';
                    },
                    'u' => {
                        if (buf.undo()) |step| {
                            self.cursor.line = step.cursor_line;
                            self.cursor.col = step.cursor_col;
                            self.cursor.desired_col = self.cursor.col;
                        }
                    },
                    18 => { // Ctrl-R
                        if (buf.redo()) |step| {
                            self.cursor.line = step.cursor_line;
                            self.cursor.col = step.cursor_col;
                            self.cursor.desired_col = self.cursor.col;
                        }
                    },
                    ':' => {
                        self.mode = .command_line;
                        self.cmd_prefix = ':';
                        self.cmd_len = 0;
                        self.cmd_cursor = 0;
                    },
                    '/' => {
                        self.mode = .command_line;
                        self.cmd_prefix = '/';
                        self.cmd_len = 0;
                        self.cmd_cursor = 0;
                        self.search_dir = .forward;
                        self.search_origin = self.cursor;
                    },
                    '?' => {
                        self.mode = .command_line;
                        self.cmd_prefix = '?';
                        self.cmd_len = 0;
                        self.cmd_cursor = 0;
                        self.search_dir = .backward;
                        self.search_origin = self.cursor;
                    },
                    'n' => {
                        _ = self.jump_to_match(buf, self.search_dir, true);
                    },
                    'N' => {
                        const rev: search_mod.Direction = if (self.search_dir == .forward) .backward else .forward;
                        _ = self.jump_to_match(buf, rev, true);
                    },
                    '*' => {
                        self.search_word_under_cursor(buf, .forward);
                    },
                    '#' => {
                        self.search_word_under_cursor(buf, .backward);
                    },
                    else => {},
                };
            },
            .escape => {
                self.hlsearch = false;
            },
            .left, .right, .down, .up => self.handle_arrow_key(buf, ev.code),
            else => {},
        }
    }

    fn delete_current_line(self: *EditorState, buf: *Buffer) !void {
        const line = self.cursor.line;
        const start = buf.lines.get_line_start(line) orelse 0;

        if (line + 1 < buf.line_count()) {
            const next_start = buf.lines.get_line_start(line + 1).?;
            const count = next_start - start;
            try buf.delete(start, count);
        } else if (line > 0) {
            const start_del = start - 1;
            const count = buf.len() - start_del;
            try buf.delete(start_del, count);
            self.cursor.line -= 1;
        } else {
            try buf.delete(0, buf.len());
        }

        if (self.cursor.line >= buf.line_count()) {
            self.cursor.line = if (buf.line_count() > 0) buf.line_count() - 1 else 0;
        }

        const len = get_line_len(buf, self.cursor.line);
        const max_col = if (len > 0) len - 1 else 0;
        self.cursor.col = @min(self.cursor.col, max_col);
        self.cursor.desired_col = self.cursor.col;
    }

    fn handle_insert_key(self: *EditorState, buf: *Buffer, ev: KeyEvent) !void {
        switch (ev.code) {
            .escape => {
                buf.end_undo_group();
                self.mode = .normal;
                if (self.cursor.col > 0) {
                    self.cursor.col -= 1;
                }
                self.cursor.desired_col = self.cursor.col;
            },
            .character => {
                if (ev.char) |ch| {
                    const line_start = buf.lines.get_line_start(self.cursor.line) orelse 0;
                    const offset = line_start + self.cursor.col;
                    try buf.insert(offset, &[_]u8{ch});
                    self.cursor.col += 1;
                    self.cursor.desired_col = self.cursor.col;
                }
            },
            .enter => {
                const line_start = buf.lines.get_line_start(self.cursor.line) orelse 0;
                const offset = line_start + self.cursor.col;
                try buf.insert(offset, "\n");
                self.cursor.line += 1;
                self.cursor.col = 0;
                self.cursor.desired_col = 0;
            },
            .backspace => {
                if (self.cursor.col > 0) {
                    const line_start = buf.lines.get_line_start(self.cursor.line) orelse 0;
                    const offset = line_start + self.cursor.col - 1;
                    try buf.delete(offset, 1);
                    self.cursor.col -= 1;
                    self.cursor.desired_col = self.cursor.col;
                } else if (self.cursor.line > 0) {
                    const prev_line = self.cursor.line - 1;
                    const prev_len = get_line_len(buf, prev_line);
                    const line_start = buf.lines.get_line_start(self.cursor.line) orelse 0;
                    if (line_start > 0) {
                        try buf.delete(line_start - 1, 1);
                    }
                    self.cursor.line = prev_line;
                    self.cursor.col = prev_len;
                    self.cursor.desired_col = self.cursor.col;
                }
            },
            .left => {
                if (self.cursor.col > 0) {
                    self.cursor.col -= 1;
                    self.cursor.desired_col = self.cursor.col;
                }
            },
            .right => {
                const len = get_line_len(buf, self.cursor.line);
                if (self.cursor.col < len) {
                    self.cursor.col += 1;
                    self.cursor.desired_col = self.cursor.col;
                }
            },
            .down => {
                if (self.cursor.line + 1 < buf.line_count()) {
                    self.cursor.line += 1;
                    const len = get_line_len(buf, self.cursor.line);
                    const max_col = if (len > 0) len - 1 else 0;
                    self.cursor.col = @min(self.cursor.desired_col, max_col);
                }
            },
            .up => {
                if (self.cursor.line > 0) {
                    self.cursor.line -= 1;
                    const len = get_line_len(buf, self.cursor.line);
                    const max_col = if (len > 0) len - 1 else 0;
                    self.cursor.col = @min(self.cursor.desired_col, max_col);
                }
            },
            else => {},
        }
    }
};

const testing = std.testing;

test "test_mode_initial_state_is_normal" {
    const state = EditorState{};
    try testing.expectEqual(Mode.normal, state.mode);
}

test "test_mode_transition_i_enters_insert" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "hello");

    var state = EditorState{ .cursor = .{ .line = 0, .col = 2 } };
    try state.handle_key(&buf, .{ .code = .character, .char = 'i' });

    try testing.expectEqual(Mode.insert, state.mode);
    try testing.expectEqual(@as(usize, 0), state.cursor.line);
    try testing.expectEqual(@as(usize, 2), state.cursor.col);
}

test "test_mode_transition_a_enters_insert_after_cursor" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "hello");

    var state = EditorState{ .cursor = .{ .line = 0, .col = 0 } };
    try state.handle_key(&buf, .{ .code = .character, .char = 'a' });

    try testing.expectEqual(Mode.insert, state.mode);
    try testing.expectEqual(@as(usize, 1), state.cursor.col);
}

test "test_mode_transition_escape_returns_to_normal" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "hello");

    var state = EditorState{ .mode = .insert, .cursor = .{ .line = 0, .col = 3 } };
    try state.handle_key(&buf, .{ .code = .escape });

    try testing.expectEqual(Mode.normal, state.mode);
    try testing.expectEqual(@as(usize, 2), state.cursor.col);
}

test "test_mode_transition_o_opens_line_below" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "line1\nline2");

    var state = EditorState{ .cursor = .{ .line = 0, .col = 2 } };
    try state.handle_key(&buf, .{ .code = .character, .char = 'o' });

    try testing.expectEqual(Mode.insert, state.mode);
    try testing.expectEqual(@as(usize, 1), state.cursor.line);
    try testing.expectEqual(@as(usize, 0), state.cursor.col);
    try testing.expectEqual(@as(usize, 3), buf.line_count());
}

test "test_vim_hjkl_navigation" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "abc\ndef");

    var state = EditorState{};
    try state.handle_key(&buf, .{ .code = .character, .char = 'l' });
    try testing.expectEqual(@as(usize, 1), state.cursor.col);

    try state.handle_key(&buf, .{ .code = .character, .char = 'j' });
    try testing.expectEqual(@as(usize, 1), state.cursor.line);
    try testing.expectEqual(@as(usize, 1), state.cursor.col);

    try state.handle_key(&buf, .{ .code = .character, .char = 'h' });
    try testing.expectEqual(@as(usize, 0), state.cursor.col);

    try state.handle_key(&buf, .{ .code = .character, .char = 'k' });
    try testing.expectEqual(@as(usize, 0), state.cursor.line);
}

test "test_vim_line_start_and_end" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "hello world");

    var state = EditorState{ .cursor = .{ .line = 0, .col = 5 } };
    try state.handle_key(&buf, .{ .code = .character, .char = '0' });
    try testing.expectEqual(@as(usize, 0), state.cursor.col);

    try state.handle_key(&buf, .{ .code = .character, .char = '$' });
    try testing.expectEqual(@as(usize, 10), state.cursor.col);
}

test "test_vim_word_navigation" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "first second third");

    var state = EditorState{};
    try state.handle_key(&buf, .{ .code = .character, .char = 'w' });
    try testing.expectEqual(@as(usize, 6), state.cursor.col);

    try state.handle_key(&buf, .{ .code = .character, .char = 'w' });
    try testing.expectEqual(@as(usize, 13), state.cursor.col);

    try state.handle_key(&buf, .{ .code = .character, .char = 'b' });
    try testing.expectEqual(@as(usize, 6), state.cursor.col);
}

test "test_vim_x_deletes_character" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "abc");

    var state = EditorState{ .cursor = .{ .line = 0, .col = 1 } };
    try state.handle_key(&buf, .{ .code = .character, .char = 'x' });

    const slice = try buf.get_slice(testing.allocator, 0, buf.len());
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings("ac", slice);
    try testing.expectEqual(@as(usize, 1), state.cursor.col);
}

test "test_vim_dd_deletes_line" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "first\nsecond\nthird");

    var state = EditorState{ .cursor = .{ .line = 1, .col = 0 } };
    try state.handle_key(&buf, .{ .code = .character, .char = 'd' });
    try state.handle_key(&buf, .{ .code = .character, .char = 'd' });

    try testing.expectEqual(@as(usize, 2), buf.line_count());
    const slice = try buf.get_slice(testing.allocator, 0, buf.len());
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings("first\nthird", slice);
    try testing.expectEqual(@as(usize, 1), state.cursor.line);
}

test "test_mode_colon_enters_command_mode" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    var state = EditorState{};
    try state.handle_key(&buf, .{ .code = .character, .char = ':' });

    try testing.expectEqual(Mode.command_line, state.mode);
    try testing.expectEqual(@as(usize, 0), state.cmd_len);
}

test "test_command_mode_typing_and_backspace" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    var state = EditorState{};
    try state.handle_key(&buf, .{ .code = .character, .char = ':' });
    try state.handle_key(&buf, .{ .code = .character, .char = 'w' });
    try state.handle_key(&buf, .{ .code = .character, .char = 'q' });

    try testing.expectEqualStrings("wq", state.get_cmd_line());

    try state.handle_key(&buf, .{ .code = .backspace });
    try testing.expectEqualStrings("w", state.get_cmd_line());

    try state.handle_key(&buf, .{ .code = .backspace });
    try testing.expectEqualStrings("", state.get_cmd_line());
    try testing.expectEqual(Mode.command_line, state.mode);

    // Backspace on empty command line exits to Normal mode
    try state.handle_key(&buf, .{ .code = .backspace });
    try testing.expectEqual(Mode.normal, state.mode);
}

test "test_command_mode_escape_cancels" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    var state = EditorState{};
    try state.handle_key(&buf, .{ .code = .character, .char = ':' });
    try state.handle_key(&buf, .{ .code = .character, .char = 'w' });
    try state.handle_key(&buf, .{ .code = .escape });

    try testing.expectEqual(Mode.normal, state.mode);
    try testing.expectEqual(@as(usize, 0), state.cmd_len);
}

test "test_command_mode_enter_echoes" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    var state = EditorState{};
    try state.handle_key(&buf, .{ .code = .character, .char = ':' });
    try state.handle_key(&buf, .{ .code = .character, .char = 'w' });
    try state.handle_key(&buf, .{ .code = .enter });

    try testing.expectEqual(Mode.normal, state.mode);
    try testing.expectEqualStrings(":w", state.get_last_cmd());
}

test "test_mode_visual_character_transition" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "hello world");

    var state = EditorState{ .cursor = .{ .line = 0, .col = 2 } };
    try state.handle_key(&buf, .{ .code = .character, .char = 'v' });

    try testing.expectEqual(Mode.visual, state.mode);
    try testing.expect(state.anchor != null);
    try testing.expectEqual(@as(usize, 0), state.anchor.?.line);
    try testing.expectEqual(@as(usize, 2), state.anchor.?.col);
}

test "test_mode_visual_line_transition" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "line 1\nline 2");

    var state = EditorState{ .cursor = .{ .line = 0, .col = 1 } };
    try state.handle_key(&buf, .{ .code = .character, .char = 'V' });

    try testing.expectEqual(Mode.visual_line, state.mode);
    try testing.expect(state.anchor != null);
}

test "test_visual_range_normalization" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "hello world");

    var state = EditorState{ .mode = .visual, .anchor = .{ .line = 0, .col = 5 }, .cursor = .{ .line = 0, .col = 2 } };
    const range = state.get_selection_range(&buf).?;

    try testing.expectEqual(@as(usize, 0), range.start_line);
    try testing.expectEqual(@as(usize, 2), range.start_col);
    try testing.expectEqual(@as(usize, 0), range.end_line);
    try testing.expectEqual(@as(usize, 5), range.end_col);
}

test "test_visual_yank_character_wise" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "hello world");

    var state = EditorState{ .cursor = .{ .line = 0, .col = 6 } };
    try state.handle_key(&buf, .{ .code = .character, .char = 'v' });
    try state.handle_key(&buf, .{ .code = .character, .char = '$' });
    try state.handle_key(&buf, .{ .code = .character, .char = 'y' });

    try testing.expectEqual(Mode.normal, state.mode);
    try testing.expectEqualStrings("world", state.get_register());
    const slice = try buf.get_slice(testing.allocator, 0, buf.len());
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings("hello world", slice);
}

test "test_visual_delete_character_wise" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "hello world");

    var state = EditorState{ .cursor = .{ .line = 0, .col = 6 } };
    try state.handle_key(&buf, .{ .code = .character, .char = 'v' });
    try state.handle_key(&buf, .{ .code = .character, .char = '$' });
    try state.handle_key(&buf, .{ .code = .character, .char = 'd' });

    try testing.expectEqual(Mode.normal, state.mode);
    try testing.expectEqualStrings("world", state.get_register());
    const slice = try buf.get_slice(testing.allocator, 0, buf.len());
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings("hello ", slice);
}

test "test_normal_put_after_cursor" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "a");

    var state = EditorState{ .cursor = .{ .line = 0, .col = 0 } };
    @memcpy(state.register[0..2], "bc");
    state.register_len = 2;
    state.register_is_line = false;

    try state.handle_key(&buf, .{ .code = .character, .char = 'p' });

    const slice = try buf.get_slice(testing.allocator, 0, buf.len());
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings("abc", slice);
    try testing.expectEqual(@as(usize, 2), state.cursor.col);
}

test "test_clipboard_sync_on_visual_yank" {
    clipboard.enable_mock(true);
    defer clipboard.enable_mock(false);

    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "sync this to clipboard");

    var state = EditorState{ .cursor = .{ .line = 0, .col = 13 } };
    try state.handle_key(&buf, .{ .code = .character, .char = 'v' });
    try state.handle_key(&buf, .{ .code = .character, .char = '$' });
    try state.handle_key(&buf, .{ .code = .character, .char = 'y' });

    try testing.expectEqualStrings("clipboard", state.get_register());
    const clip = clipboard.get();
    try testing.expect(clip != null);
    try testing.expectEqualStrings("clipboard", clip.?);
}

test "test_clipboard_sync_on_visual_delete" {
    clipboard.enable_mock(true);
    defer clipboard.enable_mock(false);

    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "delete this");

    var state = EditorState{ .cursor = .{ .line = 0, .col = 7 } };
    try state.handle_key(&buf, .{ .code = .character, .char = 'v' });
    try state.handle_key(&buf, .{ .code = .character, .char = '$' });
    try state.handle_key(&buf, .{ .code = .character, .char = 'd' });

    try testing.expectEqualStrings("this", state.get_register());
    const clip = clipboard.get();
    try testing.expect(clip != null);
    try testing.expectEqualStrings("this", clip.?);
}

test "test_clipboard_sync_on_normal_put" {
    clipboard.enable_mock(true);
    defer clipboard.enable_mock(false);
    clipboard.set("from outside");

    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "prefix ");

    var state = EditorState{ .cursor = .{ .line = 0, .col = 6 } };
    try state.handle_key(&buf, .{ .code = .character, .char = 'p' });

    const slice = try buf.get_slice(testing.allocator, 0, buf.len());
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings("prefix from outside", slice);
}

test "test_vim_undo_coalescing_insert_mode" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    var state = EditorState{ .cursor = .{ .line = 0, .col = 0 } };
    try state.handle_key(&buf, .{ .code = .character, .char = 'i' });
    try state.handle_key(&buf, .{ .code = .character, .char = 'h' });
    try state.handle_key(&buf, .{ .code = .character, .char = 'e' });
    try state.handle_key(&buf, .{ .code = .character, .char = 'l' });
    try state.handle_key(&buf, .{ .code = .character, .char = 'l' });
    try state.handle_key(&buf, .{ .code = .character, .char = 'o' });
    try state.handle_key(&buf, .{ .code = .escape });

    const slice = try buf.get_slice(testing.allocator, 0, buf.len());
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings("hello", slice);

    // Press 'u' in normal mode -> entire "hello" is undone at once
    try state.handle_key(&buf, .{ .code = .character, .char = 'u' });
    try testing.expectEqual(@as(usize, 0), buf.len());

    // Press Ctrl-r (char code 18) -> "hello" restored
    try state.handle_key(&buf, .{ .code = .character, .char = 18 });
    const slice2 = try buf.get_slice(testing.allocator, 0, buf.len());
    defer testing.allocator.free(slice2);
    try testing.expectEqualStrings("hello", slice2);
}

test "test_vim_undo_resets_dirty_state" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    buf.mark_clean();

    var state = EditorState{};
    try state.handle_key(&buf, .{ .code = .character, .char = 'i' });
    try state.handle_key(&buf, .{ .code = .character, .char = 'x' });
    try state.handle_key(&buf, .{ .code = .escape });

    try testing.expect(buf.is_dirty == true);

    try state.handle_key(&buf, .{ .code = .character, .char = 'u' });
    try testing.expect(buf.is_dirty == false);
}

test "test_vim_search_prompt_and_n_N_navigation" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "target one target two target three");

    var state = EditorState{};

    // Press '/' to start forward search
    try state.handle_key(&buf, .{ .code = .character, .char = '/' });
    try testing.expectEqual(Mode.command_line, state.mode);
    try testing.expectEqual(@as(u8, '/'), state.cmd_prefix);

    // Type "target"
    for ("target") |ch| {
        try state.handle_key(&buf, .{ .code = .character, .char = ch });
    }
    // Press Enter to execute search
    try state.handle_key(&buf, .{ .code = .enter });

    // Mode is back to normal, pattern is saved, hlsearch is on
    try testing.expectEqual(Mode.normal, state.mode);
    try testing.expectEqualStrings("target", state.get_search_pattern());
    try testing.expect(state.hlsearch == true);

    // Cursor jumped to first match at offset 0
    try testing.expectEqual(@as(usize, 0), state.cursor.col);

    // Press 'n' -> next match at offset 11
    try state.handle_key(&buf, .{ .code = .character, .char = 'n' });
    try testing.expectEqual(@as(usize, 11), state.cursor.col);

    // Press 'n' -> next match at offset 22
    try state.handle_key(&buf, .{ .code = .character, .char = 'n' });
    try testing.expectEqual(@as(usize, 22), state.cursor.col);

    // Press 'N' -> reverse direction back to offset 11
    try state.handle_key(&buf, .{ .code = .character, .char = 'N' });
    try testing.expectEqual(@as(usize, 11), state.cursor.col);
}

test "test_vim_star_hash_word_under_cursor" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "func foo() { return foo; }");

    var state = EditorState{ .cursor = .{ .line = 0, .col = 5 } }; // Cursor is on "foo"
    try state.handle_key(&buf, .{ .code = .character, .char = '*' });

    try testing.expectEqualStrings("foo", state.get_search_pattern());
    try testing.expect(state.hlsearch == true);
    // Jumped forward to second "foo" at col 20
    try testing.expectEqual(@as(usize, 20), state.cursor.col);

    // Press '#' to search backward -> jumps back to first "foo" at col 5
    try state.handle_key(&buf, .{ .code = .character, .char = '#' });
    try testing.expectEqual(@as(usize, 5), state.cursor.col);
}

test "test_vim_escape_clears_hlsearch" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "content");

    var state = EditorState{ .hlsearch = true };
    try state.handle_key(&buf, .{ .code = .escape });
    try testing.expect(state.hlsearch == false);
}

test "test_vim_smartcase_navigation" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "Apple and apple and APPLE");

    var state = EditorState{};

    // Lowercase search /apple matches "Apple" at col 0
    try state.handle_key(&buf, .{ .code = .character, .char = '/' });
    for ("apple") |ch| {
        try state.handle_key(&buf, .{ .code = .character, .char = ch });
    }
    try state.handle_key(&buf, .{ .code = .enter });
    try testing.expectEqual(@as(usize, 0), state.cursor.col);

    // Caps search /APPLE matches strictly "APPLE" at col 20
    try state.handle_key(&buf, .{ .code = .character, .char = '/' });
    for ("APPLE") |ch| {
        try state.handle_key(&buf, .{ .code = .character, .char = ch });
    }
    try state.handle_key(&buf, .{ .code = .enter });
    try testing.expectEqual(@as(usize, 20), state.cursor.col);
}

test "test_vim_incremental_search_live_preview" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "first test final test");

    var state = EditorState{ .cursor = .{ .line = 0, .col = 0 } };

    // Enter search mode '/'
    try state.handle_key(&buf, .{ .code = .character, .char = '/' });
    try testing.expectEqual(@as(usize, 0), state.cursor.col);

    // Type 't': first 't' ahead of col 0 is at offset 4 ("first")
    try state.handle_key(&buf, .{ .code = .character, .char = 't' });
    try testing.expectEqual(@as(usize, 4), state.cursor.col);
    try testing.expect(state.hlsearch == true);
    try testing.expectEqualStrings("t", state.get_search_pattern());

    // Type 'e': "te" matches at col 6 ("test")
    try state.handle_key(&buf, .{ .code = .character, .char = 'e' });
    try testing.expectEqual(@as(usize, 6), state.cursor.col);
    try testing.expectEqualStrings("te", state.get_search_pattern());
}

test "test_vim_incremental_search_escape_cancels" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "start ... middle ... end");

    var state = EditorState{ .cursor = .{ .line = 0, .col = 2 } };

    // Start search and type "end"
    try state.handle_key(&buf, .{ .code = .character, .char = '/' });
    for ("end") |ch| {
        try state.handle_key(&buf, .{ .code = .character, .char = ch });
    }
    // Cursor jumped to "end"
    try testing.expect(state.cursor.col > 2);

    // Press Escape to cancel: cursor must restore to starting position (col 2)
    try state.handle_key(&buf, .{ .code = .escape });
    try testing.expectEqual(Mode.normal, state.mode);
    try testing.expectEqual(@as(usize, 2), state.cursor.col);
    try testing.expect(state.hlsearch == false);
}

test "test_vim_command_line_cursor_navigation_and_editing" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    var state = EditorState{};
    // Enter command-line mode with ':'
    try state.handle_key(&buf, .{ .code = .character, .char = ':' });
    try testing.expectEqual(@as(usize, 0), state.cmd_cursor);
    try testing.expectEqual(@as(usize, 0), state.cmd_len);

    // Type "wh"
    try state.handle_key(&buf, .{ .code = .character, .char = 'w' });
    try state.handle_key(&buf, .{ .code = .character, .char = 'h' });
    try testing.expectEqual(@as(usize, 2), state.cmd_cursor);
    try testing.expectEqualStrings("wh", state.get_cmd_line());

    // Left arrow moves cursor between 'w' and 'h'
    try state.handle_key(&buf, .{ .code = .left });
    try testing.expectEqual(@as(usize, 1), state.cmd_cursor);

    // Type 'a' in the middle -> "wah"
    try state.handle_key(&buf, .{ .code = .character, .char = 'a' });
    try testing.expectEqual(@as(usize, 2), state.cmd_cursor);
    try testing.expectEqualStrings("wah", state.get_cmd_line());

    // Backspace deletes 'a' -> "wh"
    try state.handle_key(&buf, .{ .code = .backspace });
    try testing.expectEqual(@as(usize, 1), state.cmd_cursor);
    try testing.expectEqualStrings("wh", state.get_cmd_line());

    // Home moves to start
    try state.handle_key(&buf, .{ .code = .home });
    try testing.expectEqual(@as(usize, 0), state.cmd_cursor);

    // Delete at start deletes 'w' -> "h"
    try state.handle_key(&buf, .{ .code = .delete });
    try testing.expectEqual(@as(usize, 0), state.cmd_cursor);
    try testing.expectEqualStrings("h", state.get_cmd_line());

    // End moves to end
    try state.handle_key(&buf, .{ .code = .end });
    try testing.expectEqual(@as(usize, 1), state.cmd_cursor);
}
