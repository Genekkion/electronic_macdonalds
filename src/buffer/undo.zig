const std = @import("std");
const Allocator = std.mem.Allocator;

extern "c" fn time(arg: ?*anyopaque) i64;

pub const ChangeDelta = struct {
    offset: usize,
    inserted: []const u8,
    deleted: []const u8,
};

pub const UndoNode = struct {
    seq: u64,
    parent: ?*UndoNode,
    children: std.ArrayList(*UndoNode),
    delta: ChangeDelta,
    cursor_line: usize,
    cursor_col: usize,
    timestamp: i64,

    pub fn deinit(self: *UndoNode, allocator: Allocator) void {
        if (self.delta.inserted.len > 0) allocator.free(self.delta.inserted);
        if (self.delta.deleted.len > 0) allocator.free(self.delta.deleted);
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit(allocator);
    }
};

pub const UndoTree = struct {
    allocator: Allocator,
    root: *UndoNode,
    current: *UndoNode,
    next_seq: u64,
    saved_seq: ?u64,
    all_nodes: std.AutoHashMap(u64, *UndoNode),

    pub fn init(allocator: Allocator) !UndoTree {
        const root_node = try allocator.create(UndoNode);
        root_node.* = .{
            .seq = 0,
            .parent = null,
            .children = .empty,
            .delta = .{ .offset = 0, .inserted = "", .deleted = "" },
            .cursor_line = 0,
            .cursor_col = 0,
            .timestamp = time(null),
        };
        var map = std.AutoHashMap(u64, *UndoNode).init(allocator);
        try map.put(0, root_node);

        return .{
            .allocator = allocator,
            .root = root_node,
            .current = root_node,
            .next_seq = 1,
            .saved_seq = 0,
            .all_nodes = map,
        };
    }

    pub fn deinit(self: *UndoTree) void {
        self.root.deinit(self.allocator);
        self.allocator.destroy(self.root);
        self.all_nodes.deinit();
    }

    pub fn add_change(
        self: *UndoTree,
        offset: usize,
        inserted: []const u8,
        deleted: []const u8,
        cursor_line: usize,
        cursor_col: usize,
    ) !*UndoNode {
        const ins_dup = try self.allocator.dupe(u8, inserted);
        errdefer self.allocator.free(ins_dup);
        const del_dup = try self.allocator.dupe(u8, deleted);
        errdefer self.allocator.free(del_dup);

        const node = try self.allocator.create(UndoNode);
        node.* = .{
            .seq = self.next_seq,
            .parent = self.current,
            .children = .empty,
            .delta = .{
                .offset = offset,
                .inserted = ins_dup,
                .deleted = del_dup,
            },
            .cursor_line = cursor_line,
            .cursor_col = cursor_col,
            .timestamp = time(null),
        };
        self.next_seq += 1;

        try self.current.children.append(self.allocator, node);
        try self.all_nodes.put(node.seq, node);
        self.current = node;
        return node;
    }

    pub const StepAction = struct {
        offset: usize,
        delete_len: usize,
        insert_text: []const u8,
        cursor_line: usize,
        cursor_col: usize,
    };

    pub fn undo(self: *UndoTree) ?StepAction {
        if (self.current.parent) |parent| {
            const node = self.current;
            self.current = parent;

            return .{
                .offset = node.delta.offset,
                .delete_len = node.delta.inserted.len,
                .insert_text = node.delta.deleted,
                .cursor_line = parent.cursor_line,
                .cursor_col = parent.cursor_col,
            };
        }
        return null;
    }

    pub fn redo(self: *UndoTree) ?StepAction {
        if (self.current.children.items.len > 0) {
            // Traverse down active/most recent child branch
            const node = self.current.children.items[self.current.children.items.len - 1];
            self.current = node;

            return .{
                .offset = node.delta.offset,
                .delete_len = node.delta.deleted.len,
                .insert_text = node.delta.inserted,
                .cursor_line = node.cursor_line,
                .cursor_col = node.cursor_col,
            };
        }
        return null;
    }

    pub fn is_at_save_point(self: *const UndoTree) bool {
        if (self.saved_seq) |s| {
            return self.current.seq == s;
        }
        return false;
    }

    pub fn mark_saved(self: *UndoTree) void {
        self.saved_seq = self.current.seq;
    }

    pub fn get_node(self: *const UndoTree, seq: u64) ?*UndoNode {
        return self.all_nodes.get(seq);
    }
};

const testing = std.testing;

test "test_undo_linear_insert_delete" {
    var tree = try UndoTree.init(testing.allocator);
    defer tree.deinit();

    _ = try tree.add_change(0, "hello", "", 0, 5);
    try testing.expectEqual(@as(u64, 1), tree.current.seq);

    const undo_step = tree.undo();
    try testing.expect(undo_step != null);
    try testing.expectEqual(@as(usize, 0), undo_step.?.offset);
    try testing.expectEqual(@as(usize, 5), undo_step.?.delete_len);
    try testing.expectEqualStrings("", undo_step.?.insert_text);
    try testing.expectEqual(@as(u64, 0), tree.current.seq);

    const redo_step = tree.redo();
    try testing.expect(redo_step != null);
    try testing.expectEqual(@as(usize, 0), redo_step.?.offset);
    try testing.expectEqual(@as(usize, 0), redo_step.?.delete_len);
    try testing.expectEqualStrings("hello", redo_step.?.insert_text);
    try testing.expectEqual(@as(u64, 1), tree.current.seq);
}

test "test_undo_tree_branching_and_redo" {
    var tree = try UndoTree.init(testing.allocator);
    defer tree.deinit();

    // Change A: insert "A"
    const node_a = try tree.add_change(0, "A", "", 0, 1);
    // Change B: insert "B"
    _ = try tree.add_change(1, "B", "", 0, 2);

    // Undo B back to A
    _ = tree.undo();
    try testing.expectEqual(node_a.seq, tree.current.seq);

    // Change C: insert "C" (diverges from A, creating second child branch of A)
    const node_c = try tree.add_change(1, "C", "", 0, 2);

    // Node A now has 2 children: B and C
    try testing.expectEqual(@as(usize, 2), node_a.children.items.len);
    try testing.expectEqual(node_c.seq, tree.current.seq);

    // Undo C back to A
    _ = tree.undo();
    try testing.expectEqual(node_a.seq, tree.current.seq);

    // Redo takes the most recent branch (C)
    const redo_step = tree.redo();
    try testing.expect(redo_step != null);
    try testing.expectEqualStrings("C", redo_step.?.insert_text);
    try testing.expectEqual(node_c.seq, tree.current.seq);
}

test "test_undo_chronological_time_travel" {
    var tree = try UndoTree.init(testing.allocator);
    defer tree.deinit();

    _ = try tree.add_change(0, "A", "", 0, 1); // seq 1
    _ = try tree.add_change(1, "B", "", 0, 2); // seq 2
    _ = tree.undo(); // back to seq 1
    _ = try tree.add_change(1, "C", "", 0, 2); // seq 3 (branch 2)

    // Lookup node by sequence number across branches
    const node2 = tree.get_node(2);
    try testing.expect(node2 != null);
    try testing.expectEqualStrings("B", node2.?.delta.inserted);

    const node3 = tree.get_node(3);
    try testing.expect(node3 != null);
    try testing.expectEqualStrings("C", node3.?.delta.inserted);
}
