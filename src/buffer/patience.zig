const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const HunkType = enum { equal, insert, delete };

pub const DiffHunk = struct {
    type: HunkType,
    lines: [][]const u8,
};

pub const DiffResult = struct {
    hunks: []DiffHunk,
    allocator: Allocator,

    pub fn deinit(self: *DiffResult) void {
        for (self.hunks) |h| {
            self.allocator.free(h.lines);
        }
        self.allocator.free(self.hunks);
    }
};

pub const MergeResult = struct {
    text: []u8,
    has_conflicts: bool,
    conflict_count: usize,
    allocator: Allocator,

    pub fn deinit(self: *MergeResult) void {
        self.allocator.free(self.text);
    }
};

pub fn split_lines(allocator: Allocator, text: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer list.deinit(allocator);

    if (text.len == 0) {
        return list.toOwnedSlice(allocator);
    }

    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            var line_end = i;
            if (line_end > start and text[line_end - 1] == '\r') {
                line_end -= 1;
            }
            try list.append(allocator, text[start..line_end]);
            start = i + 1;
        }
    }
    if (start < text.len) {
        try list.append(allocator, text[start..]);
    }
    return list.toOwnedSlice(allocator);
}

const Match = struct {
    a_idx: usize,
    b_idx: usize,
};

fn hash_line(line: []const u8) u64 {
    return std.hash.Wyhash.hash(0, line);
}

/// Computes Myers diff on small sub-slices where no unique anchors exist
fn myers_diff(
    allocator: Allocator,
    a: []const []const u8,
    b: []const []const u8,
    matches: *std.ArrayList(Match),
    a_offset: usize,
    b_offset: usize,
) !void {
    const n = a.len;
    const m = b.len;
    if (n == 0 or m == 0) return;

    const max_d = n + m;
    const v_size = 2 * max_d + 1;
    const v = try allocator.alloc(isize, v_size);
    defer allocator.free(v);
    @memset(v, 0);

    // Keep history of v arrays to trace back the snake path
    var trace = std.ArrayList([]isize).empty;
    defer {
        for (trace.items) |t| allocator.free(t);
        trace.deinit(allocator);
    }

    const offset: isize = @intCast(max_d);
    v[@intCast(offset + 1)] = 0;

    var found_d: usize = 0;
    outer: for (0..max_d + 1) |d| {
        const v_copy = try allocator.alloc(isize, v_size);
        @memcpy(v_copy, v);
        try trace.append(allocator, v_copy);

        const d_signed: isize = @intCast(d);
        var k: isize = -d_signed;
        while (k <= d_signed) : (k += 2) {
            const k_idx = offset + k;
            var x: isize = 0;
            if (k == -d_signed or (k != d_signed and v[@intCast(k_idx - 1)] < v[@intCast(k_idx + 1)])) {
                x = v[@intCast(k_idx + 1)];
            } else {
                x = v[@intCast(k_idx - 1)] + 1;
            }
            var y: isize = x - k;

            while (x < @as(isize, @intCast(n)) and y < @as(isize, @intCast(m)) and
                std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)]))
            {
                x += 1;
                y += 1;
            }

            v[@intCast(k_idx)] = x;

            if (x >= @as(isize, @intCast(n)) and y >= @as(isize, @intCast(m))) {
                found_d = d;
                break :outer;
            }
        }
    }

    // Backtrack to extract matched pairs
    var curr_x: isize = @intCast(n);
    var curr_y: isize = @intCast(m);
    var local_matches = std.ArrayList(Match).empty;
    defer local_matches.deinit(allocator);

    var d = found_d;
    while (d > 0) : (d -= 1) {
        const d_signed: isize = @intCast(d);
        const v_prev = trace.items[d];
        const k = curr_x - curr_y;
        const k_idx = offset + k;

        var prev_k: isize = 0;
        if (k == -d_signed or (k != d_signed and v_prev[@intCast(k_idx - 1)] < v_prev[@intCast(k_idx + 1)])) {
            prev_k = k + 1;
        } else {
            prev_k = k - 1;
        }

        const prev_x = v_prev[@intCast(offset + prev_k)];
        const prev_y = prev_x - prev_k;

        while (curr_x > prev_x and curr_y > prev_y) {
            curr_x -= 1;
            curr_y -= 1;
            try local_matches.append(allocator, .{
                .a_idx = a_offset + @as(usize, @intCast(curr_x)),
                .b_idx = b_offset + @as(usize, @intCast(curr_y)),
            });
        }

        curr_x = prev_x;
        curr_y = prev_y;
    }

    while (curr_x > 0 and curr_y > 0) {
        curr_x -= 1;
        curr_y -= 1;
        try local_matches.append(allocator, .{
            .a_idx = a_offset + @as(usize, @intCast(curr_x)),
            .b_idx = b_offset + @as(usize, @intCast(curr_y)),
        });
    }

    // Append in ascending order
    var i = local_matches.items.len;
    while (i > 0) {
        i -= 1;
        try matches.append(allocator, local_matches.items[i]);
    }
}

/// Patience Diff: recursive unique line matching with LIS
fn patience_diff_recursive(
    allocator: Allocator,
    a: []const []const u8,
    b: []const []const u8,
    matches: *std.ArrayList(Match),
    a_offset: usize,
    b_offset: usize,
) !void {
    if (a.len == 0 or b.len == 0) return;

    // 1. Prefix trim
    var prefix_len: usize = 0;
    while (prefix_len < a.len and prefix_len < b.len and
        std.mem.eql(u8, a[prefix_len], b[prefix_len])) : (prefix_len += 1)
    {
        try matches.append(allocator, .{
            .a_idx = a_offset + prefix_len,
            .b_idx = b_offset + prefix_len,
        });
    }

    if (prefix_len == a.len or prefix_len == b.len) {
        return;
    }

    // 2. Suffix trim
    var a_end = a.len;
    var b_end = b.len;
    while (a_end > prefix_len and b_end > prefix_len and
        std.mem.eql(u8, a[a_end - 1], b[b_end - 1]))
    {
        a_end -= 1;
        b_end -= 1;
    }

    const mid_a = a[prefix_len..a_end];
    const mid_b = b[prefix_len..b_end];

    // 3. Find unique lines in both mid_a and mid_b
    var a_counts = std.AutoHashMap(u64, struct { count: usize, idx: usize }).init(allocator);
    defer a_counts.deinit();

    for (mid_a, 0..) |line, idx| {
        const h = hash_line(line);
        const entry = try a_counts.getOrPut(h);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .count = 1, .idx = idx };
        } else {
            entry.value_ptr.count += 1;
        }
    }

    var b_counts = std.AutoHashMap(u64, struct { count: usize, idx: usize }).init(allocator);
    defer b_counts.deinit();

    for (mid_b, 0..) |line, idx| {
        const h = hash_line(line);
        const entry = try b_counts.getOrPut(h);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .count = 1, .idx = idx };
        } else {
            entry.value_ptr.count += 1;
        }
    }

    // Common unique lines
    var common_unique = std.ArrayList(Match).empty;
    defer common_unique.deinit(allocator);

    var iter = a_counts.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.count == 1) {
            if (b_counts.get(entry.key_ptr.*)) |b_val| {
                if (b_val.count == 1) {
                    try common_unique.append(allocator, .{
                        .a_idx = entry.value_ptr.idx,
                        .b_idx = b_val.idx,
                    });
                }
            }
        }
    }

    if (common_unique.items.len == 0) {
        // Fallback to Myers diff on this sub-slice
        try myers_diff(allocator, mid_a, mid_b, matches, a_offset + prefix_len, b_offset + prefix_len);
    } else {
        // Sort common_unique by a_idx
        std.sort.block(Match, common_unique.items, {}, struct {
            fn lessThan(_: void, x: Match, y: Match) bool {
                return x.a_idx < y.a_idx;
            }
        }.lessThan);

        // Find Longest Increasing Subsequence (LIS) on b_idx
        const lis_indices = try compute_lis(allocator, common_unique.items);
        defer allocator.free(lis_indices);

        var last_a: usize = 0;
        var last_b: usize = 0;

        for (lis_indices) |idx| {
            const m = common_unique.items[idx];
            // Recurse on range before this anchor
            try patience_diff_recursive(
                allocator,
                mid_a[last_a..m.a_idx],
                mid_b[last_b..m.b_idx],
                matches,
                a_offset + prefix_len + last_a,
                b_offset + prefix_len + last_b,
            );

            // Add anchor match
            try matches.append(allocator, .{
                .a_idx = a_offset + prefix_len + m.a_idx,
                .b_idx = b_offset + prefix_len + m.b_idx,
            });

            last_a = m.a_idx + 1;
            last_b = m.b_idx + 1;
        }

        // Recurse on range after last anchor
        try patience_diff_recursive(
            allocator,
            mid_a[last_a..],
            mid_b[last_b..],
            matches,
            a_offset + prefix_len + last_a,
            b_offset + prefix_len + last_b,
        );
    }

    // Append suffix matches
    var s = a_end;
    var t = b_end;
    while (s < a.len and t < b.len) : ({
        s += 1;
        t += 1;
    }) {
        try matches.append(allocator, .{
            .a_idx = a_offset + s,
            .b_idx = b_offset + t,
        });
    }
}

/// Compute Longest Increasing Subsequence of b_idx in O(N log N)
fn compute_lis(allocator: Allocator, items: []const Match) ![]usize {
    if (items.len == 0) return try allocator.alloc(usize, 0);

    var tails = std.ArrayList(usize).empty;
    defer tails.deinit(allocator);

    var prev = try allocator.alloc(?usize, items.len);
    defer allocator.free(prev);
    @memset(prev, null);

    for (items, 0..) |item, i| {
        // Binary search for smallest tail >= item.b_idx
        var left: usize = 0;
        var right: usize = tails.items.len;
        while (left < right) {
            const mid = left + (right - left) / 2;
            if (items[tails.items[mid]].b_idx < item.b_idx) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        if (left > 0) {
            prev[i] = tails.items[left - 1];
        }

        if (left == tails.items.len) {
            try tails.append(allocator, i);
        } else {
            tails.items[left] = i;
        }
    }

    var result = try allocator.alloc(usize, tails.items.len);
    if (tails.items.len > 0) {
        var curr: ?usize = tails.items[tails.items.len - 1];
        var idx = tails.items.len;
        while (curr) |c| {
            idx -= 1;
            result[idx] = c;
            curr = prev[c];
        }
    }
    return result;
}

/// Public 2-Way Patience Diff
pub fn patience_diff(allocator: Allocator, a_text: []const u8, b_text: []const u8) !DiffResult {
    const a_lines = try split_lines(allocator, a_text);
    defer allocator.free(a_lines);
    const b_lines = try split_lines(allocator, b_text);
    defer allocator.free(b_lines);

    var matches = std.ArrayList(Match).empty;
    defer matches.deinit(allocator);

    try patience_diff_recursive(allocator, a_lines, b_lines, &matches, 0, 0);

    // Build diff hunks from matched pairs
    var hunks = std.ArrayList(DiffHunk).empty;
    errdefer {
        for (hunks.items) |h| allocator.free(h.lines);
        hunks.deinit(allocator);
    }

    var curr_a: usize = 0;
    var curr_b: usize = 0;

    for (matches.items) |m| {
        if (m.a_idx > curr_a) {
            // Deleted lines from a
            const del_slice = a_lines[curr_a..m.a_idx];
            const del_copy = try allocator.alloc([]const u8, del_slice.len);
            @memcpy(del_copy, del_slice);
            try hunks.append(allocator, .{ .type = .delete, .lines = del_copy });
        }
        if (m.b_idx > curr_b) {
            // Inserted lines from b
            const ins_slice = b_lines[curr_b..m.b_idx];
            const ins_copy = try allocator.alloc([]const u8, ins_slice.len);
            @memcpy(ins_copy, ins_slice);
            try hunks.append(allocator, .{ .type = .insert, .lines = ins_copy });
        }

        curr_a = m.a_idx + 1;
        curr_b = m.b_idx + 1;
    }

    if (curr_a < a_lines.len) {
        const del_slice = a_lines[curr_a..];
        const del_copy = try allocator.alloc([]const u8, del_slice.len);
        @memcpy(del_copy, del_slice);
        try hunks.append(allocator, .{ .type = .delete, .lines = del_copy });
    }
    if (curr_b < b_lines.len) {
        const ins_slice = b_lines[curr_b..];
        const ins_copy = try allocator.alloc([]const u8, ins_slice.len);
        @memcpy(ins_copy, ins_slice);
        try hunks.append(allocator, .{ .type = .insert, .lines = ins_copy });
    }

    return DiffResult{
        .hunks = try hunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// -------------------------------------------------------------------------
// 3-Way Merge (diff3) Engine
// -------------------------------------------------------------------------

fn lines_equal(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |item, i| {
        if (!std.mem.eql(u8, item, b[i])) return false;
    }
    return true;
}

pub fn merge3(
    allocator: Allocator,
    base_text: []const u8,
    mine_text: []const u8,
    theirs_text: []const u8,
    mine_label: []const u8,
    theirs_label: []const u8,
) !MergeResult {
    // If identical or empty shortcuts
    if (std.mem.eql(u8, mine_text, theirs_text)) {
        return MergeResult{
            .text = try allocator.dupe(u8, mine_text),
            .has_conflicts = false,
            .conflict_count = 0,
            .allocator = allocator,
        };
    }
    if (std.mem.eql(u8, base_text, mine_text)) {
        return MergeResult{
            .text = try allocator.dupe(u8, theirs_text),
            .has_conflicts = false,
            .conflict_count = 0,
            .allocator = allocator,
        };
    }
    if (std.mem.eql(u8, base_text, theirs_text)) {
        return MergeResult{
            .text = try allocator.dupe(u8, mine_text),
            .has_conflicts = false,
            .conflict_count = 0,
            .allocator = allocator,
        };
    }

    const base_lines = try split_lines(allocator, base_text);
    defer allocator.free(base_lines);
    const mine_lines = try split_lines(allocator, mine_text);
    defer allocator.free(mine_lines);
    const theirs_lines = try split_lines(allocator, theirs_text);
    defer allocator.free(theirs_lines);

    // Compute matches from base to mine and base to theirs
    var m_matches = std.ArrayList(Match).empty;
    defer m_matches.deinit(allocator);
    try patience_diff_recursive(allocator, base_lines, mine_lines, &m_matches, 0, 0);

    var t_matches = std.ArrayList(Match).empty;
    defer t_matches.deinit(allocator);
    try patience_diff_recursive(allocator, base_lines, theirs_lines, &t_matches, 0, 0);

    // Find all 3-way synchronization points where base[b] matches mine[m] and theirs[t]
    var base_to_mine = try allocator.alloc(?usize, base_lines.len);
    defer allocator.free(base_to_mine);
    @memset(base_to_mine, null);
    for (m_matches.items) |m| {
        base_to_mine[m.a_idx] = m.b_idx;
    }

    var base_to_theirs = try allocator.alloc(?usize, base_lines.len);
    defer allocator.free(base_to_theirs);
    @memset(base_to_theirs, null);
    for (t_matches.items) |t| {
        base_to_theirs[t.a_idx] = t.b_idx;
    }

    const SyncPoint = struct {
        b: usize,
        m: usize,
        t: usize,
    };

    var sync_points = std.ArrayList(SyncPoint).empty;
    defer sync_points.deinit(allocator);

    for (0..base_lines.len) |b| {
        if (base_to_mine[b]) |m| {
            if (base_to_theirs[b]) |t| {
                try sync_points.append(allocator, .{ .b = b, .m = m, .t = t });
            }
        }
    }

    // Iterate intervals between 3-way synchronization points
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var has_conflicts = false;
    var conflict_count: usize = 0;

    var prev_b: usize = 0;
    var prev_m: usize = 0;
    var prev_t: usize = 0;

    const total_intervals = sync_points.items.len + 1;
    for (0..total_intervals) |idx| {
        const curr_b = if (idx < sync_points.items.len) sync_points.items[idx].b else base_lines.len;
        const curr_m = if (idx < sync_points.items.len) sync_points.items[idx].m else mine_lines.len;
        const curr_t = if (idx < sync_points.items.len) sync_points.items[idx].t else theirs_lines.len;

        const b_chunk = base_lines[prev_b..curr_b];
        const m_chunk = mine_lines[prev_m..curr_m];
        const t_chunk = theirs_lines[prev_t..curr_t];

        const m_eq_b = lines_equal(m_chunk, b_chunk);
        const t_eq_b = lines_equal(t_chunk, b_chunk);
        const m_eq_t = lines_equal(m_chunk, t_chunk);

        if (m_eq_t) {
            // Both sides made the same edit (or neither made an edit)
            for (m_chunk) |line| {
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
            }
        } else if (m_eq_b and !t_eq_b) {
            // Only theirs changed
            for (t_chunk) |line| {
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
            }
        } else if (!m_eq_b and t_eq_b) {
            // Only mine changed
            for (m_chunk) |line| {
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
            }
        } else {
            // Both changed differently: Conflict!
            has_conflicts = true;
            conflict_count += 1;
            try out.appendSlice(allocator, "<<<<<<< ");
            try out.appendSlice(allocator, mine_label);
            try out.append(allocator, '\n');
            for (m_chunk) |line| {
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
            }
            try out.appendSlice(allocator, "=======\n");
            for (t_chunk) |line| {
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
            }
            try out.appendSlice(allocator, ">>>>>>> ");
            try out.appendSlice(allocator, theirs_label);
            try out.append(allocator, '\n');
        }

        // If at a sync point, output the common synchronized line
        if (idx < sync_points.items.len) {
            try out.appendSlice(allocator, base_lines[curr_b]);
            try out.append(allocator, '\n');
            prev_b = curr_b + 1;
            prev_m = curr_m + 1;
            prev_t = curr_t + 1;
        }
    }

    return MergeResult{
        .text = try out.toOwnedSlice(allocator),
        .has_conflicts = has_conflicts,
        .conflict_count = conflict_count,
        .allocator = allocator,
    };
}

// -------------------------------------------------------------------------
// Section 1: Patience 2-Way Diff Tests
// -------------------------------------------------------------------------

test "test_patience_diff_identical_texts" {
    var res = try patience_diff(testing.allocator, "line 1\nline 2\nline 3\n", "line 1\nline 2\nline 3\n");
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.hunks.len);
}

test "test_patience_diff_pure_insertion" {
    var res = try patience_diff(testing.allocator, "alpha\ngamma\n", "alpha\nbeta\ngamma\n");
    defer res.deinit();

    try testing.expect(res.hunks.len > 0);
    var found_insert = false;
    for (res.hunks) |h| {
        if (h.type == .insert) {
            found_insert = true;
            try testing.expectEqualStrings("beta", h.lines[0]);
        }
    }
    try testing.expect(found_insert);
}

test "test_patience_diff_pure_deletion" {
    var res = try patience_diff(testing.allocator, "alpha\nbeta\ngamma\n", "alpha\ngamma\n");
    defer res.deinit();

    try testing.expect(res.hunks.len > 0);
    var found_delete = false;
    for (res.hunks) |h| {
        if (h.type == .delete) {
            found_delete = true;
            try testing.expectEqualStrings("beta", h.lines[0]);
        }
    }
    try testing.expect(found_delete);
}

test "test_patience_diff_unique_anchor_preservation" {
    const a =
        \\fn foo() {
        \\    return 1;
        \\}
        \\
        \\fn bar() {
        \\    return 2;
        \\}
        \\
    ;
    const b =
        \\fn foo() {
        \\    return 1;
        \\}
        \\
        \\fn baz() {
        \\    return 3;
        \\}
        \\
        \\fn bar() {
        \\    return 2;
        \\}
        \\
    ;
    var res = try patience_diff(testing.allocator, a, b);
    defer res.deinit();

    try testing.expect(res.hunks.len > 0);
    var found_baz = false;
    for (res.hunks) |h| {
        if (h.type == .insert) {
            for (h.lines) |l| {
                if (std.mem.indexOf(u8, l, "baz") != null) {
                    found_baz = true;
                }
            }
        }
    }
    try testing.expect(found_baz);
}

// -------------------------------------------------------------------------
// Section 2: 3-Way Clean Merges
// -------------------------------------------------------------------------

test "test_merge3_clean_only_mine_changed" {
    const base = "line 1\nline 2\nline 3\n";
    const mine = "line 1\nline 2 edited\nline 3\n";
    const theirs = "line 1\nline 2\nline 3\n";

    var res = try merge3(testing.allocator, base, mine, theirs, "In-Memory", "Disk");
    defer res.deinit();

    try testing.expect(!res.has_conflicts);
    try testing.expectEqualStrings(mine, res.text);
}

test "test_merge3_clean_only_theirs_changed" {
    const base = "line 1\nline 2\nline 3\n";
    const mine = "line 1\nline 2\nline 3\n";
    const theirs = "line 1\nline 2 external\nline 3\n";

    var res = try merge3(testing.allocator, base, mine, theirs, "In-Memory", "Disk");
    defer res.deinit();

    try testing.expect(!res.has_conflicts);
    try testing.expectEqualStrings(theirs, res.text);
}

test "test_merge3_clean_disjoint_edits" {
    const base = "header\ncommon\nfooter\n";
    const mine = "header edited\ncommon\nfooter\n";
    const theirs = "header\ncommon\nfooter edited\n";
    const expected = "header edited\ncommon\nfooter edited\n";

    var res = try merge3(testing.allocator, base, mine, theirs, "In-Memory", "Disk");
    defer res.deinit();

    try testing.expect(!res.has_conflicts);
    try testing.expectEqualStrings(expected, res.text);
}

test "test_merge3_clean_identical_edits" {
    const base = "key = old_val\n";
    const mine = "key = new_val\n";
    const theirs = "key = new_val\n";

    var res = try merge3(testing.allocator, base, mine, theirs, "In-Memory", "Disk");
    defer res.deinit();

    try testing.expect(!res.has_conflicts);
    try testing.expectEqualStrings("key = new_val\n", res.text);
}

// -------------------------------------------------------------------------
// Section 3: 3-Way Conflicting Merges
// -------------------------------------------------------------------------

test "test_merge3_single_line_conflict" {
    const base = "const x = 1;\n";
    const mine = "const x = 2;\n";
    const theirs = "const x = 3;\n";

    var res = try merge3(testing.allocator, base, mine, theirs, "In-Memory", "Disk");
    defer res.deinit();

    try testing.expect(res.has_conflicts);
    try testing.expect(res.conflict_count == 1);
    const expected =
        \\<<<<<<< In-Memory
        \\const x = 2;
        \\=======
        \\const x = 3;
        \\>>>>>>> Disk
        \\
    ;
    try testing.expectEqualStrings(expected, res.text);
}

test "test_merge3_multi_line_conflict_with_clean_context" {
    const base = "start\nmiddle_base_1\nmiddle_base_2\nend\n";
    const mine = "start\nmiddle_mine\nend\n";
    const theirs = "start\nmiddle_theirs_1\nmiddle_theirs_2\nend\n";

    var res = try merge3(testing.allocator, base, mine, theirs, "In-Memory", "Disk");
    defer res.deinit();

    try testing.expect(res.has_conflicts);
    const expected =
        \\start
        \\<<<<<<< In-Memory
        \\middle_mine
        \\=======
        \\middle_theirs_1
        \\middle_theirs_2
        \\>>>>>>> Disk
        \\end
        \\
    ;
    try testing.expectEqualStrings(expected, res.text);
}

test "test_merge3_delete_vs_modify_conflict" {
    const base = "intro\nbody\noutro\n";
    const mine = "intro\noutro\n";
    const theirs = "intro\nbody updated\noutro\n";

    var res = try merge3(testing.allocator, base, mine, theirs, "In-Memory", "Disk");
    defer res.deinit();

    try testing.expect(res.has_conflicts);
    const expected =
        \\intro
        \\<<<<<<< In-Memory
        \\=======
        \\body updated
        \\>>>>>>> Disk
        \\outro
        \\
    ;
    try testing.expectEqualStrings(expected, res.text);
}

// -------------------------------------------------------------------------
// Section 4: Edge Cases & Boundary Conditions
// -------------------------------------------------------------------------

test "test_patience_diff_all_empty" {
    var res = try merge3(testing.allocator, "", "", "", "In-Memory", "Disk");
    defer res.deinit();

    try testing.expect(!res.has_conflicts);
    try testing.expectEqualStrings("", res.text);
}

test "test_merge3_base_empty_both_added" {
    const base = "";
    const mine = "hello from buffer\n";
    const theirs = "hello from disk\n";

    var res = try merge3(testing.allocator, base, mine, theirs, "In-Memory", "Disk");
    defer res.deinit();

    try testing.expect(res.has_conflicts);
    const expected =
        \\<<<<<<< In-Memory
        \\hello from buffer
        \\=======
        \\hello from disk
        \\>>>>>>> Disk
        \\
    ;
    try testing.expectEqualStrings(expected, res.text);
}

test "test_patience_diff_repeated_non_unique_lines" {
    const a = "}\n}\n}\n}\n";
    const b = "}\n}\n// inserted\n}\n}\n";

    var res = try patience_diff(testing.allocator, a, b);
    defer res.deinit();

    try testing.expect(res.hunks.len > 0);
}

test "test_patience_no_trailing_newline_handling" {
    const a = "line 1\nline 2";
    const b = "line 1\nline 2 modified";

    var res = try patience_diff(testing.allocator, a, b);
    defer res.deinit();

    try testing.expect(res.hunks.len > 0);
}
