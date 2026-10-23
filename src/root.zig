const std = @import("std");

pub const c = @import("lua/c.zig").c;
pub const buffer = @import("buffer/buffer.zig");
pub const Marker = buffer.Marker;
pub const Buffer = buffer.Buffer;
pub const LineIndex = buffer.LineIndex;
pub const BufferRegistry = @import("buffer/registry.zig").BufferRegistry;
pub const undo = @import("buffer/undo.zig");
pub const undo_persist = @import("buffer/undo_persist.zig");

pub const lua = @import("lua/buffer_binding.zig");
pub const viewport = @import("render/viewport.zig");
pub const font = @import("render/font.zig");
pub const status_line = @import("render/status_line.zig");

pub const event = @import("input/event.zig");
pub const keymap = @import("input/keymap.zig");
pub const cursor = @import("input/cursor.zig");
pub const mode = @import("input/mode.zig");
pub const vim = @import("input/vim.zig");
pub const clipboard = @import("platform/clipboard.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("buffer/buffer.zig");
    _ = @import("lua/buffer_binding.zig");
    _ = @import("render/viewport.zig");
    _ = @import("render/font.zig");
    _ = @import("render/status_line.zig");
    _ = @import("input/keymap.zig");
    _ = @import("input/cursor.zig");
    _ = @import("input/mode.zig");
    _ = @import("input/vim.zig");
    _ = @import("platform/clipboard.zig");
    _ = @import("buffer/undo.zig");
    _ = @import("buffer/undo_persist.zig");
}
