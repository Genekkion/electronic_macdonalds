const std = @import("std");

pub const SetFn = *const fn (text: []const u8) void;
pub const GetFn = *const fn () ?[]const u8;

var global_set_fn: ?SetFn = null;
var global_get_fn: ?GetFn = null;

// Mock storage for testing without macOS pasteboard server
var mock_buffer: [4096]u8 = undefined;
var mock_len: usize = 0;
var mock_active: bool = false;

pub fn set_handlers(set_fn: ?SetFn, get_fn: ?GetFn) void {
    global_set_fn = set_fn;
    global_get_fn = get_fn;
}

pub fn set(text: []const u8) void {
    if (mock_active) {
        const copy_len = @min(text.len, mock_buffer.len);
        @memcpy(mock_buffer[0..copy_len], text[0..copy_len]);
        mock_len = copy_len;
        return;
    }
    if (global_set_fn) |f| {
        f(text);
    }
}

pub fn get() ?[]const u8 {
    if (mock_active) {
        if (mock_len > 0) return mock_buffer[0..mock_len];
        return null;
    }
    if (global_get_fn) |f| {
        return f();
    }
    return null;
}

pub fn enable_mock(enable: bool) void {
    mock_active = enable;
    mock_len = 0;
}
