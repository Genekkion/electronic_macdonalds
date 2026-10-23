const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const MAX_ENTRIES: usize = 100;
pub const MAX_LEN: usize = 256;

pub const HistoryCategory = struct {
    entries: [MAX_ENTRIES][MAX_LEN]u8 = undefined,
    lens: [MAX_ENTRIES]usize = [_]usize{0} ** MAX_ENTRIES,
    count: usize = 0,

    // Navigation state
    nav_index: ?usize = null, // null means at present (draft)
    draft: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    draft_len: usize = 0,
    prefix: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    prefix_len: usize = 0,
    has_prefix: bool = false,

    pub fn add(self: *HistoryCategory, entry: []const u8) void {
        if (entry.len == 0) return;
        const len = @min(entry.len, MAX_LEN);

        // Check consecutive duplicate
        if (self.count > 0) {
            const last_len = self.lens[self.count - 1];
            if (last_len == len and std.mem.eql(u8, self.entries[self.count - 1][0..last_len], entry[0..len])) {
                return;
            }
        }

        if (self.count < MAX_ENTRIES) {
            @memcpy(self.entries[self.count][0..len], entry[0..len]);
            self.lens[self.count] = len;
            self.count += 1;
        } else {
            // FIFO shift: drop oldest entry
            var i: usize = 0;
            while (i + 1 < MAX_ENTRIES) : (i += 1) {
                self.entries[i] = self.entries[i + 1];
                self.lens[i] = self.lens[i + 1];
            }
            @memcpy(self.entries[MAX_ENTRIES - 1][0..len], entry[0..len]);
            self.lens[MAX_ENTRIES - 1] = len;
        }
    }

    pub fn reset_nav(self: *HistoryCategory) void {
        self.nav_index = null;
        self.draft_len = 0;
        self.prefix_len = 0;
        self.has_prefix = false;
    }

    pub fn get(self: *const HistoryCategory, idx: usize) ?[]const u8 {
        if (idx >= self.count) return null;
        return self.entries[idx][0..self.lens[idx]];
    }

    pub fn navigate_up(self: *HistoryCategory, current_text: []const u8) ?[]const u8 {
        if (self.count == 0) return null;

        if (self.nav_index == null) {
            // Starting navigation from draft
            const clen = @min(current_text.len, MAX_LEN);
            @memcpy(self.draft[0..clen], current_text[0..clen]);
            self.draft_len = clen;
            @memcpy(self.prefix[0..clen], current_text[0..clen]);
            self.prefix_len = clen;
            self.has_prefix = (clen > 0);

            var i = self.count;
            while (i > 0) {
                i -= 1;
                const item = self.get(i).?;
                if (!self.has_prefix or std.mem.startsWith(u8, item, self.prefix[0..self.prefix_len])) {
                    self.nav_index = i;
                    return item;
                }
            }
            return null;
        } else {
            var i = self.nav_index.?;
            while (i > 0) {
                i -= 1;
                const item = self.get(i).?;
                if (!self.has_prefix or std.mem.startsWith(u8, item, self.prefix[0..self.prefix_len])) {
                    self.nav_index = i;
                    return item;
                }
            }
            return null;
        }
    }

    pub fn navigate_down(self: *HistoryCategory) ?[]const u8 {
        if (self.nav_index == null) return null;

        var i = self.nav_index.? + 1;
        while (i < self.count) : (i += 1) {
            const item = self.get(i).?;
            if (!self.has_prefix or std.mem.startsWith(u8, item, self.prefix[0..self.prefix_len])) {
                self.nav_index = i;
                return item;
            }
        }

        // Return to present draft
        self.nav_index = null;
        return self.draft[0..self.draft_len];
    }
};

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn default_io() Io {
    return Io.Threaded.global_single_threaded.io();
}

pub fn ensure_dir_recursive(path: []const u8) void {
    if (path.len == 0) return;
    Io.Dir.cwd().createDirPath(default_io(), path) catch {};
}

const HistoryJson = struct {
    version: u32 = 1,
    commands: [][]const u8,
    searches: [][]const u8,
};

pub const HistoryStore = struct {
    commands: HistoryCategory = .{},
    searches: HistoryCategory = .{},

    pub fn save_to_file(self: *const HistoryStore, allocator: Allocator, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |dir| {
            if (dir.len > 0) {
                ensure_dir_recursive(dir);
            }
        }

        const cmd_slice = try allocator.alloc([]const u8, self.commands.count);
        defer allocator.free(cmd_slice);
        for (0..self.commands.count) |i| {
            cmd_slice[i] = self.commands.get(i).?;
        }

        const search_slice = try allocator.alloc([]const u8, self.searches.count);
        defer allocator.free(search_slice);
        for (0..self.searches.count) |i| {
            search_slice[i] = self.searches.get(i).?;
        }

        const data = HistoryJson{
            .version = 1,
            .commands = cmd_slice,
            .searches = search_slice,
        };

        const json_str = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(data, .{ .whitespace = .indent_2 })});
        defer allocator.free(json_str);

        Io.Dir.cwd().writeFile(default_io(), .{
            .sub_path = path,
            .data = json_str,
        }) catch return error.WriteFailed;
    }

    pub fn load_from_file(self: *HistoryStore, allocator: Allocator, path: []const u8) !void {
        const buf = Io.Dir.cwd().readFileAlloc(default_io(), path, allocator, .limited(1024 * 1024)) catch return;
        defer allocator.free(buf);
        if (buf.len == 0) return;

        const parsed = std.json.parseFromSlice(HistoryJson, allocator, buf, .{}) catch return;
        defer parsed.deinit();

        for (parsed.value.commands) |cmd| {
            self.commands.add(cmd);
        }
        for (parsed.value.searches) |search| {
            self.searches.add(search);
        }
    }

    pub fn get_default_path(allocator: Allocator) ![:0]u8 {
        if (getenv("XDG_STATE_HOME")) |state_home| {
            return try std.fs.path.joinZ(allocator, &[_][]const u8{ std.mem.span(state_home), "electronic_macdonalds", "history.json" });
        }
        if (getenv("HOME")) |home| {
            return try std.fs.path.joinZ(allocator, &[_][]const u8{ std.mem.span(home), ".local", "state", "electronic_macdonalds", "history.json" });
        }
        return try allocator.dupeZ(u8, "history.json");
    }
};

const testing = std.testing;

test "test_history_add_and_consecutive_dedup" {
    var cat = HistoryCategory{};
    cat.add("w");
    cat.add("w"); // duplicate ignored
    cat.add("wq");
    cat.add("wq"); // duplicate ignored
    cat.add("w"); // non-consecutive duplicate allowed

    try testing.expectEqual(@as(usize, 3), cat.count);
    try testing.expectEqualStrings("w", cat.get(0).?);
    try testing.expectEqualStrings("wq", cat.get(1).?);
    try testing.expectEqualStrings("w", cat.get(2).?);
}

test "test_history_navigate_up_down_and_draft" {
    var cat = HistoryCategory{};
    cat.add("cmd1");
    cat.add("cmd2");
    cat.add("cmd3");

    // Starting from empty in-progress draft ""
    const up1 = cat.navigate_up("");
    try testing.expectEqualStrings("cmd3", up1.?);

    const up2 = cat.navigate_up("");
    try testing.expectEqualStrings("cmd2", up2.?);

    const up3 = cat.navigate_up("");
    try testing.expectEqualStrings("cmd1", up3.?);

    // Oldest reached -> navigate_up returns null
    try testing.expect(cat.navigate_up("") == null);

    // Navigate back down
    const down1 = cat.navigate_down();
    try testing.expectEqualStrings("cmd2", down1.?);

    const down2 = cat.navigate_down();
    try testing.expectEqualStrings("cmd3", down2.?);

    // Returning to present restores draft
    const down3 = cat.navigate_down();
    try testing.expectEqualStrings("", down3.?);

    // Past present returns null
    try testing.expect(cat.navigate_down() == null);
}

test "test_history_prefix_matching" {
    var cat = HistoryCategory{};
    cat.add("edit main.zig");
    cat.add("write");
    cat.add("edit buffer.zig");
    cat.add("quit");

    // Typing "ed" prefix and navigating up should only recall "edit ..." commands
    const up1 = cat.navigate_up("ed");
    try testing.expectEqualStrings("edit buffer.zig", up1.?);

    const up2 = cat.navigate_up("ed");
    try testing.expectEqualStrings("edit main.zig", up2.?);

    try testing.expect(cat.navigate_up("ed") == null);

    // Down returns to "edit buffer.zig", then draft "ed"
    const down1 = cat.navigate_down();
    try testing.expectEqualStrings("edit buffer.zig", down1.?);

    const down2 = cat.navigate_down();
    try testing.expectEqualStrings("ed", down2.?);
}

test "test_history_json_serialization_roundtrip" {
    const tmp_path = "history_test_roundtrip.json";
    defer Io.Dir.cwd().deleteFile(testing.io, tmp_path) catch {};

    var store = HistoryStore{};
    store.commands.add("w /tmp/test.txt");
    store.commands.add("%s/foo/bar/g");
    store.searches.add("needle");
    store.searches.add("function_name");

    try store.save_to_file(testing.allocator, tmp_path);

    var loaded = HistoryStore{};
    try loaded.load_from_file(testing.allocator, tmp_path);

    try testing.expectEqual(@as(usize, 2), loaded.commands.count);
    try testing.expectEqualStrings("w /tmp/test.txt", loaded.commands.get(0).?);
    try testing.expectEqualStrings("%s/foo/bar/g", loaded.commands.get(1).?);

    try testing.expectEqual(@as(usize, 2), loaded.searches.count);
    try testing.expectEqualStrings("needle", loaded.searches.get(0).?);
    try testing.expectEqualStrings("function_name", loaded.searches.get(1).?);
}
