const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LineIndex = struct {
    allocator: Allocator,
    line_starts: std.ArrayList(usize),

    pub fn init(allocator: Allocator) LineIndex {
        var self = LineIndex{
            .allocator = allocator,
            .line_starts = .empty,
        };
        self.line_starts.append(allocator, 0) catch {};
        return self;
    }

    pub fn deinit(self: *LineIndex) void {
        self.line_starts.deinit(self.allocator);
    }

    pub fn count(self: *const LineIndex) usize {
        return self.line_starts.items.len;
    }

    pub fn get_line_start(self: *const LineIndex, line_idx: usize) ?usize {
        if (line_idx >= self.line_starts.items.len) return null;
        return self.line_starts.items[line_idx];
    }

    pub fn get_line_end(self: *const LineIndex, line_idx: usize, total_len: usize) ?usize {
        if (line_idx >= self.line_starts.items.len) return null;
        if (line_idx + 1 < self.line_starts.items.len) {
            const next_start = self.line_starts.items[line_idx + 1];
            return if (next_start > 0) next_start - 1 else 0;
        }
        return total_len;
    }

    pub fn get_line_at_offset(self: *const LineIndex, offset: usize) ?usize {
        const items = self.line_starts.items;
        if (items.len == 0) return null;
        if (offset < items[0]) return 0;
        if (offset >= items[items.len - 1]) return items.len - 1;

        var low: usize = 0;
        var high: usize = items.len - 1;
        while (low <= high) {
            const mid = low + (high - low) / 2;
            if (items[mid] <= offset) {
                if (mid + 1 == items.len or items[mid + 1] > offset) {
                    return mid;
                }
                low = mid + 1;
            } else {
                if (mid == 0) return 0;
                high = mid - 1;
            }
        }
        return low;
    }

    pub fn on_insert(self: *LineIndex, offset: usize, bytes: []const u8) !void {
        if (bytes.len == 0) return;

        // Collect newly added newlines
        var new_offsets: std.ArrayList(usize) = .empty;
        defer new_offsets.deinit(self.allocator);

        for (bytes, 0..) |b, i| {
            if (b == '\n') {
                try new_offsets.append(self.allocator, offset + i + 1);
            }
        }

        // Shift existing line starts after offset
        for (self.line_starts.items) |*start| {
            if (start.* > offset) {
                start.* += bytes.len;
            }
        }

        // Insert new line starts in sorted order
        if (new_offsets.items.len > 0) {
            var insert_pos: usize = 0;
            while (insert_pos < self.line_starts.items.len and self.line_starts.items[insert_pos] <= offset) {
                insert_pos += 1;
            }

            for (new_offsets.items, 0..) |new_start, i| {
                try self.line_starts.insert(self.allocator, insert_pos + i, new_start);
            }
        }
    }

    pub fn on_delete(self: *LineIndex, offset: usize, count_to_delete: usize) !void {
        if (count_to_delete == 0) return;
        const delete_end = offset + count_to_delete;

        var i: usize = 0;
        while (i < self.line_starts.items.len) {
            const start = self.line_starts.items[i];
            if (start > offset and start <= delete_end) {
                _ = self.line_starts.orderedRemove(i);
            } else {
                if (start > delete_end) {
                    self.line_starts.items[i] -= count_to_delete;
                }
                i += 1;
            }
        }
    }
};
