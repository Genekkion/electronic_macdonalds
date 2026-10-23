# 0007: Viewport Scrolling and Padding (`scrolloff`)

## 1. Background / Context

Previously, the editor displayed lines `0` to `visible_rows`, anchored to the top of the buffer. Navigating past the window height pushed the cursor off-screen underneath the status bar.

To enable proper navigation across buffers of any size, the editor needs:
1. **Viewport Scroll Offset (`scroll_top_line`)**: Tracking which line is at the top of the visible area.
2. **Dynamic Automatic Scrolling with Context Padding (`scrolloff`)**: Keeping a vertical margin of lines visible above and below the cursor.
3. **Small Window Resiliency**: Safe graceful degradation when window height is smaller than standard padding (`visible_rows <= 2 * scrolloff` or `visible_rows <= 1`).

---

## 2. Requirements & Goals

### 2.1 Functional Requirements

#### Dynamic Padding Calculation
- Configurable `scrolloff` option (default: `4` lines).
- Effective padding formula:
  $$\text{eff\_scrolloff} = \begin{cases} 0 & \text{if } \text{visible\_rows} \le 1 \\ \min\left(\text{scrolloff},\, \lfloor\frac{\text{visible\_rows} - 1}{2}\rfloor\right) & \text{if } \text{visible\_rows} > 1 \end{cases}$$
- Smooth bounds checking:
  - When `cursor_line < scroll_top + eff_scrolloff`: scroll up.
  - When `cursor_line > scroll_top + visible_rows - 1 - eff_scrolloff`: scroll down.
  - Clamped to `max_scroll = max(0, total_lines - visible_rows)`.

#### Small Window Edge Cases
- `visible_rows <= 2 * scrolloff`: Dynamic clamp centers cursor safely.
- `visible_rows == 1`: Padding disabled; viewport follows cursor exactly (`scroll_top = cursor_line`).
- `visible_rows <= 0`: Safe no-op; no negative coordinate calculation or panic.

#### Rendering Translation (`src/platform/macos_window.m`)
- Line numbers, text lines, visual selection rects, search highlights, and cursor rendered relative to `(line_idx - scroll_top)`.
- Lines outside `[scroll_top, scroll_top + visible_rows)` clipped automatically.

---

## 3. Task List

- [x] **Phase 1: Viewport Scroll Math & Small Window Padding (TDD)**
  - [x] Implement `update_scroll_with_padding` in `src/render/viewport.zig`.
  - [x] Write unit tests for scrolling down, scrolling up, small window padding, and 1-row/0-row windows.

- [x] **Phase 2: Platform Window Integration (`macos_window.m` & `main.zig`)**
  - [x] Add `macos_window_set_scroll_top` in `src/platform/macos_window.h` and `macos_window.m`.
  - [x] Translate line index in `_getLineCb`, text positioning, selection rects, search highlights, and cursor in `drawRect:`.
  - [x] Call `update_scroll_with_padding` in `src/main.zig` on every UI update.
