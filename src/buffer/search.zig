const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;

pub const Match = struct {
    offset: usize,
    len: usize,
};

pub const Direction = enum {
    forward,
    backward,
};

pub fn has_upper(s: []const u8) bool {
    for (s) |c| {
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

pub const BmhScanner = struct {
    pattern: []const u8,
    bad_char_table: [256]usize,
    is_case_sensitive: bool,

    pub fn init(pattern: []const u8) BmhScanner {
        const sensitive = has_upper(pattern);
        var table: [256]usize = undefined;
        const pat_len = pattern.len;
        @memset(&table, pat_len);
        if (pat_len > 1) {
            for (pattern[0 .. pat_len - 1], 0..) |c, i| {
                const shift = pat_len - 1 - i;
                if (sensitive) {
                    table[c] = shift;
                } else {
                    table[std.ascii.toLower(c)] = shift;
                    table[std.ascii.toUpper(c)] = shift;
                }
            }
        }
        return .{
            .pattern = pattern,
            .bad_char_table = table,
            .is_case_sensitive = sensitive,
        };
    }

    pub fn char_eq(self: *const BmhScanner, a: u8, b: u8) bool {
        if (self.is_case_sensitive) {
            return a == b;
        } else {
            return std.ascii.toLower(a) == std.ascii.toLower(b);
        }
    }

    pub fn search_slice(self: *const BmhScanner, text: []const u8, from: usize) ?usize {
        const m = self.pattern.len;
        const n = text.len;
        if (m == 0 or m > n or from > n - m) return null;

        var i: usize = from;
        while (i <= n - m) {
            var j: usize = m - 1;
            while (self.char_eq(text[i + j], self.pattern[j])) {
                if (j == 0) return i;
                j -= 1;
            }
            i += self.bad_char_table[text[i + m - 1]];
        }
        return null;
    }

    pub fn search_slice_backward(self: *const BmhScanner, text: []const u8, from: usize) ?usize {
        const m = self.pattern.len;
        const n = text.len;
        if (m == 0 or m > n) return null;

        var max_start = if (from >= m) from - m else 0;
        if (from >= n) max_start = n - m;

        var i: isize = @intCast(max_start);
        while (i >= 0) {
            var j: usize = 0;
            var matched = true;
            while (j < m) : (j += 1) {
                if (!self.char_eq(text[@as(usize, @intCast(i)) + j], self.pattern[j])) {
                    matched = false;
                    break;
                }
            }
            if (matched) return @intCast(i);
            i -= 1;
        }
        return null;
    }
};

fn check_straddle_match(buf: *const Buffer, logical_off: usize, scanner: *const BmhScanner) bool {
    const pattern = scanner.pattern;
    const m = pattern.len;
    if (logical_off + m > buf.len()) return false;
    if (logical_off >= buf.gap_start or logical_off + m <= buf.gap_start) return false;

    const pre_len = buf.gap_start - logical_off;
    const post_len = m - pre_len;

    const pre_slice = buf.data[logical_off..buf.gap_start];
    for (pre_slice, 0..) |c, i| {
        if (!scanner.char_eq(c, pattern[i])) return false;
    }

    const post_slice = buf.data[buf.gap_end .. buf.gap_end + post_len];
    for (post_slice, 0..) |c, i| {
        if (!scanner.char_eq(c, pattern[pre_len + i])) return false;
    }

    return true;
}

pub fn find_forward_unwrapped(buf: *const Buffer, start: usize, end: usize, scanner: *const BmhScanner) ?Match {
    const m = scanner.pattern.len;
    if (m == 0 or start >= end or end > buf.len() or end - start < m) return null;

    const gap_gap = buf.gap_end - buf.gap_start;

    // 1. Scan pre-gap segment if start is before gap_start
    if (start < buf.gap_start) {
        const seg_end = @min(end, buf.gap_start);
        const pre_slice = buf.data[0..seg_end];
        if (scanner.search_slice(pre_slice, start)) |idx| {
            return .{ .offset = idx, .len = m };
        }

        // 2. Check straddle zone across gap boundary
        if (m > 1 and end > buf.gap_start) {
            const min_straddle = if (buf.gap_start >= m - 1) buf.gap_start - (m - 1) else 0;
            const straddle_start = @max(start, min_straddle);
            var k = straddle_start;
            while (k < buf.gap_start) : (k += 1) {
                if (check_straddle_match(buf, k, scanner)) {
                    return .{ .offset = k, .len = m };
                }
            }
        }
    }

    // 3. Scan post-gap segment
    const post_start_logical = @max(start, buf.gap_start);
    if (post_start_logical < end and end > buf.gap_start) {
        const post_phys_start = post_start_logical + gap_gap;
        const post_phys_end = end + gap_gap;
        if (post_phys_end <= buf.data.len) {
            const post_slice = buf.data[buf.gap_end..post_phys_end];
            const from_in_post = post_phys_start - buf.gap_end;
            if (scanner.search_slice(post_slice, from_in_post)) |idx| {
                const logical = buf.gap_start + idx;
                return .{ .offset = logical, .len = m };
            }
        }
    }

    return null;
}

pub fn find_backward_unwrapped(buf: *const Buffer, start: usize, end: usize, scanner: *const BmhScanner) ?Match {
    const m = scanner.pattern.len;
    if (m == 0 or start >= end or end > buf.len() or end - start < m) return null;

    const gap_gap = buf.gap_end - buf.gap_start;

    // 1. Scan post-gap segment first (searching backward from end down to gap_start)
    if (end > buf.gap_start) {
        const post_start_logical = @max(start, buf.gap_start);
        const post_phys_end = end + gap_gap;
        if (post_phys_end <= buf.data.len) {
            const post_slice = buf.data[buf.gap_end..post_phys_end];
            const from_in_post = post_phys_end - buf.gap_end;
            if (scanner.search_slice_backward(post_slice, from_in_post)) |idx| {
                const logical = buf.gap_start + idx;
                if (logical >= post_start_logical) {
                    return .{ .offset = logical, .len = m };
                }
            }
        }

        // 2. Check straddle zone backward
        if (m > 1 and start < buf.gap_start) {
            const min_straddle = if (buf.gap_start >= m - 1) buf.gap_start - (m - 1) else 0;
            const straddle_start = @max(start, min_straddle);
            var k: isize = @as(isize, @intCast(buf.gap_start)) - 1;
            while (k >= @as(isize, @intCast(straddle_start))) : (k -= 1) {
                const uk: usize = @intCast(k);
                if (uk + m <= end and check_straddle_match(buf, uk, scanner)) {
                    return .{ .offset = uk, .len = m };
                }
            }
        }
    }

    // 3. Scan pre-gap segment
    if (start < buf.gap_start) {
        const seg_end = @min(end, buf.gap_start);
        const pre_slice = buf.data[0..seg_end];
        if (scanner.search_slice_backward(pre_slice, seg_end)) |idx| {
            if (idx >= start) {
                return .{ .offset = idx, .len = m };
            }
        }
    }

    return null;
}

pub fn find_next(buf: *const Buffer, start_offset: usize, pattern: []const u8) ?Match {
    if (pattern.len == 0 or buf.len() < pattern.len) return null;
    const scanner = BmhScanner.init(pattern);

    const from = if (start_offset >= buf.len()) 0 else start_offset;

    // Scan from cursor to buffer end
    if (find_forward_unwrapped(buf, from, buf.len(), &scanner)) |m| {
        return m;
    }

    // Wrap around from beginning up to cursor
    if (from > 0) {
        const wrap_end = @min(from + pattern.len - 1, buf.len());
        if (find_forward_unwrapped(buf, 0, wrap_end, &scanner)) |m| {
            return m;
        }
    }

    return null;
}

pub fn find_prev(buf: *const Buffer, start_offset: usize, pattern: []const u8) ?Match {
    if (pattern.len == 0 or buf.len() < pattern.len) return null;
    const scanner = BmhScanner.init(pattern);

    const from = if (start_offset > buf.len()) buf.len() else start_offset;

    // Scan backward from cursor to buffer start
    if (from > 0) {
        if (find_backward_unwrapped(buf, 0, from, &scanner)) |m| {
            return m;
        }
    }

    // Wrap around from buffer end down to cursor
    if (from < buf.len()) {
        const wrap_start = if (from >= pattern.len) from - pattern.len + 1 else 0;
        if (find_backward_unwrapped(buf, wrap_start, buf.len(), &scanner)) |m| {
            return m;
        }
    }

    return null;
}

pub fn find_in_range(
    buf: *const Buffer,
    range_start: usize,
    range_end: usize,
    pattern: []const u8,
    allocator: Allocator,
) ![]Match {
    if (pattern.len == 0 or range_start >= range_end or range_end > buf.len()) {
        return try allocator.alloc(Match, 0);
    }

    const scanner = BmhScanner.init(pattern);
    var list = std.ArrayList(Match).empty;
    errdefer list.deinit(allocator);

    var cur = range_start;
    while (cur < range_end) {
        if (find_forward_unwrapped(buf, cur, range_end, &scanner)) |m| {
            try list.append(allocator, m);
            cur = m.offset + @max(m.len, 1);
        } else {
            break;
        }
    }

    return list.toOwnedSlice(allocator);
}

pub fn replace_in_range(
    buf: *Buffer,
    allocator: Allocator,
    pattern: []const u8,
    replacement: []const u8,
    range_start: usize,
    range_end: usize,
    all: bool,
) !usize {
    if (pattern.len == 0 or range_start >= range_end or range_end > buf.len()) return 0;

    const all_matches = try find_in_range(buf, range_start, range_end, pattern, allocator);
    defer allocator.free(all_matches);

    if (all_matches.len == 0) return 0;

    const matches = if (all) all_matches else all_matches[0..1];
    const match_count = matches.len;

    const orig_len = range_end - range_start;
    const new_len = orig_len + match_count * replacement.len - match_count * pattern.len;
    const new_text = try allocator.alloc(u8, new_len);
    defer allocator.free(new_text);

    var src_cur = range_start;
    var dst_cur: usize = 0;
    for (matches) |m| {
        const copy_len = m.offset - src_cur;
        if (copy_len > 0) {
            const pre_slice = try buf.get_slice(allocator, src_cur, m.offset);
            defer allocator.free(pre_slice);
            @memcpy(new_text[dst_cur .. dst_cur + copy_len], pre_slice);
            dst_cur += copy_len;
        }

        if (replacement.len > 0) {
            @memcpy(new_text[dst_cur .. dst_cur + replacement.len], replacement);
            dst_cur += replacement.len;
        }
        src_cur = m.offset + m.len;
    }

    if (src_cur < range_end) {
        const tail_len = range_end - src_cur;
        const tail_slice = try buf.get_slice(allocator, src_cur, range_end);
        defer allocator.free(tail_slice);
        @memcpy(new_text[dst_cur .. dst_cur + tail_len], tail_slice);
        dst_cur += tail_len;
    }

    const old_text = try buf.get_slice(allocator, range_start, range_end);
    defer allocator.free(old_text);

    try buf.delete_raw(range_start, orig_len);
    try buf.insert_raw(range_start, new_text);

    _ = try buf.undo_tree.add_change(range_start, new_text, old_text, 0, 0);
    buf.is_dirty = !buf.undo_tree.is_at_save_point();

    return match_count;
}

const testing = std.testing;

test "test_bmh_forward_search_basic" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "the quick brown fox jumps over the lazy dog");

    const m1 = find_next(&buf, 0, "fox");
    try testing.expect(m1 != null);
    try testing.expectEqual(@as(usize, 16), m1.?.offset);
    try testing.expectEqual(@as(usize, 3), m1.?.len);

    // Search starting past the match
    const m2 = find_next(&buf, 20, "the");
    try testing.expect(m2 != null);
    try testing.expectEqual(@as(usize, 31), m2.?.offset);

    // Wraparound search
    const m3 = find_next(&buf, 35, "quick");
    try testing.expect(m3 != null);
    try testing.expectEqual(@as(usize, 4), m3.?.offset);
}

test "test_bmh_search_across_gap_boundary" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "ABCDEFGHIJ");
    // Move gap to index 4 (between D and E)
    buf.move_gap(4);

    const m = find_next(&buf, 0, "CDEF");
    try testing.expect(m != null);
    try testing.expectEqual(@as(usize, 2), m.?.offset);
    try testing.expectEqual(@as(usize, 4), m.?.len);
}

test "test_bmh_backward_search_and_wrap" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "apple banana apple cherry apple");

    // Matches are at 0, 13, 26
    const m1 = find_prev(&buf, 25, "apple");
    try testing.expect(m1 != null);
    try testing.expectEqual(@as(usize, 13), m1.?.offset);

    // Wraparound search from offset 0
    const m2 = find_prev(&buf, 0, "apple");
    try testing.expect(m2 != null);
    try testing.expectEqual(@as(usize, 26), m2.?.offset);
}

test "test_find_in_range_viewport_slice" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "var x = 1;\nvar y = 2;\nvar z = 3;\nvar w = 4;\n");

    // Range covering only lines 2 and 3
    const l2_start = buf.lines.get_line_start(1).?;
    const l3_end = buf.lines.get_line_end(2, buf.len()).?;

    const matches = try find_in_range(&buf, l2_start, l3_end, "var", testing.allocator);
    defer testing.allocator.free(matches);

    try testing.expectEqual(@as(usize, 2), matches.len);
    try testing.expectEqual(buf.lines.get_line_start(1).?, matches[0].offset);
    try testing.expectEqual(buf.lines.get_line_start(2).?, matches[1].offset);
}

test "test_single_pass_substitution_entire_buffer" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "foo and foo, but not bar, yet foo again");

    // Replace all "foo" with "SUPER_BAR"
    const replaced = try replace_in_range(&buf, testing.allocator, "foo", "SUPER_BAR", 0, buf.len(), true);
    try testing.expectEqual(@as(usize, 3), replaced);

    const slice = try buf.get_slice(testing.allocator, 0, buf.len());
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings("SUPER_BAR and SUPER_BAR, but not bar, yet SUPER_BAR again", slice);
    try testing.expect(buf.is_dirty);

    // Roll back via undo in a single step
    const step = buf.undo();
    try testing.expect(step != null);

    const undo_slice = try buf.get_slice(testing.allocator, 0, buf.len());
    defer testing.allocator.free(undo_slice);
    try testing.expectEqualStrings("foo and foo, but not bar, yet foo again", undo_slice);
}

test "test_smartcase_lowercase_pattern_is_case_insensitive" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "Apple and apple and APPLE");

    // All-lowercase needle "apple" must match "Apple", "apple", and "APPLE"
    const m1 = find_next(&buf, 0, "apple");
    try testing.expect(m1 != null);
    try testing.expectEqual(@as(usize, 0), m1.?.offset);

    const m2 = find_next(&buf, 5, "apple");
    try testing.expect(m2 != null);
    try testing.expectEqual(@as(usize, 10), m2.?.offset);

    const m3 = find_next(&buf, 15, "apple");
    try testing.expect(m3 != null);
    try testing.expectEqual(@as(usize, 20), m3.?.offset);
}

test "test_smartcase_uppercase_pattern_is_case_sensitive" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "apple and Apple and APPLE");

    // Mixed-case needle "Apple" must ONLY match "Apple" at 10
    const m1 = find_next(&buf, 0, "Apple");
    try testing.expect(m1 != null);
    try testing.expectEqual(@as(usize, 10), m1.?.offset);

    // Past offset 10, wraparound should find "Apple" at 10 again (not "apple" or "APPLE")
    const m2 = find_next(&buf, 15, "Apple");
    try testing.expect(m2 != null);
    try testing.expectEqual(@as(usize, 10), m2.?.offset);
}
