const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
};

pub const Rule = struct {
    pattern: []u8,
    base_rel: []u8,
    is_negated: bool,
    dir_only: bool,
    anchored: bool,
};

pub const IgnoreMatcher = struct {
    allocator: Allocator,
    rules: std.ArrayList(Rule),

    pub fn init(allocator: Allocator) IgnoreMatcher {
        return .{
            .allocator = allocator,
            .rules = .empty,
        };
    }

    pub fn deinit(self: *IgnoreMatcher) void {
        for (self.rules.items) |r| {
            self.allocator.free(r.pattern);
            self.allocator.free(r.base_rel);
        }
        self.rules.deinit(self.allocator);
    }

    pub fn clone(self: *const IgnoreMatcher) Error!IgnoreMatcher {
        var copy = IgnoreMatcher.init(self.allocator);
        errdefer copy.deinit();

        try copy.rules.ensureTotalCapacity(self.allocator, self.rules.items.len);
        for (self.rules.items) |r| {
            const pat = try self.allocator.dupe(u8, r.pattern);
            errdefer self.allocator.free(pat);
            const base = try self.allocator.dupe(u8, r.base_rel);
            errdefer self.allocator.free(base);

            copy.rules.appendAssumeCapacity(.{
                .pattern = pat,
                .base_rel = base,
                .is_negated = r.is_negated,
                .dir_only = r.dir_only,
                .anchored = r.anchored,
            });
        }
        return copy;
    }

    pub fn add_rules(self: *IgnoreMatcher, base_rel: []const u8, content: []const u8) Error!void {
        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            var slice = line;
            var is_negated = false;
            if (slice[0] == '!') {
                is_negated = true;
                slice = slice[1..];
                if (slice.len == 0) continue;
            }

            var dir_only = false;
            if (slice[slice.len - 1] == '/') {
                dir_only = true;
                slice = slice[0 .. slice.len - 1];
                if (slice.len == 0) continue;
            }

            var anchored = false;
            if (slice[0] == '/') {
                anchored = true;
                slice = slice[1..];
                if (slice.len == 0) continue;
            } else if (std.mem.indexOfScalar(u8, slice, '/') != null) {
                anchored = true;
            }

            const pat_copy = try self.allocator.dupe(u8, slice);
            errdefer self.allocator.free(pat_copy);
            const base_copy = try self.allocator.dupe(u8, base_rel);
            errdefer self.allocator.free(base_copy);

            try self.rules.append(self.allocator, .{
                .pattern = pat_copy,
                .base_rel = base_copy,
                .is_negated = is_negated,
                .dir_only = dir_only,
                .anchored = anchored,
            });
        }
    }

    pub fn is_ignored(self: *const IgnoreMatcher, rel_path: []const u8, is_dir: bool) bool {
        var ignored = false;
        for (self.rules.items) |rule| {
            if (match_rule(rule, rel_path, is_dir)) {
                ignored = !rule.is_negated;
            }
        }
        return ignored;
    }
};

pub fn is_always_ignored_name(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or std.mem.eql(u8, name, ".DS_Store");
}

fn match_rule(rule: Rule, rel_path: []const u8, is_dir: bool) bool {
    var sub_path = rel_path;
    if (rule.base_rel.len > 0) {
        if (!std.mem.startsWith(u8, rel_path, rule.base_rel)) return false;
        if (rel_path.len <= rule.base_rel.len or rel_path[rule.base_rel.len] != '/') return false;
        sub_path = rel_path[rule.base_rel.len + 1 ..];
    }

    if (rule.anchored) {
        if (!rule.dir_only) {
            if (glob_match(rule.pattern, sub_path)) return true;
        } else if (is_dir and glob_match(rule.pattern, sub_path)) {
            return true;
        }
        if (std.mem.startsWith(u8, sub_path, rule.pattern) and
            sub_path.len > rule.pattern.len and
            sub_path[rule.pattern.len] == '/')
        {
            return true;
        }
        return false;
    }

    var comp_iter = std.mem.splitScalar(u8, sub_path, '/');
    var remaining = sub_path;
    while (comp_iter.next()) |comp| {
        const is_last = (comp.ptr + comp.len == sub_path.ptr + sub_path.len);
        const comp_is_dir = if (is_last) is_dir else true;
        if (!rule.dir_only or comp_is_dir) {
            if (glob_match(rule.pattern, comp)) return true;
        }
        if (remaining.len > comp.len) {
            remaining = remaining[comp.len + 1 ..];
        }
    }
    return false;
}

pub fn glob_match(pattern: []const u8, text: []const u8) bool {
    var p_idx: usize = 0;
    var t_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (t_idx < text.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == '?' or pattern[p_idx] == text[t_idx])) {
            p_idx += 1;
            t_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            star_idx = p_idx;
            match_idx = t_idx;
            p_idx += 1;
        } else if (star_idx) |s_idx| {
            p_idx = s_idx + 1;
            match_idx += 1;
            t_idx = match_idx;
        } else {
            return false;
        }
    }

    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

test "test_ignore_parse_and_match_basic_globs" {
    const allocator = std.testing.allocator;
    var matcher = IgnoreMatcher.init(allocator);
    defer matcher.deinit();

    try matcher.add_rules("", "*.o\nbuild/\nnode_modules\n");

    try std.testing.expect(matcher.is_ignored("src/main.o", false));
    try std.testing.expect(matcher.is_ignored("build", true));
    try std.testing.expect(matcher.is_ignored("build/app", false));
    try std.testing.expect(matcher.is_ignored("node_modules", true));
    try std.testing.expect(!matcher.is_ignored("src/main.zig", false));
}

test "test_ignore_comments_blank_lines_and_negation" {
    const allocator = std.testing.allocator;
    var matcher = IgnoreMatcher.init(allocator);
    defer matcher.deinit();

    try matcher.add_rules("", "# comment\n\n*.log\n!important.log\n");

    try std.testing.expect(matcher.is_ignored("debug.log", false));
    try std.testing.expect(matcher.is_ignored("sub/error.log", false));
    try std.testing.expect(!matcher.is_ignored("important.log", false));
    try std.testing.expect(!matcher.is_ignored("# comment", false));
}

test "test_ignore_anchored_and_nested_paths" {
    const allocator = std.testing.allocator;
    var matcher = IgnoreMatcher.init(allocator);
    defer matcher.deinit();

    try matcher.add_rules("", "/root_only.txt\nany_level.txt\n");

    try std.testing.expect(matcher.is_ignored("root_only.txt", false));
    try std.testing.expect(!matcher.is_ignored("sub/root_only.txt", false));
    try std.testing.expect(matcher.is_ignored("any_level.txt", false));
    try std.testing.expect(matcher.is_ignored("sub/any_level.txt", false));
}

test "test_ignore_always_skips_dot_git" {
    try std.testing.expect(is_always_ignored_name(".git"));
    try std.testing.expect(!is_always_ignored_name(".gitignore"));
    try std.testing.expect(!is_always_ignored_name("src"));
}
