const std = @import("std");
const Buffer = @import("../buffer/buffer.zig").Buffer;

pub const Cursor = struct {
    line: usize = 0,
    col: usize = 0,
    desired_col: usize = 0,

    fn get_line_len(buf: *const Buffer, line_idx: usize) usize {
        const start = buf.lines.get_line_start(line_idx) orelse return 0;
        const end = buf.lines.get_line_end(line_idx, buf.len()) orelse return 0;
        return if (end >= start) end - start else 0;
    }

    pub fn move_forward(self: *Cursor, buf: *const Buffer) void {
        const cur_len = get_line_len(buf, self.line);
        if (self.col < cur_len) {
            self.col += 1;
        } else if (self.line + 1 < buf.line_count()) {
            self.line += 1;
            self.col = 0;
        }
        self.desired_col = self.col;
    }

    pub fn move_backward(self: *Cursor, buf: *const Buffer) void {
        if (self.col > 0) {
            self.col -= 1;
        } else if (self.line > 0) {
            self.line -= 1;
            self.col = get_line_len(buf, self.line);
        }
        self.desired_col = self.col;
    }

    pub fn move_down(self: *Cursor, buf: *const Buffer) void {
        if (self.line + 1 < buf.line_count()) {
            self.line += 1;
            const next_len = get_line_len(buf, self.line);
            self.col = @min(self.desired_col, next_len);
        }
    }

    pub fn move_up(self: *Cursor, buf: *const Buffer) void {
        if (self.line > 0) {
            self.line -= 1;
            const prev_len = get_line_len(buf, self.line);
            self.col = @min(self.desired_col, prev_len);
        }
    }

    pub fn to_offset(self: *const Cursor, buf: *const Buffer) ?usize {
        const line_start = buf.lines.get_line_start(self.line) orelse return null;
        const line_len = get_line_len(buf, self.line);
        const col = @min(self.col, line_len);
        return line_start + col;
    }

    pub fn from_offset(self: *Cursor, buf: *const Buffer, offset: usize) bool {
        if (offset > buf.len()) return false;
        const line = buf.lines.get_line_at_offset(offset) orelse 0;
        const line_start = buf.lines.get_line_start(line) orelse 0;
        self.line = line;
        self.col = if (offset >= line_start) offset - line_start else 0;
        self.desired_col = self.col;
        return true;
    }
};

const testing = std.testing;

test "test_cursor_move_forward_char" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "ab\ncd");

    var cursor = Cursor{};
    cursor.move_forward(&buf);
    cursor.move_forward(&buf);
    try testing.expectEqual(@as(usize, 0), cursor.line);
    try testing.expectEqual(@as(usize, 2), cursor.col);

    cursor.move_forward(&buf); // wraps to next line
    try testing.expectEqual(@as(usize, 1), cursor.line);
    try testing.expectEqual(@as(usize, 0), cursor.col);
}

test "test_cursor_move_backward_char" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "ab\ncd");

    var cursor = Cursor{ .line = 1, .col = 0 };
    cursor.move_backward(&buf);
    try testing.expectEqual(@as(usize, 0), cursor.line);
    try testing.expectEqual(@as(usize, 2), cursor.col);

    cursor.move_backward(&buf);
    cursor.move_backward(&buf);
    cursor.move_backward(&buf); // clamped at start of buffer
    try testing.expectEqual(@as(usize, 0), cursor.line);
    try testing.expectEqual(@as(usize, 0), cursor.col);
}

test "test_cursor_move_up_down" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "long line\nshort\nlong line again");

    var cursor = Cursor{ .line = 0, .col = 8, .desired_col = 8 };
    cursor.move_down(&buf);
    try testing.expectEqual(@as(usize, 1), cursor.line);
    try testing.expectEqual(@as(usize, 5), cursor.col); // clamped to "short"

    cursor.move_down(&buf);
    try testing.expectEqual(@as(usize, 2), cursor.line);
    try testing.expectEqual(@as(usize, 8), cursor.col); // restored desired_col
}

test "test_cursor_offset_conversion" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "line 0\nline 1\nline 2");

    var cursor = Cursor{ .line = 1, .col = 2 };
    const off = cursor.to_offset(&buf);
    try testing.expect(off != null);
    try testing.expectEqual(@as(usize, 9), off.?); // "line 0\n" is 7 bytes, 7 + 2 = 9

    var cursor2 = Cursor{};
    _ = cursor2.from_offset(&buf, 9);
    try testing.expectEqual(@as(usize, 1), cursor2.line);
    try testing.expectEqual(@as(usize, 2), cursor2.col);
}
