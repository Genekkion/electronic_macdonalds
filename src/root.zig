const std = @import("std");

pub const buffer = @import("buffer/buffer.zig");
pub const Marker = buffer.Marker;
pub const Buffer = buffer.Buffer;
pub const LineIndex = buffer.LineIndex;
pub const BufferRegistry = @import("buffer/registry.zig").BufferRegistry;

pub const lua = @import("lua/buffer_binding.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("buffer/buffer.zig");
    _ = @import("lua/buffer_binding.zig");
}
