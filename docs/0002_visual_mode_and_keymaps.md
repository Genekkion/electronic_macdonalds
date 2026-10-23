# 0002: Visual Mode, Selection & Lua Keymap Engine

## 1. Background / Context

Electronic Macdonalds now has a functional buffer engine, CoreText renderer, embedded Lua 5.5 runtime, and basic modal editing (`normal`, `insert`, `command_line`).

However, two major foundations of Vim/Emacs modal editing are still missing:
1. **Visual Selection & Registers**: Users cannot visually select regions of text (`v` for character-wise, `V` for line-wise), highlight them in the GUI viewport, or yank (`y`), delete (`d`), and put (`p`) text using registers.
2. **Lua Keymap Engine**: Keybindings are currently hardcoded in Zig's `EditorState`. Following the GNU Emacs philosophy with embedded Lua, users should be able to map and remap keys, define leader key combos (e.g. `<leader>w`), and bind key sequences to either Lua functions or command strings from Lua scripts (`init.lua`).

---

## 2. Requirements / Goal

### 2.1 Desired Outcome
Provide comprehensive Visual selection modes (`v`, `V`) with GUI background highlighting, register-based clipboard management (`y`, `p`, `P`, `d`), and a flexible Lua keymapping engine (`editor.keymap.set(mode, lhs, rhs)`).

### 2.2 Functional Requirements

#### Visual Mode & Registers:
- **Mode Transitions**:
  - `v` in Normal mode enters `.visual` (character-wise selection anchor at cursor).
  - `V` in Normal mode enters `.visual_line` (whole-line selection anchor).
  - `<Escape>` returns to `.normal` and clears active selection.
- **Selection Motions**:
  - All existing motions (`h`, `j`, `k`, `l`, `w`, `b`, `0`, `$`) update the cursor while keeping the anchor fixed.
- **Operations on Selection**:
  - `y` (Yank): Copies the selected range into the default register `""` and returns to `.normal`.
  - `d` or `x` (Delete): Deletes the selected text, saves it into register `""`, and returns to `.normal`.
  - `p` / `P` (Put): Inserts register contents after/before cursor in Normal mode.
- **Renderer Highlighting**:
  - `EditorView` (`macos_window.m`) renders a translucent highlight rectangle behind visually selected characters.

#### Lua Keymap Engine:
- **API**: `editor.keymap.set(mode, lhs, rhs, opts)`
  - `mode`: `"n"` (normal), `"i"` (insert), `"v"` (visual).
  - `lhs`: Key combo (e.g. `"<leader>w"`, `"<C-s>"`, `"jk"`).
  - `rhs`: Lua callback function or command string (e.g. `":w<CR>"`).
- **Leader Key Support**: Customizable `editor.g.mapleader` (defaults to `<Space>`).
- **Multi-key Prefix Sequences**: Ability to buffer intermediate key presses (e.g. `<Space>` followed by `w`) with a timeout or pending state.

### 2.3 Non-Functional Requirements
- Visual selection calculation must be $O(1)$ range math from buffer indices.
- Zero copy for register copies when within the same buffer session.
- Sub-millisecond latency for multi-key sequence lookups in Lua.

### 2.4 Out of Scope
- System-wide macOS pasteboard integration (`NSPasteboard` sync) — deferred to follow-up.
- Named Vim registers (`"a`, `"b`, etc.) — initial implementation focuses on the default anonymous register `""`.

---

## 3. Proposal

### 3.1 Selection State Machine

In `src/input/mode.zig`:
```zig
pub const Mode = enum {
    normal,
    insert,
    visual,
    visual_line,
    command_line,
};
```

In `src/input/vim.zig`:
```zig
pub const Selection = struct {
    anchor_line: usize,
    anchor_col: usize,
    cursor_line: usize,
    cursor_col: usize,
    is_line: bool,

    pub fn get_range(self: Selection) struct { start_line: usize, start_col: usize, end_line: usize, end_col: usize } { ... }
};
```

### 3.2 Register Engine

Register buffer in Zig / Lua:
- `anonymous_register: []u8`
- `is_line_wise: bool`
- Exposed to Lua via `editor.register.get()` and `editor.register.set()`.

### 3.3 Visual Highlight Rendering in AppKit

In `src/platform/macos_window.m`:
- Pass selection range `(start_line, start_col, end_line, end_col, is_line)` to `EditorView`.
- In `drawRect:`, iterate over visible selected rows and call `CGContextFillRect(context, selectionRect)` with `#3e4451` (translucent gray/blue) before drawing text.

### 3.4 Keymap Trie / Tree in Lua (`runtime/lua/editor/keymap.lua`)

```lua
local keymap = {
    n = {},
    i = {},
    v = {},
}

editor.g = { mapleader = " " }

function editor.keymap.set(mode, lhs, rhs, opts)
    -- Normalize leader key: replace <leader> with editor.g.mapleader
    local norm = lhs:gsub("<leader>", editor.g.mapleader)
    keymap[mode][norm] = rhs
end
```

---

## 4. Task List

- [x] **Phase 1: Visual Mode Primitives & Range Math (TDD)**
  - [x] Add `.visual_line` to `Mode` in `src/input/mode.zig`.
  - [x] Implement `Selection` struct with normalized start/end offset calculations.
  - [x] Implement `v` and `V` transitions and motions in `src/input/vim.zig`.
  - [x] Write unit tests for visual range expansion and contraction.

- [x] **Phase 2: Yank, Delete & Put Operations (TDD)**
  - [x] Implement `yank_selection(self, buf)` into anonymous register.
  - [x] Implement `delete_selection(self, buf)` into anonymous register.
  - [x] Implement `put_register(self, buf, after)` in normal mode.
  - [x] Write unit tests for character-wise and line-wise yank/put.

- [x] **Phase 3: GUI Visual Selection Highlighting**
  - [x] Update `macos_window.h` and `EditorView` to receive selection coordinates.
  - [x] Render selection bounding boxes in `drawRect:`.
  - [x] Verify visually via `zig build run`.

- [x] **Phase 4: Lua Keymap Engine (`editor.keymap.set`)**
  - [x] Create `src/runtime/lua/editor/keymap.lua`.
  - [x] Support `<leader>` expansion and function/string targets.
  - [x] Dispatch multi-key lookups from Zig input handler.
  - [x] Write unit tests verifying custom mappings and leader keys.
