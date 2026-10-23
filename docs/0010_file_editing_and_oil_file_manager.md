# 0010: File Editing (`:e`) and Oil-style Filesystem Buffer Manager

## 1. Background / Context

In modal editors, file navigation and file operations are essential:
1. Opening files via `:e <path>` / `:edit <path>` into the buffer registry.
2. Opening directories directly in an editable buffer (inspired by `oil.nvim`), treating the filesystem as a text buffer.
3. Performing batch filesystem mutations (renaming, deleting, creating, and moving files) using standard Vim text-editing commands (`cw`, `dd`, `o`, `p`), committed atomically on `:w`.
4. Navigating hierarchies using standard keys (`<CR>` to open a file/folder, `-` to navigate to the parent folder).

---

## 2. Requirements & Goals

### 2.1 File Editing (`:edit` / `:e [path]`)
- **`:e <path>` with existing file**:
  - If a buffer for that path is already in the registry, switch to it.
  - If not in registry, load the file from disk into a new buffer and switch to it.
- **`:e <path>` with non-existent file**:
  - Create a new empty buffer associated with that `file_path`, allowing the user to write content and save to that path with `:w`.
- **`:e <directory>` or `:e .`**:
  - Route directly to the Oil directory buffer manager.
- **`:e` (no path)**:
  - Reload the current buffer from disk if it has a file path.

### 2.2 Oil Filesystem Buffer Engine
- **Directory Buffer Representation**:
  - Buffer title/path: `oil:///path/to/dir/` (or `<dir>/`).
  - Entries listed line-by-line: directories sorted first with a trailing `/`, followed by regular files sorted alphabetically.
  - Snapshot tracking: Keep an internal mapping of line index to original entry `{ name = "...", is_dir = bool }`.
- **In-Buffer Filesystem Operations**:
  - **Rename**: Changing a line's text (e.g. `foo.txt` $\to$ `bar.txt`) renames the file on disk.
  - **Delete**: Deleting a line (`dd`) deletes the corresponding file (`unlink`) or directory (`rmdir`) on disk.
  - **Create**: Adding a new line (`o my_file.txt` or `o my_dir/`) creates an empty file or new directory.
  - **Move**: Changing a line to a relative path (e.g. `sub/foo.txt`) moves the file.
- **Atomic Commit on `:w`**:
  - Diffs current buffer lines against initial snapshot.
  - Performs batch filesystem operations (`fs_mkdir`, `fs_touch`, `fs_rename`, `fs_delete`).
  - Refreshes buffer contents and snapshot, clearing dirty state.
- **Navigation Keymaps**:
  - `<CR>`: If cursor is on a regular file line, opens that file (`:e <path>`). If on a directory line, opens that directory in Oil.
  - `-`: Navigates to the parent directory (`..`).

---

## 3. Architecture & Design

### 3.1 Zig Filesystem Primitives (`src/lua/fs.zig` / `editor.*`)
Exposes C/POSIX filesystem operations to the Lua VM:
- `editor.is_dir(path: string) -> bool`
- `editor.read_dir(path: string) -> { { name = string, is_dir = bool }, ... }`
- `editor.fs_rename(old_path: string, new_path: string) -> (bool, err_code, err_msg)`
- `editor.fs_delete(path: string, is_dir: bool) -> (bool, err_code, err_msg)`
- `editor.fs_mkdir(path: string) -> (bool, err_code, err_msg)`
- `editor.fs_touch(path: string) -> (bool, err_code, err_msg)`

### 3.2 Oil Engine (`src/runtime/lua/editor/oil.lua`)
- Implemented in Lua as a built-in module loaded into `editor.oil`.
- Maintains active directory buffer state and original snapshot.
- Intercepts `:w` on oil buffers to execute filesystem diffs.
- Binds `<CR>` and `-` for directory navigation.

---

## 4. Task List

- [x] **Phase 1: Zig Filesystem Primitives (TDD)**
  - [x] Implement `src/lua/fs.zig` with `is_dir`, `read_dir`, `fs_rename`, `fs_delete`, `fs_mkdir`, `fs_touch`.
  - [x] Register primitives on `editor` table in `src/lua/buffer_binding.zig`.
  - [x] Write unit tests verifying POSIX file/dir operations from Lua.

- [x] **Phase 2: `:edit` / `:e` Command with Directory Routing (TDD)**
  - [x] Update `src/runtime/lua/editor/commands.lua` to implement `:edit` / `:e`.
  - [x] Support opening existing files, switching to loaded buffers, and creating new empty buffers.
  - [x] Route directory paths (`is_dir == true`) to `editor.oil.open(dir)`.
  - [x] Write unit tests for `:e <file>`, `:e <existing>`, `:e <new_file>`, `:e <dir>`.

- [x] **Phase 3: Oil Directory Listing & Navigation Keymaps (TDD)**
  - [x] Implement `src/runtime/lua/editor/oil.lua` directory buffer formatter.
  - [x] Bind `<CR>` to open files/folders and `-` to navigate to parent.
  - [x] Write unit tests verifying directory listing order and navigation transitions.

- [x] **Phase 4: Save & Diff Synchronization (Rename, Delete, Create) (TDD)**
  - [x] Implement diff calculation in `editor.oil.save(buf)` comparing lines to snapshot.
  - [x] Execute filesystem mutations with error reporting.
  - [x] Refresh buffer lines and reset dirty flag.
  - [x] Write unit tests for in-buffer file renaming, deletion, and file creation.
