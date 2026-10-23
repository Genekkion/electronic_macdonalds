const std = @import("std");

pub const Mode = enum {
    normal,
    insert,
    visual,
    command_line,

    pub fn cursor_width(self: Mode, char_width: f32) f32 {
        return switch (self) {
            .normal, .visual => char_width,
            .insert, .command_line => 2.0,
        };
    }

    pub fn label(self: Mode) [:0]const u8 {
        return switch (self) {
            .normal => "-- NORMAL --",
            .insert => "-- INSERT --",
            .visual => "-- VISUAL --",
            .command_line => "-- COMMAND --",
        };
    }
};

const testing = std.testing;

test "test_cursor_visual_style_by_mode" {
    const normal_w = Mode.normal.cursor_width(8.0);
    try testing.expectEqual(@as(f32, 8.0), normal_w);

    const insert_w = Mode.insert.cursor_width(8.0);
    try testing.expectEqual(@as(f32, 2.0), insert_w);
}
