# 0004: Non-Linear Undo Tree & Disk Persistence

## 1. Background / Context

Electronic Macdonalds currently executes direct, in-place gap buffer mutations on `insert` and `delete`. There is no undo or redo capability.

In standard modal editors (Vim/Neovim and Emacs with `undo-tree`), undo history is non-linear:
1. **Branching History**: Editing after an undo branches off as an alternative timeline rather than overwriting redo history.
2. **Coalesced Edits**: An entire Insert mode session or a single Normal mode command forms an atomic change block.
3. **Session Persistence**: When `undofile` is enabled, the in-memory undo tree is written to a designated cache directory upon buffer save (`:w`), allowing history to survive editor restarts.

---

## 2. Requirements / Goal

### 2.1 Desired Outcome
Provide a high-performance in-memory non-linear Undo Tree with atomic edit coalescing, Vim keybindings (`u`, `<C-r>`, `g-`, `g+`), dynamic `is_dirty` tracking, and automatic file-hash-validated disk persistence.

### 2.2 Functional Requirements

#### In-Memory Undo Tree
- **Tree Node Structure**:
  - Sequence number (`seq: u64`), parent pointer, list of children.
  - Forward and reverse deltas (offset, deleted text, inserted text).
  - Cursor snapshot associated with the edit.
  - Timestamp (`timestamp: i64`) for chronological navigation.
- **Edit Coalescing ("Debouncing")**:
  - Insert mode (`i`, `a`, `o`): Successive character insertions and backspaces are batched into a single `UndoNode` finalized upon `<Esc>`.
  - Normal mode (`x`, `dd`, `p`, etc.): Each command generates a single atomic `UndoNode`.
- **Navigation**:
  - `u`: Traverses up to `current.parent`, inverting the delta.
  - `<C-r>`: Traverses down to the most recently visited child branch.
  - `g-` / `g+`: Traverses backward / forward chronologically by `seq` across branches.
- **Dirty State Reconciliation**:
  - Tracks `saved_seq` (the sequence number when the buffer was last written to disk).
  - When undoing back to `saved_seq`, `buffer.is_dirty` automatically evaluates to `false`.

#### Query API (`editor.undo.tree()`)
- Exposes tree structure to Lua matching Neovim's `undotree()` schema for visualizers:
  - `seq_cur`, `seq_last`, `save_cur`, and array of entries with `seq`, `time`, `parent`, `children`.

#### Persistence Engine
- **Storage Location**: `~/.local/state/electronic_macdonalds/undo/%path_hash%.undo`.
- **Validation**: Stores SHA256 of the file content at `saved_seq`. If external modification occurs, persistence safely rejects invalid trees.
- **Automatic Triggers**:
  - On buffer write (`:w`, `:wq`): Flushes tree to sidecar file.
  - On buffer open (`:e`, `read_file`): Automatically loads matching tree if valid.

### 2.3 Non-Functional Requirements
- Undo/redo step execution must be $O(K)$ where $K$ is the length of the mutated text slice.
- Disk serialization/deserialization must complete in $< 2\text{ms}$ for trees under 1,000 nodes.
- Zero memory leaks across tree pruning or buffer destruction.

### 2.4 Out of Scope
- Visual graphical tree UI in Lua (the API is provided; UI visualization is deferred).
- Encryption of undo files on disk.

---

## 3. Proposal

### 3.1 Data Structures (`src/buffer/undo.zig`)

```zig
pub const ChangeDelta = struct {
    offset: usize,
    inserted_text: []const u8,
    deleted_text: []const u8,
};

pub const UndoNode = struct {
    seq: u64,
    parent: ?*UndoNode,
    children: std.ArrayList(*UndoNode),
    delta: ChangeDelta,
    cursor: Cursor,
    timestamp: i64,
};

pub const UndoTree = struct {
    allocator: Allocator,
    root: *UndoNode,
    current: *UndoNode,
    next_seq: u64,
    saved_seq: ?u64,
    pending_delta: ?ChangeDelta, // For coalescing insert mode typing
};
```

### 3.2 Buffer Integration (`src/buffer/buffer.zig`)

`Buffer` holds an `UndoTree`:
- `buf.begin_undo_group()` and `buf.end_undo_group()`.
- `buf.apply_insert(offset, text, record_undo: bool)`.
- `buf.apply_delete(offset, count, record_undo: bool)`.
- `buf.undo() -> ?Cursor` and `buf.redo() -> ?Cursor`.

### 3.3 Persistence Serialization Format

Binary format in `~/.local/state/electronic_macdonalds/undo/`:
- **Header**: Magic bytes `EMUN` (4 bytes), format version `0x01` (1 byte).
- **Checksum**: SHA256 of file on disk (32 bytes).
- **Node Count**: `u32`.
- **Node Records**: Array of nodes serialized with parent ID, seq, timestamp, and delta byte strings.

---

## 4. Task List

- [x] **Phase 1: In-Memory Undo Tree & Delta Inversion (TDD)**
  - [x] Implement `ChangeDelta`, `UndoNode`, and `UndoTree` in `src/buffer/undo.zig`.
  - [x] Implement tree branching (creating alternate sibling branches when diverging from an ancestor).
  - [x] Implement `undo()` and `redo()` with reverse delta application on gap buffer.
  - [x] Write unit tests for linear undo/redo, non-linear branch navigation, and chronological traversal (`g-`, `g+`).

- [x] **Phase 2: Edit Coalescing & Vim Modal Integration (TDD)**
  - [x] Implement atomic grouping across Insert mode sessions in `src/input/vim.zig`.
  - [x] Bind `u` (undo) and `<C-r>` (redo) in Normal mode.
  - [x] Connect `saved_seq` to buffer dirty state (`is_dirty` resets when undoing to disk state).
  - [x] Write unit tests verifying coalesced typing and `is_dirty` reversal.

- [x] **Phase 3: Lua Query API (`editor.undo.tree()`) (TDD)**
  - [x] Expose `editor.undo.tree(buf)` returning table matching Neovim's `undotree()`.
  - [x] Write unit tests verifying tree structure introspection from Lua.

- [x] **Phase 4: Disk Persistence & File Checksum Validation (TDD)**
  - [x] Implement binary serialization/deserialization in `src/buffer/undo_persist.zig`.
  - [x] Connect save/load hooks to `:w` and `:e`.
  - [x] Write unit tests verifying persistence round-trip and rejection on checksum mismatch.
