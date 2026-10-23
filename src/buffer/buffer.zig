const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Marker = @import("marker.zig").Marker;
pub const LineIndex = @import("line_index.zig").LineIndex;

pub const Buffer = struct {
    allocator: Allocator,
    data: []u8,
    gap_start: usize,
    gap_end: usize,
    markers: std.ArrayList(*Marker),
    lines: LineIndex,
    is_dirty: bool = false,
    file_path: ?[:0]const u8 = null,
    name: ?[]const u8 = null,

    const default_capacity: usize = 64;

    pub const Error = error{
        OutOfBounds,
        OutOfMemory,
    };

    pub const FileError = error{
        FileOpenFailed,
        FileNotFound,
        WriteFailed,
        ReadFailed,
        OutOfMemory,
        OutOfBounds,
    };

    pub fn init(allocator: Allocator) Buffer {
        const data = allocator.alloc(u8, default_capacity) catch blk: {
            var empty: [0]u8 = undefined;
            break :blk &empty;
        };
        return .{
            .allocator = allocator,
            .data = data,
            .gap_start = 0,
            .gap_end = data.len,
            .markers = .empty,
            .lines = LineIndex.init(allocator),
            .is_dirty = false,
        };
    }

    pub fn deinit(self: *Buffer) void {
        if (self.data.len > 0) {
            self.allocator.free(self.data);
        }
        if (self.file_path) |p| {
            self.allocator.free(p);
        }
        if (self.name) |n| {
            self.allocator.free(n);
        }
        self.markers.deinit(self.allocator);
        self.lines.deinit();
    }

    pub fn len(self: *const Buffer) usize {
        return self.data.len - (self.gap_end - self.gap_start);
    }

    pub fn line_count(self: *const Buffer) usize {
        return self.lines.count();
    }

    fn move_gap(self: *Buffer, target: usize) void {
        if (target == self.gap_start) return;

        if (target < self.gap_start) {
            const shift_len = self.gap_start - target;
            const new_gap_end = self.gap_end - shift_len;
            std.mem.copyBackwards(
                u8,
                self.data[new_gap_end..self.gap_end],
                self.data[target..self.gap_start],
            );
            self.gap_start = target;
            self.gap_end = new_gap_end;
        } else {
            const shift_len = target - self.gap_start;
            std.mem.copyForwards(
                u8,
                self.data[self.gap_start..self.gap_start + shift_len],
                self.data[self.gap_end..self.gap_end + shift_len],
            );
            self.gap_start = target;
            self.gap_end += shift_len;
        }
    }

    fn ensure_gap_capacity(self: *Buffer, needed: usize) Error!void {
        const current_gap = self.gap_end - self.gap_start;
        if (current_gap >= needed) return;

        const post_gap_len = self.data.len - self.gap_end;
        const min_needed = self.data.len + (needed - current_gap);
        var new_cap = if (self.data.len == 0) default_capacity else self.data.len * 2;
        while (new_cap < min_needed) {
            new_cap *= 2;
        }

        const new_data = try self.allocator.alloc(u8, new_cap);
        if (self.gap_start > 0) {
            @memcpy(new_data[0..self.gap_start], self.data[0..self.gap_start]);
        }
        const new_gap_end = new_cap - post_gap_len;
        if (post_gap_len > 0) {
            @memcpy(new_data[new_gap_end..], self.data[self.gap_end..]);
        }

        if (self.data.len > 0) {
            self.allocator.free(self.data);
        }
        self.data = new_data;
        self.gap_end = new_gap_end;
    }

    pub fn insert(self: *Buffer, offset: usize, bytes: []const u8) Error!void {
        if (offset > self.len()) return error.OutOfBounds;
        if (bytes.len == 0) return;

        self.move_gap(offset);
        try self.ensure_gap_capacity(bytes.len);

        @memcpy(self.data[self.gap_start..self.gap_start + bytes.len], bytes);
        self.gap_start += bytes.len;

        for (self.markers.items) |marker| {
            if (marker.offset >= offset) {
                marker.offset += bytes.len;
            }
        }

        try self.lines.on_insert(offset, bytes);
        self.is_dirty = true;
    }

    pub fn delete(self: *Buffer, offset: usize, count_to_delete: usize) Error!void {
        if (offset > self.len()) return error.OutOfBounds;
        if (offset + count_to_delete > self.len()) return error.OutOfBounds;
        if (count_to_delete == 0) return;

        self.move_gap(offset);
        self.gap_end += count_to_delete;

        for (self.markers.items) |marker| {
            if (marker.offset > offset and marker.offset <= offset + count_to_delete) {
                marker.offset = offset;
            } else if (marker.offset > offset + count_to_delete) {
                marker.offset -= count_to_delete;
            }
        }

        try self.lines.on_delete(offset, count_to_delete);
        self.is_dirty = true;
    }

    pub fn get_slice(self: *const Buffer, allocator: Allocator, start: usize, end: usize) Error![]u8 {
        if (start > end or end > self.len()) return error.OutOfBounds;
        const total = end - start;
        const result = try allocator.alloc(u8, total);

        var dest_offset: usize = 0;
        var cur = start;

        // Pre-gap segment
        if (cur < self.gap_start) {
            const pre_end = @min(end, self.gap_start);
            const pre_len = pre_end - cur;
            @memcpy(result[dest_offset..dest_offset + pre_len], self.data[cur..pre_end]);
            dest_offset += pre_len;
            cur = pre_end;
        }

        // Post-gap segment
        if (cur < end) {
            const post_cur = cur + (self.gap_end - self.gap_start);
            const post_len = end - cur;
            @memcpy(result[dest_offset..dest_offset + post_len], self.data[post_cur..post_cur + post_len]);
        }

        return result;
    }

    pub fn byte_at(self: *const Buffer, offset: usize) ?u8 {
        if (offset >= self.len()) return null;
        if (offset < self.gap_start) {
            return self.data[offset];
        } else {
            return self.data[offset + (self.gap_end - self.gap_start)];
        }
    }

    pub fn get_line(self: *const Buffer, allocator: Allocator, line_idx: usize) Error!?[]u8 {
        const start = self.lines.get_line_start(line_idx) orelse return null;
        const end = self.lines.get_line_end(line_idx, self.len()) orelse return null;
        return try self.get_slice(allocator, start, end);
    }

    pub fn create_marker(self: *Buffer, offset: usize) Error!*Marker {
        if (offset > self.len()) return error.OutOfBounds;
        const marker = try self.allocator.create(Marker);
        marker.* = .{ .offset = offset };
        try self.markers.append(self.allocator, marker);
        return marker;
    }

    pub fn destroy_marker(self: *Buffer, marker: *Marker) void {
        for (self.markers.items, 0..) |m, i| {
            if (m == marker) {
                _ = self.markers.swapRemove(i);
                self.allocator.destroy(marker);
                return;
            }
        }
    }

    extern "c" fn fseek(stream: ?*anyopaque, offset: c_long, whence: c_int) c_int;
    extern "c" fn ftell(stream: ?*anyopaque) c_long;

    pub fn save_to_file(self: *Buffer, path: [:0]const u8) FileError!void {
        const f = std.c.fopen(path.ptr, "wb") orelse return error.FileOpenFailed;
        defer _ = std.c.fclose(f);

        // Write pre-gap segment
        if (self.gap_start > 0) {
            const written = std.c.fwrite(self.data[0..self.gap_start].ptr, 1, self.gap_start, f);
            if (written < self.gap_start) return error.WriteFailed;
        }

        // Write post-gap segment
        const post_len = self.data.len - self.gap_end;
        if (post_len > 0) {
            const written = std.c.fwrite(self.data[self.gap_end..].ptr, 1, post_len, f);
            if (written < post_len) return error.WriteFailed;
        }

        if (self.file_path) |old_p| {
            self.allocator.free(old_p);
        }
        self.file_path = self.allocator.dupeZ(u8, path) catch null;
        self.is_dirty = false;
    }

    pub fn load_from_file(allocator: Allocator, path: [:0]const u8) FileError!Buffer {
        const f = std.c.fopen(path.ptr, "rb") orelse return error.FileNotFound;
        defer _ = std.c.fclose(f);

        _ = fseek(f, 0, 2); // SEEK_END
        const size_long = ftell(f);
        if (size_long < 0) return error.ReadFailed;
        const file_size: usize = @intCast(size_long);
        _ = fseek(f, 0, 0); // SEEK_SET

        var buf = Buffer.init(allocator);
        errdefer buf.deinit();

        if (file_size > 0) {
            const temp = allocator.alloc(u8, file_size) catch return error.OutOfMemory;
            defer allocator.free(temp);

            const read_bytes = std.c.fread(temp.ptr, 1, file_size, f);
            if (read_bytes < file_size) return error.ReadFailed;

            try buf.insert(0, temp[0..read_bytes]);
        }

        buf.file_path = allocator.dupeZ(u8, path) catch null;
        buf.is_dirty = false;
        return buf;
    }
};

const testing = std.testing;

test "test_buffer_init_empty" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try testing.expectEqual(@as(usize, 0), buf.len());
    try testing.expectEqual(@as(usize, 1), buf.line_count());
}

test "test_buffer_insert_at_start" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello");
    try testing.expectEqual(@as(usize, 5), buf.len());

    const slice = try buf.get_slice(testing.allocator, 0, 5);
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings("hello", slice);
}

test "test_buffer_insert_mid" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello world");
    try buf.insert(5, ", brave");

    try testing.expectEqual(@as(usize, 18), buf.len());
    const slice = try buf.get_slice(testing.allocator, 0, 18);
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings("hello, brave world", slice);
}

test "test_buffer_insert_multibyte_utf8" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello ");
    try buf.insert(6, "世界 🌍");

    const expected = "hello 世界 🌍";
    try testing.expectEqual(expected.len, buf.len());

    const slice = try buf.get_slice(testing.allocator, 0, buf.len());
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings(expected, slice);
}

test "test_buffer_delete_range" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello, brave world");
    try buf.delete(5, 7);

    try testing.expectEqual(@as(usize, 11), buf.len());
    const slice = try buf.get_slice(testing.allocator, 0, 11);
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings("hello world", slice);
}

test "test_buffer_delete_to_empty" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "xyz");
    try buf.delete(0, 3);

    try testing.expectEqual(@as(usize, 0), buf.len());
    try testing.expectEqual(@as(usize, 1), buf.line_count());
}

test "test_buffer_line_count_and_content" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "line 1\nline 2\nline 3");
    try testing.expectEqual(@as(usize, 3), buf.line_count());

    const line = (try buf.get_line(testing.allocator, 1)).?;
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("line 2", line);
}

test "test_buffer_line_updates_on_delete" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "a\nb\nc");
    try buf.delete(1, 2);

    try testing.expectEqual(@as(usize, 2), buf.line_count());
}

test "test_marker_shifts_on_preceding_insert" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello world");
    const m = try buf.create_marker(6);
    defer buf.destroy_marker(m);

    try buf.insert(0, "say ");
    try testing.expectEqual(@as(usize, 10), m.offset);
}

test "test_marker_stays_on_subsequent_insert" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello world");
    const m = try buf.create_marker(5);
    defer buf.destroy_marker(m);

    try buf.insert(6, "brave ");
    try testing.expectEqual(@as(usize, 5), m.offset);
}

test "test_marker_collapses_on_covering_delete" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "abcdef");
    const m = try buf.create_marker(3);
    defer buf.destroy_marker(m);

    try buf.delete(1, 4);
    try testing.expectEqual(@as(usize, 1), m.offset);
}

test "test_buffer_out_of_bounds_insert" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "abc");
    try testing.expectError(error.OutOfBounds, buf.insert(5, "x"));
}

test "test_buffer_out_of_bounds_delete" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "abc");
    try testing.expectError(error.OutOfBounds, buf.delete(2, 5));
}

test "test_buffer_zero_length_operations" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "abc");
    try buf.insert(1, "");
    try buf.delete(1, 0);

    try testing.expectEqual(@as(usize, 3), buf.len());
}

test "test_buffer_dirty_flag_tracking" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try testing.expect(!buf.is_dirty);
    try buf.insert(0, "hello");
    try testing.expect(buf.is_dirty);
}

test "test_buffer_save_to_file" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello world\nline two\n");
    const test_path: [:0]const u8 = "/tmp/em_test_save.txt";
    try buf.save_to_file(test_path);
    defer _ = std.c.unlink(test_path.ptr);

    try testing.expect(!buf.is_dirty);

    var loaded = try Buffer.load_from_file(testing.allocator, test_path);
    defer loaded.deinit();

    const content = try loaded.get_slice(testing.allocator, 0, loaded.len());
    defer testing.allocator.free(content);

    try testing.expectEqualStrings("hello world\nline two\n", content);
}

test "test_buffer_load_from_file" {
    const test_path: [:0]const u8 = "/tmp/em_test_load.txt";
    const f = std.c.fopen(test_path.ptr, "wb") orelse return error.FileOpenFailed;
    const test_data = "file content\nline two\nline three";
    _ = std.c.fwrite(test_data.ptr, 1, test_data.len, f);
    _ = std.c.fclose(f);
    defer _ = std.c.unlink(test_path.ptr);

    var buf = try Buffer.load_from_file(testing.allocator, test_path);
    defer buf.deinit();

    try testing.expect(!buf.is_dirty);
    try testing.expectEqual(@as(usize, 3), buf.line_count());
    const slice = try buf.get_slice(testing.allocator, 0, buf.len());
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings("file content\nline two\nline three", slice);
}
