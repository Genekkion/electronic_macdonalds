const std = @import("std");

pub const FontMetrics = struct {
    char_width: f32,
    line_height: f32,
    ascent: f32,
};

pub const PixelRect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const Viewport = struct {
    pixel_width: f32,
    pixel_height: f32,
    metrics: FontMetrics,
    scroll_top_line: usize = 0,

    pub fn cols(self: *const Viewport) usize {
        if (self.metrics.char_width <= 0.0 or self.pixel_width <= 0.0) return 0;
        return @intFromFloat(@floor(self.pixel_width / self.metrics.char_width));
    }

    pub fn rows(self: *const Viewport) usize {
        if (self.metrics.line_height <= 0.0 or self.pixel_height <= 0.0) return 0;
        return @intFromFloat(@floor(self.pixel_height / self.metrics.line_height));
    }

    pub fn cursor_rect(self: *const Viewport, line: usize, col: usize) ?PixelRect {
        if (line < self.scroll_top_line) return null;
        const visible_row = line - self.scroll_top_line;
        if (visible_row >= self.rows()) return null;

        return .{
            .x = @as(f32, @floatFromInt(col)) * self.metrics.char_width,
            .y = @as(f32, @floatFromInt(visible_row)) * self.metrics.line_height,
            .width = self.metrics.char_width,
            .height = self.metrics.line_height,
        };
    }

    pub fn clamp_scroll(self: *Viewport, total_lines: usize) void {
        const visible_rows = self.rows();
        const max_scroll = if (total_lines > visible_rows) total_lines - visible_rows else 0;
        if (self.scroll_top_line > max_scroll) {
            self.scroll_top_line = max_scroll;
        }
    }

    pub fn update_scroll_with_padding(
        self: *Viewport,
        cursor_line: usize,
        total_lines: usize,
        scrolloff: usize,
    ) void {
        const visible_rows = self.rows();
        if (visible_rows == 0 or total_lines == 0) {
            self.scroll_top_line = 0;
            return;
        }

        const eff_scrolloff = if (visible_rows <= 1) 0 else @min(scrolloff, (visible_rows - 1) / 2);

        // If cursor is above the viewport + padding, scroll up
        if (cursor_line < self.scroll_top_line + eff_scrolloff) {
            self.scroll_top_line = if (cursor_line >= eff_scrolloff) cursor_line - eff_scrolloff else 0;
        }

        // If cursor is below the viewport - padding, scroll down
        if (visible_rows > eff_scrolloff) {
            const bottom_bound = self.scroll_top_line + visible_rows - 1 - eff_scrolloff;
            if (cursor_line > bottom_bound) {
                const target_top = cursor_line + 1 + eff_scrolloff;
                self.scroll_top_line = if (target_top >= visible_rows) target_top - visible_rows else 0;
            }
        }

        self.clamp_scroll(total_lines);
    }
};

const testing = std.testing;

test "test_viewport_dimensions_from_pixel_size" {
    const vp = Viewport{
        .pixel_width = 800.0,
        .pixel_height = 600.0,
        .metrics = .{
            .char_width = 8.0,
            .line_height = 16.0,
            .ascent = 12.0,
        },
    };

    try testing.expectEqual(@as(usize, 100), vp.cols());
    try testing.expectEqual(@as(usize, 37), vp.rows());
}

test "test_viewport_zero_or_negative_size" {
    const vp = Viewport{
        .pixel_width = 0.0,
        .pixel_height = 0.0,
        .metrics = .{
            .char_width = 8.0,
            .line_height = 16.0,
            .ascent = 12.0,
        },
    };

    try testing.expectEqual(@as(usize, 0), vp.cols());
    try testing.expectEqual(@as(usize, 0), vp.rows());
}

test "test_cursor_to_pixel_rect" {
    const vp = Viewport{
        .pixel_width = 800.0,
        .pixel_height = 600.0,
        .metrics = .{
            .char_width = 8.0,
            .line_height = 16.0,
            .ascent = 12.0,
        },
    };

    const rect = vp.cursor_rect(2, 5).?;
    try testing.expectEqual(@as(f32, 40.0), rect.x);
    try testing.expectEqual(@as(f32, 32.0), rect.y);
    try testing.expectEqual(@as(f32, 8.0), rect.width);
    try testing.expectEqual(@as(f32, 16.0), rect.height);
}

test "test_cursor_with_scroll_offset" {
    var vp = Viewport{
        .pixel_width = 800.0,
        .pixel_height = 600.0,
        .metrics = .{
            .char_width = 8.0,
            .line_height = 16.0,
            .ascent = 12.0,
        },
        .scroll_top_line = 10,
    };

    const rect = vp.cursor_rect(15, 0).?;
    try testing.expectEqual(@as(f32, 80.0), rect.y);
}

test "test_scroll_clamp_within_buffer_bounds" {
    var vp = Viewport{
        .pixel_width = 800.0,
        .pixel_height = 160.0,
        .metrics = .{
            .char_width = 8.0,
            .line_height = 16.0,
            .ascent = 12.0,
        },
        .scroll_top_line = 25,
    };

    vp.clamp_scroll(20);
    try testing.expectEqual(@as(usize, 10), vp.scroll_top_line);
}

test "test_scroll_with_padding_downwards" {
    // 10 visible rows, 100 total lines, scrolloff = 3
    var vp = Viewport{
        .pixel_width = 800.0,
        .pixel_height = 160.0, // 160 / 16 = 10 rows
        .metrics = .{ .char_width = 8.0, .line_height = 16.0, .ascent = 12.0 },
        .scroll_top_line = 0,
    };

    // Cursor at line 6: within threshold (10 - 1 - 3 = 6), no scroll needed
    vp.update_scroll_with_padding(6, 100, 3);
    try testing.expectEqual(@as(usize, 0), vp.scroll_top_line);

    // Cursor at line 7: exceeds bottom threshold -> scrolls down by 1 to maintain 3 rows padding below
    vp.update_scroll_with_padding(7, 100, 3);
    try testing.expectEqual(@as(usize, 1), vp.scroll_top_line);

    // Cursor jumps to line 50: scrolls down so line 50 has 3 rows padding below (50 + 1 + 3 - 10 = 44)
    vp.update_scroll_with_padding(50, 100, 3);
    try testing.expectEqual(@as(usize, 44), vp.scroll_top_line);
}

test "test_scroll_with_padding_upwards" {
    var vp = Viewport{
        .pixel_width = 800.0,
        .pixel_height = 160.0, // 10 rows
        .metrics = .{ .char_width = 8.0, .line_height = 16.0, .ascent = 12.0 },
        .scroll_top_line = 40,
    };

    // Cursor at line 45: above top threshold (40 + 3 = 43) -> no scroll
    vp.update_scroll_with_padding(45, 100, 3);
    try testing.expectEqual(@as(usize, 40), vp.scroll_top_line);

    // Cursor moves to line 42: violates top padding -> scrolls up to 42 - 3 = 39
    vp.update_scroll_with_padding(42, 100, 3);
    try testing.expectEqual(@as(usize, 39), vp.scroll_top_line);
}

test "test_scroll_small_window_scrolloff_clamp" {
    // 5 visible rows, scrolloff = 4 -> effective scrolloff clamps to (5 - 1) / 2 = 2
    var vp = Viewport{
        .pixel_width = 800.0,
        .pixel_height = 80.0, // 80 / 16 = 5 rows
        .metrics = .{ .char_width = 8.0, .line_height = 16.0, .ascent = 12.0 },
        .scroll_top_line = 0,
    };

    // Cursor at line 3: threshold with eff=2 is 5 - 1 - 2 = 2 -> scrolls to 3 + 1 + 2 - 5 = 1
    vp.update_scroll_with_padding(3, 50, 4);
    try testing.expectEqual(@as(usize, 1), vp.scroll_top_line);
}

test "test_scroll_single_row_window" {
    // 1 visible row -> effective scrolloff drops to 0
    var vp = Viewport{
        .pixel_width = 800.0,
        .pixel_height = 16.0, // 16 / 16 = 1 row
        .metrics = .{ .char_width = 8.0, .line_height = 16.0, .ascent = 12.0 },
        .scroll_top_line = 0,
    };

    vp.update_scroll_with_padding(12, 50, 4);
    try testing.expectEqual(@as(usize, 12), vp.scroll_top_line);
}

test "test_scroll_collapsed_zero_rows" {
    var vp = Viewport{
        .pixel_width = 800.0,
        .pixel_height = 0.0,
        .metrics = .{ .char_width = 8.0, .line_height = 16.0, .ascent = 12.0 },
        .scroll_top_line = 0,
    };

    vp.update_scroll_with_padding(10, 50, 4);
    try testing.expectEqual(@as(usize, 0), vp.scroll_top_line);
}
