const std = @import("std");
const Allocator = std.mem.Allocator;
const Mode = @import("../input/mode.zig").Mode;

pub fn format_status_line(
    allocator: Allocator,
    mode: Mode,
    filename: []const u8,
    line: usize,
    col: usize,
    total_lines: usize,
) ![:0]u8 {
    _ = total_lines;
    const formatted = try std.fmt.allocPrint(
        allocator,
        "{s}   {s}   {d}:{d}",
        .{ mode.label(), filename, line + 1, col + 1 },
    );
    defer allocator.free(formatted);
    return try allocator.dupeZ(u8, formatted);
}

pub fn format_command_line(allocator: Allocator, prefix: u8, cmd: []const u8) ![:0]u8 {
    const formatted = try std.fmt.allocPrint(allocator, "{c}{s}", .{ prefix, cmd });
    defer allocator.free(formatted);
    return try allocator.dupeZ(u8, formatted);
}

const testing = std.testing;

test "test_status_line_command_mode" {
    const text = try format_command_line(testing.allocator, ':', "w");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(":w", text);
}

test "test_status_line_formatting_normal_mode" {
    const text = try format_status_line(testing.allocator, .normal, "main.zig", 0, 0, 10);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "-- NORMAL --") != null);
    try testing.expect(std.mem.indexOf(u8, text, "main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1:1") != null);
}

test "test_status_line_formatting_insert_mode" {
    const text = try format_status_line(testing.allocator, .insert, "test.txt", 4, 12, 20);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "-- INSERT --") != null);
    try testing.expect(std.mem.indexOf(u8, text, "5:13") != null);
}
