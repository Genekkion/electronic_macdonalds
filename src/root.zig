const std = @import("std");

pub const buffer = @import("buffer/buffer.zig");
pub const Marker = buffer.Marker;
pub const Buffer = buffer.Buffer;
pub const LineIndex = buffer.LineIndex;

test {
    std.testing.refAllDecls(@This());
    _ = @import("buffer/buffer.zig");
}
