# 0003: Multi-Buffer Management & Lifecycle

## 1. Background / Context

Electronic Macdonalds maintains multiple buffers in a central [`BufferRegistry`](../src/buffer/registry.zig), but user-facing operations currently assume a single active scratch buffer. 

When users run `:e <path>` or create buffers, there is no mechanism to:
1. List all active buffers (`:ls` / `:buffers`).
2. Cycle through buffers sequentially (`:bnext` / `:bprev`).
3. Switch directly to a buffer by number or name (`:b <id_or_name>`).
4. Close/unload buffers with dirty state checking (`:bd` / `:bd!`).
5. Track alternate/previous buffer history (`#`).

Following the hybrid GNU Emacs runtime + Vim modal philosophy, buffer lifecycle state is managed in the embedded Lua 5.5 business logic layer, while memory storage and zero-copy slicing remain in Zig substrate.

---

## 2. Requirements / Goal

### 2.1 Desired Outcome
Provide full Vim/Emacs multi-buffer workflows with fast switching, dirty buffer protection, buffer enumeration, and UI viewport synchronization.

### 2.2 Functional Requirements
- **Buffer Identity**:
  - Each buffer has an assigned numeric ID (`id: u64`), filename/path (`file_path: ?[]const u8`), and display name (filename or `"[No Name] <id>"`).
- **Listing (`:ls` / `:buffers`)**:
  - Displays formatted buffer table on status line / message log with Vim indicators:
    - `%a`: Currently active buffer.
    - `#`: Alternate (previously active) buffer.
    - `+`: Dirty / modified buffer with unsaved changes.
    - Line count and file path / display name.
- **Cycling (`:bnext` / `:bn`, `:bprev` / `:bp`)**:
  - Advances forward or backward through registered buffers in circular order.
  - Updates alternate buffer `#` pointer.
- **Targeted Switch (`:b <target>` / `:buffer <target>`)**:
  - Accepts numeric buffer ID (`:b 2`) or case-insensitive substring match of buffer name/path (`:b scratch`).
- **Buffer Deletion (`:bd [target]` / `:bdelete [target]`, `:bd!`)**:
  - Fails with warning if target buffer has unsaved changes unless `!` is appended.
  - Automatically activates the alternate buffer or previous buffer upon deletion.
  - If the last buffer is closed, automatically creates an empty clean scratch buffer so the editor is never without a buffer.

### 2.3 Non-Functional Requirements
- Buffer switching must be $O(1)$ pointer update in Zig and redraw in $< 1\text{ms}$.
- Zero filesystem access during buffer switching between already-loaded buffers.

### 2.4 Out of Scope
- Hidden buffer unmapping / swap file recovery to disk.
- Tab page management (`:tabnew`) — deferred to a subsequent TD.

---

## 3. Proposal

### 3.1 Zig Primitives & Lua Bindings

In `src/buffer/buffer.zig`:
```zig
pub const Buffer = struct {
    ...
    name: ?[]const u8 = null, // Optional custom name
    pub fn get_display_name(self: *const Buffer, allocator: Allocator) ![]u8 { ... }
};
```

In `src/lua/buffer_binding.zig`:
- `editor.list_buffers()`: Returns Lua table array of `{ id = num, name = str, path = str or nil, is_dirty = bool, line_count = num }`.
- `editor.get_buffer_by_id(id)`: Returns buffer handle or nil.
- `editor.get_buffer_by_name(name)`: Substring lookup across registered buffers.

### 3.2 Lua Buffer Manager (`src/runtime/lua/editor/buffers.lua`)

Maintain buffer state and navigation history:
```lua
local buffers = {
    active_id = nil,
    alt_id = nil,
}

function buffers.list() ... end
function buffers.next() ... end
function buffers.prev() ... end
function buffers.switch(target) ... end
function buffers.delete(target, force) ... end
```

### 3.3 Command Dispatching (`src/runtime/lua/editor/commands.lua`)

Register commands:
- `:ls`, `:buffers` -> `buffers.list()`
- `:bn`, `:bnext` -> `buffers.next()`
- `:bp`, `:bprev` -> `buffers.prev()`
- `:b`, `:buffer` -> `buffers.switch(args)`
- `:bd`, `:bdelete`, `:bd!` -> `buffers.delete(args, force)`

---

## 4. Task List

- [x] **Phase 1: Buffer Identity & Enumeration Primitives (TDD)**
  - [x] Add `name` and display name derivation to `Buffer` in `src/buffer/buffer.zig`.
  - [x] Implement `editor.list_buffers()` in `src/lua/buffer_binding.zig`.
  - [x] Write unit tests verifying buffer metadata retrieval from Lua.

- [x] **Phase 2: Lua Buffer Navigation & History Engine (TDD)**
  - [x] Implement `src/runtime/lua/editor/buffers.lua`.
  - [x] Implement circular next/prev buffer cycling with alternate buffer (`#`) tracking.
  - [x] Implement numeric ID and substring name lookup for `:b <target>`.
  - [x] Write unit tests verifying cycling and target resolution.

- [x] **Phase 3: Buffer Deletion & Safe Fallback (TDD)**
  - [x] Implement `:bd` with dirty guard, `:bd!` force delete, and empty-fallback creation.
  - [x] Write unit tests for `:bd` on clean/dirty buffers and fallback creation.

- [x] **Phase 4: GUI Sync & Status Line Formatting**
  - [x] Hook buffer switch events in `src/main.zig` to update `g_active_buffer`, status line filename, and trigger redraw.
  - [x] Verify interactively via `zig build run`.
