# 0005: In-Buffer Search and Replace

## 1. Background / Context

Electronic Macdonalds currently supports gap buffer editing, modal input (`Normal`, `Insert`, `Visual`, `Command-Line`), multi-buffer management, and non-linear undo/redo persistence.

However, navigation and manipulation across medium-to-large files requires high-performance in-buffer search and batch substitution:
1. **Search & Jump**: Modal search prompts (`/` forward, `?` backward) and match repetition (`n`, `N`).
2. **Instant Word Lookup**: Jumping to the next/previous occurrence of the symbol under the cursor (`*`, `#`).
3. **Viewport Match Highlighting**: Highlighting matched occurrences on screen without scanning the entire file or causing frame drops.
4. **Batch Substitution (`:%s/find/replace/g`)**: Fast single-pass replacement that remains responsive on large files and creates a single atomic undo record.

---

## 2. Requirements & Goals

### 2.1 Functional Requirements

#### Search Engine (`src/buffer/search.zig`)
- **Boyer-Moore-Horspool Algorithm & Smartcase**:
  - Precomputes 256-byte bad-character shift table in $O(M)$ time and space.
  - Scans gap buffer contiguous slices with zero allocations during searches.
  - **Neovim-Style Smartcase**: If pattern contains no uppercase characters, search is case-insensitive; if pattern contains at least one uppercase letter, search is strictly case-sensitive. Both upper and lower variants are encoded in the shift table for zero-overhead branchless skip evaluation.
- **Directional Navigation**:
  - `find_next(buf, offset, pattern)`: Scans forward from cursor offset; wraps around buffer end if not found.
  - `find_prev(buf, offset, pattern)`: Scans backward from cursor offset; wraps around buffer start if not found.
- **Viewport Highlighting Range Query**:
  - `find_in_range(buf, start_offset, end_offset, pattern)`: Returns all match spans located entirely within the visible viewport slice.

#### Modal Input Integration (`src/input/vim.zig`)
- `/`: Activates search forward command prompt in status bar.
- `?`: Activates search backward command prompt in status bar.
- `<CR>` in search prompt: Stores search pattern in editor state, jumps cursor to the first match in direction, scrolls viewport if needed.
- `n`: Jumps to next match in current search direction.
- `N`: Jumps to previous match (reverse of current search direction).
- `*`: Extracts word/identifier under cursor, sets forward search pattern, jumps to next match.
- `#`: Extracts word/identifier under cursor, sets backward search pattern, jumps to previous match.
- `<Esc>` in Normal mode: Clears visual search highlighting if desired (or `:noh`).

#### Substitution Engine (`:%s/old/new/g`)
- Single-pass batched reconstruction:
  - Scans all matches in target range (current line or entire buffer).
  - Computes exact final size and allocates replacement buffer in a single pass.
  - Copies non-matching chunks and replacement strings in linear $O(L)$ time.
  - Records a single coalesced `ChangeDelta` in the undo tree so `u` rolls back all replacements in one step.
- Lua command integration:
  - `:s/pattern/replacement/g` (current line).
  - `:%s/pattern/replacement/g` (entire buffer).

### 2.2 Non-Functional Requirements
- **Low Latency**: Viewport highlight queries must complete in $< 0.1\text{ms}$ for visible screen area.
- **Single-Threaded Simplicity**: No background thread pools or async locks; predictable deterministic memory behavior.
- **Safety**: Safe handling of empty patterns, single-character needles, multibyte UTF-8, and gap-boundary edge cases.

---

## 3. Architecture & Algorithm Design

### 3.1 Boyer-Moore-Horspool on Gap Buffer

A standard gap buffer splits text across two slices:
```
Segment 0: data[0 .. gap_start]
Segment 1: data[gap_end .. capacity]
```

To search without copying text:
1. Scan Segment 0 using the BMH skip table.
2. Check the cross-gap boundary window of size $(2M - 2)$ if applicable.
3. Scan Segment 1 using the BMH skip table.

### 3.2 Viewport Highlighting

During rendering:
1. Identify visible byte range: `[lines.get_line_start(top_line) .. lines.get_line_end(bottom_line)]`.
2. Run `find_in_range` over only this range.
3. Render background highlight boxes for each returned match span behind glyphs.

---

## 4. Task List

- [x] **Phase 1: Search Engine Core & BMH Algorithm (TDD)**
  - [x] Implement `BmhScanner` with 256-byte shift table in `src/buffer/search.zig`.
  - [x] Implement `find_next` and `find_prev` with wraparound support.
  - [x] Implement `find_in_range` for viewport-restricted match collection.
  - [x] Write unit tests for forward, backward, gap-spanning, and wraparound searches.

- [x] **Phase 2: Modal Search Input & Navigation (`/`, `?`, `n`, `N`, `*`, `#`) (TDD)**
  - [x] Support search prompt mode in `src/input/mode.zig` and `vim.zig`.
  - [x] Implement `n` and `N` navigation commands with viewport centering.
  - [x] Implement `*` and `#` word-under-cursor extraction and search.
  - [x] Write unit tests for search prompt handling and cursor jumps.

- [x] **Phase 3: Viewport Match Highlighting (TDD)**
  - [x] Wire active search pattern into `src/render/viewport.zig`.
  - [x] Emit match highlight rects in `src/render/viewport.zig` / `macos_window.m`.
  - [x] Implement `:noh` / `<Esc>` highlight dismissal.
  - [x] Write unit tests verifying match spans generated for visible lines.

- [x] **Phase 4: High-Performance Single-Pass Substitution (`:%s`) (TDD)**
  - [x] Implement `replace_all` in `src/buffer/search.zig` with atomic undo grouping.
  - [x] Bind `:s` and `:%s` in `src/runtime/lua/editor/commands.lua`.
  - [x] Write unit tests verifying single-pass multi-match replacement and atomic undo rollback.
