const std = @import("std");
const Buffer = @import("../buffer/buffer.zig").Buffer;
const Cursor = @import("cursor.zig").Cursor;
const Mode = @import("mode.zig").Mode;
const KeyEvent = @import("event.zig").KeyEvent;

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

pub const EditorState = struct {
    mode: Mode = .normal,
    cursor: Cursor = .{},
    pending_cmd: ?u8 = null,
    cmd_line: [256]u8 = [_]u8{0} ** 256,
    cmd_len: usize = 0,
    last_cmd: [256]u8 = [_]u8{0} ** 256,
    last_cmd_len: usize = 0,

    pub fn get_cmd_line(self: *const EditorState) []const u8 {
        return self.cmd_line[0..self.cmd_len];
    }

    pub fn get_last_cmd(self: *const EditorState) []const u8 {
        return self.last_cmd[0..self.last_cmd_len];
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
            .visual => {
                if (ev.code == .escape) {
                    self.mode = .normal;
                }
            },
            .command_line => self.handle_command_line_key(ev),
        }
    }

    fn handle_command_line_key(self: *EditorState, ev: KeyEvent) void {
        switch (ev.code) {
            .escape => {
                self.mode = .normal;
                self.cmd_len = 0;
            },
            .backspace => {
                if (self.cmd_len > 0) {
                    self.cmd_len -= 1;
                } else {
                    self.mode = .normal;
                }
            },
            .enter => {
                self.last_cmd[0] = ':';
                @memcpy(self.last_cmd[1 .. 1 + self.cmd_len], self.cmd_line[0..self.cmd_len]);
                self.last_cmd_len = 1 + self.cmd_len;
                self.cmd_len = 0;
                self.mode = .normal;
            },
            .character => {
                if (ev.char) |ch| {
                    if (self.cmd_len < self.cmd_line.len) {
                        self.cmd_line[self.cmd_len] = ch;
                        self.cmd_len += 1;
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
                        self.mode = .insert;
                    },
                    'a' => {
                        const len = get_line_len(buf, self.cursor.line);
                        if (self.cursor.col < len) {
                            self.cursor.col += 1;
                        }
                        self.cursor.desired_col = self.cursor.col;
                        self.mode = .insert;
                    },
                    'o' => {
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
                    ':' => {
                        self.mode = .command_line;
                        self.cmd_len = 0;
                    },
                    else => {},
                };
            },
            .left => {
                if (self.cursor.col > 0) {
                    self.cursor.col -= 1;
                    self.cursor.desired_col = self.cursor.col;
                }
            },
            .right => {
                const len = get_line_len(buf, self.cursor.line);
                const max_col = if (len > 0) len - 1 else 0;
                if (self.cursor.col < max_col) {
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
