# 0006: Line Number Gutter and Go-to-Line Navigation

## 1. Background / Context

With core editing, modal input, search and replace, and multi-buffer management in place, text navigation and code context require two vital workflow features:
1. **Line Number Gutter**: Visual column displaying absolute or relative line numbers, dynamically sized to total buffer line count, with current-line highlighting.
2. **Go-to-Line Navigation**: Direct line jumps via colon commands (`:<number>`, `:$`) and standard Vim normal-mode motions (`G`, `gg`, and `[count]G` / `[count]gg`).

---

## 2. Requirements & Goals

### 2.1 Functional Requirements

#### Line Number Gutter (`src/platform/macos_window.m` / `src/render/`)
- Dynamic gutter sizing: calculates width based on `floor(log10(total_lines)) + 1` (minimum 3 digits + padding).
- Distinct styling:
  - Subtle gutter background strip (`#212329`) and separator border (`#383d47`).
  - Muted line numbers for background lines (`#5c6370`).
  - High-contrast highlighted line number for current cursor line (`#e5c07b` / `#abb2bf`).
- Modes:
  - Absolute numbers (`set number` / `nu`): shows line index 1-based.
  - Hybrid / Relative numbers (`set relativenumber` / `rnu`): shows current line's absolute number, and relative offsets for other visible lines.
- Unified coordinate offset: adjusts text rendering, selection rects, search highlight rects, and cursor positions by `textStartX = gutterWidth + padding`.

#### Go-to-Line Commands & Motions (`src/input/vim.zig` & `src/runtime/lua/editor/commands.lua`)
- **Colon Jump**:
  - `:<line>` (e.g. `:42`, `:1`): jumps cursor directly to line 42 (clamped to buffer bounds).
  - `:$`: jumps cursor to the last line of the buffer.
- **Normal Mode Motions**:
  - `G`: jumps to the last line (or line `[count]` if numeric prefix was typed).
  - `gg`: jumps to line 1 (or line `[count]` if numeric prefix was typed).
  - Visual mode support: `G` and `gg` expand selection to target line.
- **Count Prefix Accumulator**:
  - Digits `1`..`9` in normal mode start accumulating count; subsequent `0`..`9` append to count.
  - Count applies to motions `j`, `k`, `h`, `l`, `w`, `b`, `G`, `gg`.

### 2.2 Non-Functional Requirements
- Zero overhead on rendering loops.
- All unit tests pass via `zig build test --summary all`.
- Strict TDD cycle: test first, RED, implement, GREEN.

---

## 3. Architecture & Design

### 3.1 Editor State & Count Accumulation (`src/input/vim.zig`)
- Add `count: ?usize = null` to `EditorState`.
- Digits `'1'..'9'` (or `'0'` if `count != null`) set/accumulate `count`.
- Motions consume `effective_count = self.count orelse 1`, then reset `self.count = null`.

### 3.2 Lua Integration (`src/lua/buffer_binding.zig` & `commands.lua`)
- Expose `editor.set_cursor(line, col)` and `editor.get_cursor()` to Lua.
- Add numeric command parser to `editor.dispatch_command`:
  - `line:match("^:?(%d+)$")` -> jumps cursor to line.
  - `line:match("^:?%$")` -> jumps cursor to end.
- Add `:set` option handlers for `nu`, `nonu`, `rnu`, `nornu`.

### 3.3 Platform Rendering (`src/platform/macos_window.m`)
- `macos_window_set_line_numbers(win, bool show, bool relative)`
- Computes `gutterWidth` and offsets text and cursor accordingly.

---

## 4. Task List

- [x] **Phase 1: Motion Motions (`G`, `gg`, `[count]G`, `[count]gg`) & Normal Mode Counts (TDD)**
  - [x] Add `count: ?usize = null` to `EditorState` in `src/input/vim.zig`.
  - [x] Support `G` and `gg` motions in Normal and Visual modes.
  - [x] Write unit tests for `G`, `gg`, and count-prefixed jumps.

- [x] **Phase 2: Numeric Go-to-Line Commands (`:<line>`, `:$`) (TDD)**
  - [x] Expose `editor.set_cursor(line, col)` and `editor.get_cursor()` in `src/lua/buffer_binding.zig`.
  - [x] Handle `:<number>` and `:$` in `src/runtime/lua/editor/commands.lua`.
  - [x] Write unit tests for colon line navigation.

- [x] **Phase 3: Line Number Gutter Rendering (`macos_window.m` & `main.zig`)**
  - [x] Add `macos_window_set_line_numbers` to `src/platform/macos_window.h` and `.m`.
  - [x] Implement dynamic gutter calculation, line number glyph drawing, and coordinate shift in `drawRect:`.
  - [x] Add `:set nu`, `:set nonu`, `:set rnu`, `:set nornu` commands.
