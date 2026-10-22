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
