const std = @import("std");
const FontMetrics = @import("viewport.zig").FontMetrics;

const c = @cImport({
    @cInclude("macos_font.h");
});

pub fn load_system_monospace_font(font_name: [:0]const u8, point_size: f64) ?FontMetrics {
    var raw_metrics: c.MacFontMetrics = undefined;
    if (c.macos_font_load_monospace(font_name.ptr, point_size, &raw_metrics)) {
        return .{
            .char_width = raw_metrics.char_width,
            .line_height = raw_metrics.line_height,
            .ascent = raw_metrics.ascent,
        };
    }
    return null;
}

const testing = std.testing;

test "test_coretext_monospace_metrics" {
    const metrics = load_system_monospace_font("Menlo", 14.0).?;
    try testing.expect(metrics.char_width > 0.0);
    try testing.expect(metrics.line_height >= 14.0);
    try testing.expect(metrics.ascent > 0.0);
}
