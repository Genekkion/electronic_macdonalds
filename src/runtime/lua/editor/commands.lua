-- runtime/lua/editor/commands.lua
-- Command registry, argument parser, and built-in Vim commands

local M = {}

editor.commands = editor.commands or {}

--- Register a command with a given name and callback function
function editor.create_command(name, fn)
    assert(type(name) == "string", "command name must be a string")
    assert(type(fn) == "function", "command handler must be a function")
    editor.commands[name] = fn
end

--- Dispatch a command-line string (e.g. ":w /path/to/file" or "q!")
function editor.dispatch_command(line)
    if not line or line == "" then
        return true
    end

    -- Strip leading colon and surrounding whitespace
    local raw = line:match("^:?%s*(.-)%s*$")
    if raw == "" then
        return true
    end

    -- Extract command name (including optional !) and remainder arguments
    local name, args = raw:match("^(%S+)%s*(.-)$")
    if not name then
        return false
    end

    local handler = editor.commands[name]
    if handler then
        local ok, err = pcall(handler, args)
        if not ok then
            editor.set_error("Error executing :" .. name .. ": " .. tostring(err))
            return false
        end
        return true
    else
        editor.set_error("Not an editor command: " .. name)
        return false
    end
end

-- ============================================================================
-- Built-in Commands
-- ============================================================================

-- :echo <msg> - Display message on status line
editor.create_command("echo", function(args)
    editor.set_status(args)
end)

-- :w [path] - Save current buffer to disk
editor.create_command("w", function(args)
    local cur_buf = editor.get_current_buffer()
    if not cur_buf then
        editor.set_error("No buffer to write")
        return
    end

    local path = args
    if path == "" then
        path = cur_buf.filename or ""
    end

    if path == "" then
        editor.set_error("No file name")
        return
    end

    local ok, err, msg = cur_buf:save(path)
    if ok then
        cur_buf.filename = path
        editor.set_status('"' .. path .. '" written')
    else
        editor.set_error("Write error: " .. tostring(msg or err))
    end
end)

-- :q - Quit editor (checks dirty state)
editor.create_command("q", function()
    local cur_buf = editor.get_current_buffer()
    if cur_buf then
        local dirty, _, _ = cur_buf:is_dirty()
        if dirty then
            editor.set_error("No write since last change (add ! to override)")
            return
        end
    end
    editor.quit(false)
end)

-- :q! - Force quit editor (discards unsaved modifications)
editor.create_command("q!", function()
    editor.quit(true)
end)

-- :wq [path] - Save and exit
editor.create_command("wq", function(args)
    local cur_buf = editor.get_current_buffer()
    if cur_buf then
        local path = args
        if path == "" then
            path = cur_buf.filename or ""
        end
        if path == "" then
            editor.set_error("No file name")
            return
        end
        local ok, err, msg = cur_buf:save(path)
        if not ok then
            editor.set_error("Write error: " .. tostring(msg or err))
            return
        end
    end
    editor.quit(true)
end)

-- :e <path> - Edit / open a file
editor.create_command("e", function(path)
    if not path or path == "" then
        editor.set_error("Argument required")
        return
    end

    local buf, err, msg = editor.read_file(path)
    if buf then
        buf.filename = path
        editor.set_current_buffer(buf)
        editor.set_status('"' .. path .. '" opened')
    else
        editor.set_error("Cannot open file: " .. tostring(msg or err))
    end
end)

return M
