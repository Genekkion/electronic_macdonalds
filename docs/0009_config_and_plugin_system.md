# 0009: Lua Configuration & Event-Driven Plugin System

## 1. Background / Context

Electronic Macdonalds embeds a native Lua 5.5 VM for extensible command execution and keymaps. To make it a customizable, modern editor, users and plugin authors need:
1. A standard configuration entry point (`~/.config/electronic_macdonalds/init.lua`) executed safely at startup.
2. A structured runtime path (`package.path`) that enables modular Lua imports (`require("my_config")`) and third-party plugins.
3. Declarative option settings (`editor.set("number", true)`, `editor.set("scrolloff", 5)`).
4. Custom command definition (`editor.command("Format", fn)`).
5. An event/autocommand engine (`editor.on("BufWritePre", fn)`, `editor.autocmd(...)`) that fires lifecycle hooks during editing (buffer switching, file saving, mode changes) without modifying the Zig core.

---

## 2. Requirements & Goals

### 2.1 File & Directory Layout
- **Config Directory**:
  - `$XDG_CONFIG_HOME/electronic_macdonalds/` (defaults to `~/.config/electronic_macdonalds/` or fallback `~/.electronic_macdonalds/`).
  - Entry point: `init.lua`.
  - Modules: `lua/` subdirectory (e.g. `lua/settings.lua`, `lua/keymaps.lua`).
- **Data / Plugins Directory**:
  - `$XDG_DATA_HOME/electronic_macdonalds/plugins/` (defaults to `~/.local/share/electronic_macdonalds/plugins/`).
  - Each plugin in `plugins/<plugin_name>/` can provide a `lua/` tree and optional `plugin/*.lua` auto-start scripts.

### 2.2 Runtime Path & Module Loading
- Before `init.lua` is evaluated, the Zig core augments Lua's `package.path`:
  - `<config_dir>/lua/?.lua;<config_dir>/lua/?/init.lua;`
  - `<data_dir>/plugins/*/lua/?.lua;<data_dir>/plugins/*/lua/?/init.lua;`
- Users can require local modules or installed plugins directly:
  ```lua
  require("settings")
  local autopairs = require("autopairs")
  autopairs.setup()
  ```

### 2.3 Protected Execution & Error Isolation
- `init.lua` and plugin scripts must run under `pcall` / `lua_pcallk`.
- If a user config contains syntax or runtime errors:
  - The editor must not crash or abort boot.
  - An error message is captured, logged to stderr, and displayed on the status line.
  - The editor falls back gracefully to default settings.

### 2.4 Option & Command Lua APIs
- `editor.set(name: string, val: any)`:
  - Supported options: `number` (bool), `relativenumber` (bool), `scrolloff` (integer), `tabstop` (integer), `shiftwidth` (integer), `hlsearch` (bool).
- `editor.get(name: string) -> any`:
  - Retrieves current option value.
- `editor.command(name: string, handler: function | string)`:
  - Registers a colon command callable via `:<name>` with arguments.

### 2.5 Event & Autocommand Engine
- **Lifecycle Events**:
  - `BufNew`: Triggered when a buffer is created.
  - `BufEnter`: Triggered when a buffer becomes active.
  - `BufLeave`: Triggered when leaving active buffer.
  - `BufDelete`: Triggered when a buffer is closed.
  - `BufWritePre`: Triggered right before buffer text is written to disk.
  - `BufWritePost`: Triggered right after buffer text is written to disk.
  - `ModeChanged`: Triggered on modal transitions (with `from` and `to` modes).
  - `CursorMoved`: Triggered when cursor position changes.
- **Lua Registration APIs**:
  - `editor.on(event_name, callback_fn)`: Register simple event listener.
  - `editor.autocmd(event_name, { pattern = "...", callback = fn })`: Register pattern-filtered autocmd.
- **Protected Callback Dispatch**:
  - Event triggers run callbacks in protected mode; callback errors are caught and reported without disrupting core editor operations (e.g., save continues even if a write hook errors).

---

## 3. Architecture & Design

### 3.1 Zig Subsystems
- **`src/lua/config.zig`**:
  - Path resolution (`get_config_path`, `get_plugins_dir`).
  - `setup_package_path(L, config_dir, plugins_dir)`: Updates `package.path` in Lua VM.
  - `load_user_config(L, config_path) !?[]const u8`: Executes `init.lua` with error capture.
- **`src/lua/events.zig`**:
  - `EventType` enum (`BufNew`, `BufEnter`, `BufLeave`, `BufDelete`, `BufWritePre`, `BufWritePost`, `ModeChanged`, `CursorMoved`).
  - `EventData` struct containing relevant event context (`buf_id`, `buf_path`, `from_mode`, `to_mode`, `line`, `col`).
  - `emit_event(L, event_type, event_data)`: Iterates Lua registry callbacks and executes them via `lua_pcallk`.
- **`src/lua/binding.zig`**:
  - Register `editor.set`, `editor.get`, `editor.command`, `editor.on`, `editor.autocmd`.
  - Expose editor option state synchronization between Zig and Lua.

---

## 4. Task List

- [x] **Phase 1: Config Discovery, `package.path` & Protected Boot (TDD)**
  - [x] Implement `get_config_path` and `get_plugins_dir` with XDG standards in `src/lua/config.zig`.
  - [x] Implement `setup_package_path` injecting config `lua/` and plugin directories.
  - [x] Implement `load_user_config` with `lua_pcallk` error isolation.
  - [x] Write unit tests verifying path construction, `package.path` expansion, and error capture.

- [x] **Phase 2: Option & Command Lua APIs (TDD)**
  - [x] Implement `editor.set(opt, val)` and `editor.get(opt)` in `src/lua/binding.zig`.
  - [x] Synchronize option changes to editor state (`number`, `relativenumber`, `scrolloff`, `hlsearch`).
  - [x] Implement `editor.command(name, fn)` with argument passing.
  - [x] Write unit tests verifying option setting, retrieval, and custom Lua command dispatch.

- [x] **Phase 3: Autocommand & Event Engine (TDD)**
  - [x] Implement event registry and `editor.on` / `editor.autocmd` in `src/lua/events.zig` and `binding.zig`.
  - [x] Implement `emit_event` with protected execution.
  - [x] Wire core triggers in `src/main.zig` / `src/buffer/buffer.zig` / `src/input/vim.zig`:
    - `BufEnter`, `BufWritePre`, `BufWritePost`, `ModeChanged`.
  - [x] Write unit tests for save hooks, mode change events, and callback error isolation.

- [x] **Phase 4: Plugin Directory Auto-Discovery & AppKit Wiring**
  - [x] Discover installed plugin directories in `~/.local/share/electronic_macdonalds/plugins/`.
  - [x] Auto-source `plugin/*.lua` scripts on startup.
  - [x] Connect boot sequence and status line error reporting in `src/main.zig`.
  - [x] Verify full build and integration test suite.
