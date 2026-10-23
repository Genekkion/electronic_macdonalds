const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ignore_mod = @import("ignore.zig");
const IgnoreMatcher = ignore_mod.IgnoreMatcher;

pub const Error = Io.Dir.OpenError || Io.Dir.Reader.Error || Io.File.OpenError || Io.File.ReadPositionalError || Allocator.Error || Io.Cancelable;

const max_gitignore_bytes = 64 * 1024;
const max_grep_file_bytes = 8 * 1024 * 1024;
const binary_sniff_bytes = 4096;
const max_line_preview_bytes = 512;

pub const FindOptions = struct {
    root_path: []const u8 = ".",
    query: []const u8 = "",
    hidden: bool = true,
    ignored: bool = false,
    max_results: usize = 5000,
};

pub const GrepOptions = struct {
    root_path: []const u8 = ".",
    pattern: []const u8 = "",
    hidden: bool = true,
    ignored: bool = false,
    max_results: usize = 2000,
};

pub const GrepMatch = struct {
    path: []u8,
    line: usize,
    col: usize,
    text: []u8,
};

const FindContext = struct {
    io: Io,
    allocator: Allocator,
    opts: FindOptions,
    group: Io.Group,
    mutex: Io.Mutex,
    stop: std.atomic.Value(bool),
    results: std.ArrayList([]u8),
};

const GrepContext = struct {
    io: Io,
    allocator: Allocator,
    opts: GrepOptions,
    case_sensitive: bool,
    group: Io.Group,
    mutex: Io.Mutex,
    stop: std.atomic.Value(bool),
    results: std.ArrayList(GrepMatch),
};

pub fn find_files(io: Io, allocator: Allocator, opts: FindOptions) Error![][]u8 {
    if (opts.max_results == 0) return &.{};

    const root_dir = try open_target_dir(io, opts.root_path);

    var ctx = FindContext{
        .io = io,
        .allocator = allocator,
        .opts = opts,
        .group = .init,
        .mutex = .init,
        .stop = .init(false),
        .results = .empty,
    };
    errdefer {
        for (ctx.results.items) |item| allocator.free(item);
        ctx.results.deinit(allocator);
    }

    const root_rel = try allocator.dupe(u8, "");
    const root_matcher = IgnoreMatcher.init(allocator);

    ctx.group.async(io, find_dir_worker, .{ &ctx, root_dir, root_rel, root_matcher });
    try ctx.group.await(io);

    const slice = try ctx.results.toOwnedSlice(allocator);
    std.mem.sort([]u8, slice, {}, less_than_str);
    return slice;
}

pub fn free_file_list(allocator: Allocator, list: [][]u8) void {
    for (list) |item| {
        allocator.free(item);
    }
    if (list.len > 0) {
        allocator.free(list);
    }
}

pub fn live_grep(io: Io, allocator: Allocator, opts: GrepOptions) Error![]GrepMatch {
    if (opts.pattern.len == 0 or opts.max_results == 0) return &.{};

    const root_dir = try open_target_dir(io, opts.root_path);

    var ctx = GrepContext{
        .io = io,
        .allocator = allocator,
        .opts = opts,
        .case_sensitive = has_uppercase(opts.pattern),
        .group = .init,
        .mutex = .init,
        .stop = .init(false),
        .results = .empty,
    };
    errdefer {
        for (ctx.results.items) |m| {
            allocator.free(m.path);
            allocator.free(m.text);
        }
        ctx.results.deinit(allocator);
    }

    const root_rel = try allocator.dupe(u8, "");
    const root_matcher = IgnoreMatcher.init(allocator);

    ctx.group.async(io, grep_dir_worker, .{ &ctx, root_dir, root_rel, root_matcher });
    try ctx.group.await(io);

    const slice = try ctx.results.toOwnedSlice(allocator);
    std.mem.sort(GrepMatch, slice, {}, less_than_grep_match);
    return slice;
}

pub fn free_grep_matches(allocator: Allocator, matches: []GrepMatch) void {
    for (matches) |m| {
        allocator.free(m.path);
        allocator.free(m.text);
    }
    if (matches.len > 0) {
        allocator.free(matches);
    }
}

fn open_target_dir(io: Io, root_path: []const u8) Io.Dir.OpenError!Io.Dir {
    const clean_path = if (root_path.len == 0) "." else root_path;
    return Io.Dir.cwd().openDir(io, clean_path, .{
        .iterate = true,
        .access_sub_paths = true,
    });
}

fn load_dir_gitignore(io: Io, dir: Io.Dir, rel_prefix: []const u8, matcher: *IgnoreMatcher) void {
    var buf: [max_gitignore_bytes]u8 = undefined;
    const rule_files = [_][]const u8{
        ".git/info/exclude",
        ".gitignore",
        ".ignore",
    };
    for (rule_files) |sub_path| {
        if (dir.readFile(io, sub_path, &buf)) |content| {
            matcher.add_rules(rel_prefix, content) catch {};
        } else |_| {}
    }
}

fn join_rel_path(allocator: Allocator, prefix: []const u8, name: []const u8) Allocator.Error![]u8 {
    if (prefix.len == 0) {
        return allocator.dupe(u8, name);
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
}

fn find_dir_worker(ctx: *FindContext, dir_val: Io.Dir, rel_prefix: []u8, matcher_val: IgnoreMatcher) Io.Cancelable!void {
    var dir = dir_val;
    defer dir.close(ctx.io);
    defer ctx.allocator.free(rel_prefix);

    var matcher = matcher_val;
    defer matcher.deinit();

    if (ctx.stop.load(.acquire)) return;

    if (!ctx.opts.ignored) {
        load_dir_gitignore(ctx.io, dir, rel_prefix, &matcher);
    }

    var iter = dir.iterate();
    while (iter.next(ctx.io) catch null) |entry| {
        if (ctx.stop.load(.acquire)) break;
        if (ignore_mod.is_always_ignored_name(entry.name)) continue;
        if (!ctx.opts.hidden and entry.name.len > 0 and entry.name[0] == '.') continue;

        const entry_rel = join_rel_path(ctx.allocator, rel_prefix, entry.name) catch continue;
        const is_dir = (entry.kind == .directory);

        if (!ctx.opts.ignored and matcher.is_ignored(entry_rel, is_dir)) {
            ctx.allocator.free(entry_rel);
            continue;
        }

        switch (entry.kind) {
            .directory => {
                const sub_dir = dir.openDir(ctx.io, entry.name, .{
                    .iterate = true,
                    .access_sub_paths = true,
                }) catch {
                    ctx.allocator.free(entry_rel);
                    continue;
                };
                const cloned_matcher = matcher.clone() catch {
                    var sd = sub_dir;
                    sd.close(ctx.io);
                    ctx.allocator.free(entry_rel);
                    continue;
                };
                ctx.group.async(ctx.io, find_dir_worker, .{ ctx, sub_dir, entry_rel, cloned_matcher });
            },
            .file, .sym_link => {
                if (ctx.opts.query.len > 0 and !matches_query(entry_rel, ctx.opts.query)) {
                    ctx.allocator.free(entry_rel);
                    continue;
                }
                ctx.mutex.lockUncancelable(ctx.io);
                defer ctx.mutex.unlock(ctx.io);

                if (ctx.results.items.len >= ctx.opts.max_results) {
                    ctx.stop.store(true, .release);
                    ctx.allocator.free(entry_rel);
                    break;
                }
                ctx.results.append(ctx.allocator, entry_rel) catch {
                    ctx.allocator.free(entry_rel);
                    continue;
                };
                if (ctx.results.items.len >= ctx.opts.max_results) {
                    ctx.stop.store(true, .release);
                    break;
                }
            },
            else => {
                ctx.allocator.free(entry_rel);
            },
        }
    }
}

fn grep_dir_worker(ctx: *GrepContext, dir_val: Io.Dir, rel_prefix: []u8, matcher_val: IgnoreMatcher) Io.Cancelable!void {
    var dir = dir_val;
    defer dir.close(ctx.io);
    defer ctx.allocator.free(rel_prefix);

    var matcher = matcher_val;
    defer matcher.deinit();

    if (ctx.stop.load(.acquire)) return;

    if (!ctx.opts.ignored) {
        load_dir_gitignore(ctx.io, dir, rel_prefix, &matcher);
    }

    var iter = dir.iterate();
    while (iter.next(ctx.io) catch null) |entry| {
        if (ctx.stop.load(.acquire)) break;
        if (ignore_mod.is_always_ignored_name(entry.name)) continue;
        if (!ctx.opts.hidden and entry.name.len > 0 and entry.name[0] == '.') continue;

        const entry_rel = join_rel_path(ctx.allocator, rel_prefix, entry.name) catch continue;
        const is_dir = (entry.kind == .directory);

        if (!ctx.opts.ignored and matcher.is_ignored(entry_rel, is_dir)) {
            ctx.allocator.free(entry_rel);
            continue;
        }

        switch (entry.kind) {
            .directory => {
                const sub_dir = dir.openDir(ctx.io, entry.name, .{
                    .iterate = true,
                    .access_sub_paths = true,
                }) catch {
                    ctx.allocator.free(entry_rel);
                    continue;
                };
                const cloned_matcher = matcher.clone() catch {
                    var sd = sub_dir;
                    sd.close(ctx.io);
                    ctx.allocator.free(entry_rel);
                    continue;
                };
                ctx.group.async(ctx.io, grep_dir_worker, .{ ctx, sub_dir, entry_rel, cloned_matcher });
            },
            .file => {
                defer ctx.allocator.free(entry_rel);
                grep_single_file(ctx, dir, entry.name, entry_rel);
            },
            else => {
                ctx.allocator.free(entry_rel);
            },
        }
    }
}

fn grep_single_file(ctx: *GrepContext, dir: Io.Dir, sub_name: []const u8, entry_rel: []const u8) void {
    if (ctx.stop.load(.acquire)) return;

    var file = dir.openFile(ctx.io, sub_name, .{}) catch return;
    defer file.close(ctx.io);

    const file_len = file.length(ctx.io) catch return;
    if (file_len == 0 or file_len > max_grep_file_bytes) return;

    var sniff_buf: [binary_sniff_bytes]u8 = undefined;
    const sniff_n = file.readPositional(ctx.io, &.{&sniff_buf}, 0) catch return;
    if (sniff_n == 0) return;

    if (std.mem.indexOfScalar(u8, sniff_buf[0..sniff_n], 0) != null) return;

    if (file_len <= sniff_n) {
        scan_buffer_lines(ctx, entry_rel, sniff_buf[0..sniff_n]);
        return;
    }

    const total_len: usize = @intCast(file_len);
    const full_buf = ctx.allocator.alloc(u8, total_len) catch return;
    defer ctx.allocator.free(full_buf);

    @memcpy(full_buf[0..sniff_n], sniff_buf[0..sniff_n]);
    const rest_n = file.readPositionalAll(ctx.io, full_buf[sniff_n..], sniff_n) catch return;
    const valid_buf = full_buf[0 .. sniff_n + rest_n];

    scan_buffer_lines(ctx, entry_rel, valid_buf);
}

fn scan_buffer_lines(ctx: *GrepContext, entry_rel: []const u8, content: []const u8) void {
    var line_num: usize = 1;
    var start: usize = 0;

    while (start < content.len) {
        if (ctx.stop.load(.acquire)) return;

        const nl_pos = std.mem.indexOfScalarPos(u8, content, start, '\n');
        const end = nl_pos orelse content.len;
        var line = content[start..end];
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        if (find_pattern(line, ctx.opts.pattern, ctx.case_sensitive)) |col_idx| {
            const preview_len = @min(line.len, max_line_preview_bytes);
            const path_copy = ctx.allocator.dupe(u8, entry_rel) catch return;
            const text_copy = ctx.allocator.dupe(u8, line[0..preview_len]) catch {
                ctx.allocator.free(path_copy);
                return;
            };

            ctx.mutex.lockUncancelable(ctx.io);
            if (ctx.results.items.len >= ctx.opts.max_results) {
                ctx.stop.store(true, .release);
                ctx.mutex.unlock(ctx.io);
                ctx.allocator.free(path_copy);
                ctx.allocator.free(text_copy);
                return;
            }
            ctx.results.append(ctx.allocator, .{
                .path = path_copy,
                .line = line_num,
                .col = col_idx + 1,
                .text = text_copy,
            }) catch {
                ctx.mutex.unlock(ctx.io);
                ctx.allocator.free(path_copy);
                ctx.allocator.free(text_copy);
                return;
            };
            if (ctx.results.items.len >= ctx.opts.max_results) {
                ctx.stop.store(true, .release);
            }
            ctx.mutex.unlock(ctx.io);
        }

        start = end + 1;
        line_num += 1;
    }
}

fn has_uppercase(s: []const u8) bool {
    for (s) |ch| {
        if (ch >= 'A' and ch <= 'Z') return true;
    }
    return false;
}

fn find_pattern(haystack: []const u8, needle: []const u8, case_sensitive: bool) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    if (case_sensitive) {
        return std.mem.indexOf(u8, haystack, needle);
    }

    const first_lower = std.ascii.toLower(needle[0]);
    const first_upper = std.ascii.toUpper(needle[0]);
    const limit = haystack.len - needle.len + 1;
    var i: usize = 0;

    while (i < limit) : (i += 1) {
        const ch = haystack[i];
        if (ch != first_lower and ch != first_upper) continue;
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            return i;
        }
    }
    return null;
}

pub fn matches_query(candidate: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (find_pattern(candidate, query, false) != null) return true;

    var q_idx: usize = 0;
    for (candidate) |ch| {
        if (std.ascii.toLower(ch) == std.ascii.toLower(query[q_idx])) {
            q_idx += 1;
            if (q_idx == query.len) return true;
        }
    }
    return false;
}

fn less_than_str(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn less_than_grep_match(_: void, a: GrepMatch, b: GrepMatch) bool {
    const cmp = std.mem.order(u8, a.path, b.path);
    if (cmp != .eq) return cmp == .lt;
    if (a.line != b.line) return a.line < b.line;
    return a.col < b.col;
}

fn make_tmp_root_path(allocator: Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

fn contains_str(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

test "test_find_files_happy_path_recursive" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sub/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const a = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/b.zig", .data = "const b = 2;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/deep/c.lua", .data = "return {}\n" });

    const root_path = try make_tmp_root_path(allocator, &tmp);
    defer allocator.free(root_path);

    const files = try find_files(io, allocator, .{
        .root_path = root_path,
        .hidden = false,
        .ignored = false,
    });
    defer free_file_list(allocator, files);

    try std.testing.expectEqual(@as(usize, 3), files.len);
    try std.testing.expect(contains_str(files, "a.zig"));
    try std.testing.expect(contains_str(files, "sub/b.zig"));
    try std.testing.expect(contains_str(files, "sub/deep/c.lua"));
}

test "test_find_files_hidden_and_gitignore_filtering" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "[core]\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "ignored.txt\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "SECRET=1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "visible.txt", .data = "ok\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ignored.txt", .data = "skip\n" });

    const root_path = try make_tmp_root_path(allocator, &tmp);
    defer allocator.free(root_path);

    const files_no_hidden = try find_files(io, allocator, .{
        .root_path = root_path,
        .hidden = false,
        .ignored = false,
    });
    defer free_file_list(allocator, files_no_hidden);

    try std.testing.expectEqual(@as(usize, 1), files_no_hidden.len);
    try std.testing.expectEqualStrings("visible.txt", files_no_hidden[0]);

    const files_with_hidden = try find_files(io, allocator, .{
        .root_path = root_path,
        .hidden = true,
        .ignored = false,
    });
    defer free_file_list(allocator, files_with_hidden);

    try std.testing.expectEqual(@as(usize, 3), files_with_hidden.len);
    try std.testing.expect(contains_str(files_with_hidden, ".env"));
    try std.testing.expect(contains_str(files_with_hidden, ".gitignore"));
    try std.testing.expect(contains_str(files_with_hidden, "visible.txt"));
    try std.testing.expect(!contains_str(files_with_hidden, ".git/config"));
}

test "test_find_files_query_fuzzy_and_substring_filter" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src/input");
    try tmp.dir.createDirPath(io, "src/lua");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/input/vim.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/lua/config.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "" });

    const root_path = try make_tmp_root_path(allocator, &tmp);
    defer allocator.free(root_path);

    const files = try find_files(io, allocator, .{
        .root_path = root_path,
        .query = "vim",
        .hidden = false,
        .ignored = false,
    });
    defer free_file_list(allocator, files);

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("src/input/vim.zig", files[0]);
}

test "test_live_grep_happy_path_multiline" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "alpha.txt",
        .data = "hello world\nfoo bar\n  hello zig\n",
    });

    const root_path = try make_tmp_root_path(allocator, &tmp);
    defer allocator.free(root_path);

    const matches = try live_grep(io, allocator, .{
        .root_path = root_path,
        .pattern = "hello",
    });
    defer free_grep_matches(allocator, matches);

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("alpha.txt", matches[0].path);
    try std.testing.expectEqual(@as(usize, 1), matches[0].line);
    try std.testing.expectEqual(@as(usize, 1), matches[0].col);
    try std.testing.expectEqualStrings("hello world", matches[0].text);

    try std.testing.expectEqualStrings("alpha.txt", matches[1].path);
    try std.testing.expectEqual(@as(usize, 3), matches[1].line);
    try std.testing.expectEqual(@as(usize, 3), matches[1].col);
    try std.testing.expectEqualStrings("  hello zig", matches[1].text);
}

test "test_live_grep_binary_file_instant_bailout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "bin.dat",
        .data = "ELF\x00binary_header\ntarget_needle\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "text.zig",
        .data = "const target_needle = 1;\n",
    });

    const root_path = try make_tmp_root_path(allocator, &tmp);
    defer allocator.free(root_path);

    const matches = try live_grep(io, allocator, .{
        .root_path = root_path,
        .pattern = "target_needle",
    });
    defer free_grep_matches(allocator, matches);

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("text.zig", matches[0].path);
}

test "test_live_grep_smart_case_sensitivity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "case.txt",
        .data = "Hello World\nhello world\n",
    });

    const root_path = try make_tmp_root_path(allocator, &tmp);
    defer allocator.free(root_path);

    const lower_matches = try live_grep(io, allocator, .{
        .root_path = root_path,
        .pattern = "hello",
    });
    defer free_grep_matches(allocator, lower_matches);
    try std.testing.expectEqual(@as(usize, 2), lower_matches.len);

    const upper_matches = try live_grep(io, allocator, .{
        .root_path = root_path,
        .pattern = "Hello",
    });
    defer free_grep_matches(allocator, upper_matches);
    try std.testing.expectEqual(@as(usize, 1), upper_matches.len);
    try std.testing.expectEqual(@as(usize, 1), upper_matches[0].line);
}

test "test_search_empty_directory_and_empty_files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try make_tmp_root_path(allocator, &tmp);
    defer allocator.free(root_path);

    const empty_files = try find_files(io, allocator, .{ .root_path = root_path });
    defer free_file_list(allocator, empty_files);
    try std.testing.expectEqual(@as(usize, 0), empty_files.len);

    try tmp.dir.writeFile(io, .{ .sub_path = "zero.txt", .data = "" });

    const files_with_zero = try find_files(io, allocator, .{ .root_path = root_path });
    defer free_file_list(allocator, files_with_zero);
    try std.testing.expectEqual(@as(usize, 1), files_with_zero.len);

    const grep_zero = try live_grep(io, allocator, .{
        .root_path = root_path,
        .pattern = "anything",
    });
    defer free_grep_matches(allocator, grep_zero);
    try std.testing.expectEqual(@as(usize, 0), grep_zero.len);
}

test "test_live_grep_empty_pattern_returns_empty" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "some content\n" });

    const root_path = try make_tmp_root_path(allocator, &tmp);
    defer allocator.free(root_path);

    const matches = try live_grep(io, allocator, .{
        .root_path = root_path,
        .pattern = "",
    });
    defer free_grep_matches(allocator, matches);
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "test_search_nonexistent_directory_error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    try std.testing.expectError(error.FileNotFound, find_files(io, allocator, .{
        .root_path = "/nonexistent_dir_electronic_macdonalds_99999",
    }));
}

test "test_search_max_results_boundary_cap" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "many.txt",
        .data = "match 1\nmatch 2\nmatch 3\nmatch 4\nmatch 5\nmatch 6\nmatch 7\nmatch 8\nmatch 9\nmatch 10\n",
    });

    const root_path = try make_tmp_root_path(allocator, &tmp);
    defer allocator.free(root_path);

    const matches = try live_grep(io, allocator, .{
        .root_path = root_path,
        .pattern = "match",
        .max_results = 5,
    });
    defer free_grep_matches(allocator, matches);

    try std.testing.expectEqual(@as(usize, 5), matches.len);
}

test "test_live_grep_no_trailing_newline_and_long_lines" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "tail.txt",
        .data = "first line\nlast_line_match",
    });

    const root_path = try make_tmp_root_path(allocator, &tmp);
    defer allocator.free(root_path);

    const matches = try live_grep(io, allocator, .{
        .root_path = root_path,
        .pattern = "last_line_match",
    });
    defer free_grep_matches(allocator, matches);

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(usize, 2), matches[0].line);
    try std.testing.expectEqual(@as(usize, 1), matches[0].col);
    try std.testing.expectEqualStrings("last_line_match", matches[0].text);
}

test "test_search_respects_git_info_exclude_and_dot_ignore" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".git/info");
    try tmp.dir.createDirPath(io, "workspace/lazy");
    try tmp.dir.createDirPath(io, "src");

    try tmp.dir.writeFile(io, .{ .sub_path = ".git/info/exclude", .data = "# comment\nworkspace/\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".ignore", .data = "scratch.txt\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "workspace/lazy/plugin.lua", .data = "local secret_token = 1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "scratch.txt", .data = "secret_token\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "const secret_token = 2;\n" });

    const root_path = try make_tmp_root_path(allocator, &tmp);
    defer allocator.free(root_path);

    const files_filtered = try find_files(io, allocator, .{
        .root_path = root_path,
        .hidden = false,
        .ignored = false,
    });
    defer free_file_list(allocator, files_filtered);

    try std.testing.expectEqual(@as(usize, 1), files_filtered.len);
    try std.testing.expectEqualStrings("src/main.zig", files_filtered[0]);

    const grep_filtered = try live_grep(io, allocator, .{
        .root_path = root_path,
        .pattern = "secret_token",
        .hidden = false,
        .ignored = false,
    });
    defer free_grep_matches(allocator, grep_filtered);

    try std.testing.expectEqual(@as(usize, 1), grep_filtered.len);
    try std.testing.expectEqualStrings("src/main.zig", grep_filtered[0].path);

    const files_unfiltered = try find_files(io, allocator, .{
        .root_path = root_path,
        .hidden = false,
        .ignored = true,
    });
    defer free_file_list(allocator, files_unfiltered);

    try std.testing.expectEqual(@as(usize, 3), files_unfiltered.len);
}

