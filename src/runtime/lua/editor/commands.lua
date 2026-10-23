-- runtime/lua/editor/commands.lua
-- Command registry, argument parser, and built-in Vim commands

local M = {}

editor.commands = editor.commands or {}

editor.options = editor.options or {
    number = true,
    relativenumber = false,
}

function editor.set_option(opt, val)
    editor.options[opt] = val
end

function editor.get_option(opt)
    return editor.options[opt]
end

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

    -- Check for numeric line jump: e.g. ":42", "42", ":$"
    local num = raw:match("^(%d+)$")
    if num then
        local target = tonumber(num)
        local cur_buf = editor.get_current_buffer()
        if cur_buf then
            local count = cur_buf:line_count()
            local line_idx = math.max(0, math.min(target - 1, count - 1))
            editor.set_cursor(line_idx, 0)
            return true
        end
    end
    if raw == "$" then
        local cur_buf = editor.get_current_buffer()
        if cur_buf then
            local count = cur_buf:line_count()
            local line_idx = math.max(0, count - 1)
            editor.set_cursor(line_idx, 0)
            return true
        end
    end

    -- Extract command name (including optional !) and remainder arguments
    local name, args
    if raw:match("^%%s%A") then
        name = "%s"
        args = raw:sub(3)
    elseif raw:match("^s%A") then
        name = "s"
        args = raw:sub(2)
    else
        name, args = raw:match("^(%S+)%s*(.-)$")
    end
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
    if not path or path == "" then
        path = (cur_buf.get_path and cur_buf:get_path()) or ""
    end

    if path == "" then
        editor.set_error("No file name")
        return
    end

    local ok, err, msg = cur_buf:save(path)
    if ok then
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
        if not path or path == "" then
            path = (cur_buf.get_path and cur_buf:get_path()) or ""
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
        editor.set_current_buffer(buf)
        editor.set_status('"' .. path .. '" opened')
    else
        editor.set_error("Cannot open file: " .. tostring(msg or err))
    end
end)

local function parse_substitute(args)
    if not args or args == "" then
        return nil, "Missing substitute arguments"
    end
    local delim = args:sub(1, 1)
    local parts = {}
    local cur = ""
    local escaped = false
    for i = 2, #args do
        local ch = args:sub(i, i)
        if escaped then
            cur = cur .. ch
            escaped = false
        elseif ch == "\\" then
            escaped = true
        elseif ch == delim then
            table.insert(parts, cur)
            cur = ""
        else
            cur = cur .. ch
        end
    end
    table.insert(parts, cur)

    local pat = parts[1] or ""
    local rep = parts[2] or ""
    local flags = parts[3] or ""
    local all = flags:find("g") ~= nil
    return { pattern = pat, replacement = rep, all = all }
end

-- :%s/<pat>/<rep>/[flags] - Substitute across whole buffer
editor.create_command("%s", function(args)
    local cur_buf = editor.get_current_buffer()
    if not cur_buf then
        editor.set_error("No buffer")
        return
    end

    local sub, err = parse_substitute(args)
    if not sub then
        editor.set_error("Invalid substitute syntax: " .. tostring(err))
        return
    end

    local count, _, msg = cur_buf:replace(sub.pattern, sub.replacement, 0, cur_buf:len(), sub.all)
    if count then
        editor.set_status(tostring(count) .. " substitution(s)")
    else
        editor.set_error("Substitution failed: " .. tostring(msg))
    end
end)

-- :s/<pat>/<rep>/[flags] - Substitute
editor.create_command("s", function(args)
    local cur_buf = editor.get_current_buffer()
    if not cur_buf then
        editor.set_error("No buffer")
        return
    end

    local sub, err = parse_substitute(args)
    if not sub then
        editor.set_error("Invalid substitute syntax: " .. tostring(err))
        return
    end

    local count, _, msg = cur_buf:replace(sub.pattern, sub.replacement, 0, cur_buf:len(), sub.all)
    if count then
        editor.set_status(tostring(count) .. " substitution(s)")
    else
        editor.set_error("Substitution failed: " .. tostring(msg))
    end
end)

-- :set <options...> - Set options
editor.create_command("set", function(args)
    if not args or args == "" then return end
    for item in args:gmatch("%S+") do
        if item == "nu" or item == "number" then
            editor.set_option("number", true)
        elseif item == "nonu" or item == "nonumber" then
            editor.set_option("number", false)
        elseif item == "rnu" or item == "relativenumber" then
            editor.set_option("relativenumber", true)
        elseif item == "nornu" or item == "norelativenumber" then
            editor.set_option("relativenumber", false)
        end
    end
end)

return M
