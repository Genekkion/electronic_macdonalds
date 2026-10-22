const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;

pub const BufferRegistry = struct {
    allocator: Allocator,
    buffers: std.AutoHashMap(u64, *Buffer),
    next_id: u64,

    pub fn init(allocator: Allocator) BufferRegistry {
        return .{
            .allocator = allocator,
            .buffers = std.AutoHashMap(u64, *Buffer).init(allocator),
            .next_id = 1,
        };
    }

    pub fn deinit(self: *BufferRegistry) void {
        var it = self.buffers.valueIterator();
        while (it.next()) |buf_ptr| {
            buf_ptr.*.deinit();
            self.allocator.destroy(buf_ptr.*);
        }
        self.buffers.deinit();
    }

    pub fn create_buffer(self: *BufferRegistry) !u64 {
        const buf = try self.allocator.create(Buffer);
        errdefer self.allocator.destroy(buf);
        buf.* = Buffer.init(self.allocator);

        const id = self.next_id;
        self.next_id += 1;
        try self.buffers.put(id, buf);
        return id;
    }

    pub fn get(self: *BufferRegistry, id: u64) ?*Buffer {
        return self.buffers.get(id);
    }

    pub fn close_buffer(self: *BufferRegistry, id: u64) bool {
        if (self.buffers.fetchRemove(id)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);
            return true;
        }
        return false;
    }
};
