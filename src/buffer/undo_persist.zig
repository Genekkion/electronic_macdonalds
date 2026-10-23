const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const undo = @import("undo.zig");
const UndoTree = undo.UndoTree;
const UndoNode = undo.UndoNode;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn default_io() Io {
    return Io.Threaded.global_single_threaded.io();
}

fn ensure_dir_recursive(path: []const u8) void {
    if (path.len == 0) return;
    Io.Dir.cwd().createDirPath(default_io(), path) catch {};
}

fn appendSliceBytes(comptime T: type, list: *std.ArrayList(u8), allocator: Allocator, slice: []const T) PersistError!void {
    const bytes = std.mem.sliceAsBytes(slice);
    list.appendSlice(allocator, bytes) catch return error.OutOfMemory;
}

fn readSliceFromCursor(comptime T: type, slice: []T, data: []const u8, cursor: *usize) bool {
    const out_bytes = std.mem.sliceAsBytes(slice);
    if (cursor.* + out_bytes.len > data.len) return false;
    @memcpy(out_bytes, data[cursor.* .. cursor.* + out_bytes.len]);
    cursor.* += out_bytes.len;
    return true
;
}

pub const MAGIC: [4]u8 = "EMUN".*;
pub const VERSION: u8 = 1;

pub const PersistError = error{
    FileOpenFailed,
    WriteFailed,
    ReadFailed,
    InvalidMagic,
    UnsupportedVersion,
    ChecksumMismatch,
    CorruptedData,
    OutOfMemory,
};

pub fn compute_sha256(data: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return hash;
}

pub fn get_undo_dir(allocator: Allocator) ![:0]const u8 {
    const home_c = getenv("HOME");
    const home = if (home_c) |h| std.mem.span(h) else "/tmp";
    const s = try std.fmt.allocPrint(allocator, "{s}/.local/state/electronic_macdonalds/undo", .{home});
    defer allocator.free(s);
    return try allocator.dupeZ(u8, s);
}

pub fn get_undo_path_for_file(allocator: Allocator, file_path: []const u8) ![:0]const u8 {
    const undo_dir = try get_undo_dir(allocator);
    defer allocator.free(undo_dir);

    ensure_dir_recursive(undo_dir);

    var escaped = try allocator.alloc(u8, file_path.len);
    defer allocator.free(escaped);
    for (file_path, 0..) |ch, i| {
        escaped[i] = if (ch == '/') '%' else ch;
    }

    const s = try std.fmt.allocPrint(allocator, "{s}/{s}.undo", .{ undo_dir, escaped });
    defer allocator.free(s);
    return try allocator.dupeZ(u8, s);
}

pub fn save_undo_file(
    tree: *const UndoTree,
    content: []const u8,
    save_path: [:0]const u8,
    allocator: Allocator,
) PersistError!void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    // 1. Write Header
    try appendSliceBytes(u8, &out, allocator, &MAGIC);
    const version = [_]u8{VERSION};
    try appendSliceBytes(u8, &out, allocator, &version);

    // 2. Write Checksum of current buffer content
    const hash = compute_sha256(content);
    try appendSliceBytes(u8, &out, allocator, &hash);

    // 3. Write Current seq and Saved seq
    const meta = [_]u64{ tree.current.seq, tree.saved_seq orelse 0 };
    try appendSliceBytes(u64, &out, allocator, &meta);

    // 4. Collect nodes (exclude root seq 0)
    const count = tree.all_nodes.count();
    const nodes = allocator.alloc(*UndoNode, count) catch return error.OutOfMemory;
    defer allocator.free(nodes);

    var it = tree.all_nodes.valueIterator();
    var idx: usize = 0;
    while (it.next()) |node_ptr| {
        nodes[idx] = node_ptr.*;
        idx += 1;
    }

    const sortFn = struct {
        fn lessThan(_: void, a: *UndoNode, b: *UndoNode) bool {
            return a.seq < b.seq;
        }
    }.lessThan;
    std.mem.sort(*UndoNode, nodes, {}, sortFn);

    var eligible_count: u32 = 0;
    for (nodes) |n| {
        if (n.seq > 0) eligible_count += 1;
    }

    const eligible_buf = [_]u32{eligible_count};
    try appendSliceBytes(u32, &out, allocator, &eligible_buf);

    // 5. Write each node
    for (nodes) |node| {
        if (node.seq == 0) continue;

        const parent_seq: u64 = if (node.parent) |p| p.seq else 0;
        const node_hdr = [_]u64{ node.seq, parent_seq, @intCast(node.timestamp) };
        try appendSliceBytes(u64, &out, allocator, &node_hdr);

        const cursors = [_]u32{
            @intCast(node.cursor_line),
            @intCast(node.cursor_col),
            @intCast(node.delta.offset),
            @intCast(node.delta.inserted.len),
            @intCast(node.delta.deleted.len),
        };
        try appendSliceBytes(u32, &out, allocator, &cursors);

        if (node.delta.inserted.len > 0) {
            try appendSliceBytes(u8, &out, allocator, node.delta.inserted);
        }
        if (node.delta.deleted.len > 0) {
            try appendSliceBytes(u8, &out, allocator, node.delta.deleted);
        }
    }

    Io.Dir.cwd().writeFile(default_io(), .{
        .sub_path = save_path,
        .data = out.items,
    }) catch return error.WriteFailed;
}

pub fn load_undo_file(
    tree: *UndoTree,
    content: []const u8,
    load_path: [:0]const u8,
    allocator: Allocator,
) PersistError!void {
    const file_bytes = Io.Dir.cwd().readFileAlloc(
        default_io(),
        load_path,
        allocator,
        .limited(32 * 1024 * 1024),
    ) catch return error.FileOpenFailed;
    defer allocator.free(file_bytes);

    var cursor: usize = 0;

    // 1. Read and verify Magic
    var magic: [4]u8 = undefined;
    if (!readSliceFromCursor(u8, &magic, file_bytes, &cursor)) return error.ReadFailed;
    if (!std.mem.eql(u8, &magic, &MAGIC)) return error.InvalidMagic;

    // 2. Read and verify Version
    var version: [1]u8 = undefined;
    if (!readSliceFromCursor(u8, &version, file_bytes, &cursor)) return error.ReadFailed;
    if (version[0] != VERSION) return error.UnsupportedVersion;

    // 3. Verify Checksum
    var stored_hash: [32]u8 = undefined;
    if (!readSliceFromCursor(u8, &stored_hash, file_bytes, &cursor)) return error.ReadFailed;
    const actual_hash = compute_sha256(content);
    if (!std.mem.eql(u8, &stored_hash, &actual_hash)) return error.ChecksumMismatch;

    // 4. Read Current and Saved seq
    var meta: [2]u64 = undefined;
    if (!readSliceFromCursor(u64, &meta, file_bytes, &cursor)) return error.ReadFailed;
    const cur_seq = meta[0];
    const saved_seq = meta[1];

    // 5. Read eligible count
    var count_buf: [1]u32 = undefined;
    if (!readSliceFromCursor(u32, &count_buf, file_bytes, &cursor)) return error.ReadFailed;
    const node_count = count_buf[0];

    // 6. Read each node and insert into tree
    var i: u32 = 0;
    while (i < node_count) : (i += 1) {
        var node_hdr: [3]u64 = undefined;
        if (!readSliceFromCursor(u64, &node_hdr, file_bytes, &cursor)) return error.ReadFailed;
        const seq = node_hdr[0];
        const parent_seq = node_hdr[1];
        const timestamp: i64 = @intCast(node_hdr[2]);

        var cursors: [5]u32 = undefined;
        if (!readSliceFromCursor(u32, &cursors, file_bytes, &cursor)) return error.ReadFailed;
        const line: usize = cursors[0];
        const col: usize = cursors[1];
        const offset: usize = cursors[2];
        const ins_len: usize = cursors[3];
        const del_len: usize = cursors[4];

        const ins_bytes = try allocator.alloc(u8, ins_len);
        errdefer allocator.free(ins_bytes);
        if (ins_len > 0) {
            if (!readSliceFromCursor(u8, ins_bytes, file_bytes, &cursor)) return error.ReadFailed;
        }

        const del_bytes = try allocator.alloc(u8, del_len);
        errdefer allocator.free(del_bytes);
        if (del_len > 0) {
            if (!readSliceFromCursor(u8, del_bytes, file_bytes, &cursor)) return error.ReadFailed;
        }

        const parent_node = tree.get_node(parent_seq) orelse tree.root;

        const new_node = try allocator.create(UndoNode);
        new_node.* = .{
            .seq = seq,
            .parent = parent_node,
            .children = .empty,
            .delta = .{
                .offset = offset,
                .inserted = ins_bytes,
                .deleted = del_bytes,
            },
            .cursor_line = line,
            .cursor_col = col,
            .timestamp = timestamp,
        };

        try parent_node.children.append(allocator, new_node);
        try tree.all_nodes.put(seq, new_node);
        if (seq >= tree.next_seq) {
            tree.next_seq = seq + 1;
        }
    }

    if (tree.get_node(cur_seq)) |active_node| {
        tree.current = active_node;
    }
    tree.saved_seq = saved_seq;
}

const testing = std.testing;

test "test_undo_persistence_roundtrip" {
    var tree = try UndoTree.init(testing.allocator);
    defer tree.deinit();

    _ = try tree.add_change(0, "first", "", 0, 5);
    _ = try tree.add_change(5, " second", "", 0, 12);
    _ = tree.undo();
    _ = try tree.add_change(5, " branched", "", 0, 14);

    const content = "first branched";
    const undo_path = "/tmp/em_test_undo_roundtrip.undo";
    defer Io.Dir.cwd().deleteFile(testing.io, undo_path) catch {};

    try save_undo_file(&tree, content, undo_path, testing.allocator);

    // Fresh tree loaded from undo file
    var loaded_tree = try UndoTree.init(testing.allocator);
    defer loaded_tree.deinit();

    try load_undo_file(&loaded_tree, content, undo_path, testing.allocator);

    // Check tree properties
    try testing.expectEqual(@as(u64, 3), loaded_tree.current.seq);
    try testing.expectEqual(@as(u64, 4), loaded_tree.next_seq);
    try testing.expectEqualStrings(" branched", loaded_tree.current.delta.inserted);

    // Verify parent of branch has 2 children (node 2 and node 3)
    const node1 = loaded_tree.get_node(1);
    try testing.expect(node1 != null);
    try testing.expectEqual(@as(usize, 2), node1.?.children.items.len);
}

test "test_undo_persistence_rejects_corrupted_checksum" {
    var tree = try UndoTree.init(testing.allocator);
    defer tree.deinit();

    _ = try tree.add_change(0, "data", "", 0, 4);

    const orig_content = "data";
    const undo_path = "/tmp/em_test_undo_checksum.undo";
    defer Io.Dir.cwd().deleteFile(testing.io, undo_path) catch {};

    try save_undo_file(&tree, orig_content, undo_path, testing.allocator);

    // Attempt to load with modified content
    var fresh_tree = try UndoTree.init(testing.allocator);
    defer fresh_tree.deinit();

    const tampered_content = "externally modified";
    const result = load_undo_file(&fresh_tree, tampered_content, undo_path, testing.allocator);
    try testing.expectError(error.ChecksumMismatch, result);
}

test "test_undo_path_resolution" {
    const file_path = "/Users/test/document.txt";
    const undo_path = try get_undo_path_for_file(testing.allocator, file_path);
    defer testing.allocator.free(undo_path);

    try testing.expect(std.mem.endsWith(u8, undo_path, "%Users%test%document.txt.undo"));
}
