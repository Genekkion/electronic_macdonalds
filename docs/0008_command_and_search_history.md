# 0008: Command and Search History with JSON Persistence

## 1. Background / Context

Modal editing relies heavily on repeating and recalling previous commands and search patterns:
1. Recalling previous colon commands (`:w`, `:%s/old/new/g`, `:bnext`) via `<Up>` and `<Down>` arrows.
2. Filtering history entries by prefix (e.g. typing `:w` then pressing `<Up>` only recalls previous commands starting with `w`).
3. Recalling previous search queries (`/` and `?`) with live incremental preview and viewport highlights.
4. Persisting history across editor restarts using an explicit, human-readable JSON schema stored in `~/.local/state/electronic_macdonalds/history.json`.

---

## 2. Requirements & Goals

### 2.1 Functional Requirements

#### History Ring & Navigation (`src/input/history.zig`)
- **Dual Isolated Rings**: Separate collections for commands (`:`) and searches (`/`, `?`).
- **Capacity**: Maximum 100 entries per category (FIFO eviction when full).
- **Deduplication**: Consecutive identical commands are not duplicated.
- **Draft Preservation**: The in-progress draft is saved when starting `<Up>` navigation, and restored when navigating `<Down>` back to the present.
- **Prefix Matching (Neovim-style)**:
  - Empty prompt: `<Up>`/`<Down>` cycles through all previous items in reverse chronological order.
  - Non-empty prompt: `<Up>`/`<Down>` only visits items matching the initial typed prefix.
- **Live Search Synchronization**: Scrolling through search history in `/` or `?` triggers real-time `incsearch` match preview and viewport highlight updates.

#### JSON Persistence
- **File Location**: `~/.local/state/electronic_macdonalds/history.json`.
- **Schema**:
  ```json
  {
    "version": 1,
    "commands": [
      "w",
      "%s/old/new/g",
      "bnext"
    ],
    "searches": [
      "my_function",
      "error"
    ]
  }
  ```
- **Lifecycle**:
  - Automatically loads on editor boot (clean fallback if missing or corrupted).
  - Automatically saves on committing commands (`<CR>`) and on editor exit (`:q`, `:wq`).

---

## 3. Architecture & Design

### 3.1 Data Structures (`src/input/history.zig`)
- `HistoryCategory`: Bounded ring of `[100][256]u8` entries.
- `HistoryStore`: Contains `commands: HistoryCategory` and `searches: HistoryCategory`.
- `NavState`: Tracks `nav_index`, `draft: [256]u8`, `draft_len: usize`, and `prefix: [256]u8`, `prefix_len: usize`.

### 3.2 Key Handler Integration (`src/input/vim.zig`)
- In `handle_command_line_key`:
  - `.up`: Saves draft if at present, walks backwards through matching items, updates `cmd_line` and `cmd_cursor`.
  - `.down`: Walks forward through matching items, restores draft if at present.
  - `.enter`: Appends entry to category history, resets navigation state, persists to disk.
  - `.escape`: Resets navigation state.

---

## 4. Task List

- [x] **Phase 1: History Ring Core, Prefix Filtering & JSON Persistence (TDD)**
  - [x] Implement `HistoryStore` with `add`, `navigate_up`, `navigate_down` in `src/input/history.zig`.
  - [x] Implement `save_to_file` and `load_from_file` with JSON serialization.
  - [x] Write unit tests for FIFO push, consecutive dedup, draft restore, prefix filtering, and JSON roundtrip.

- [x] **Phase 2: Vim Modal Key Integration (`<Up>` / `<Down>` / `<CR>`) (TDD)**
  - [x] Connect `HistoryStore` inside `EditorState` in `src/input/vim.zig`.
  - [x] Wire `.up` and `.down` in `handle_command_line_key`.
  - [x] Wire live preview synchronization on search history navigation.
  - [x] Write unit tests verifying interactive history recall and live search updates.

- [x] **Phase 3: AppKit & Startup/Shutdown Wiring (`src/main.zig`)**
  - [x] Load `history.json` on editor initialization.
  - [x] Save `history.json` on command execution and editor shutdown.
