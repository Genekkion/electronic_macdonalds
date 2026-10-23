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

    if editor.oil and editor.oil.is_oil_buffer(cur_buf) and (not args or args == "") then
        editor.oil.save(cur_buf)
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

    -- Check if file was modified externally
    if (not args or args == "" or args == cur_buf:get_path()) and cur_buf.check_external_change and cur_buf:check_external_change() then
        editor.set_error("WARNING: File changed on disk since last read (add ! to override, or run :DiffConflict)")
        return
    end

    local ok, err, msg = cur_buf:save(path)
    if ok then
        editor.set_status('"' .. path .. '" written')
    else
        editor.set_error("Write error: " .. tostring(msg or err))
    end
end)

-- :w! [path] - Force save overriding external changes
editor.create_command("w!", function(args)
    local cur_buf = editor.get_current_buffer()
    if not cur_buf then
        editor.set_error("No buffer to write")
        return
    end

    if editor.oil and editor.oil.is_oil_buffer(cur_buf) and (not args or args == "") then
        editor.oil.save(cur_buf)
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

-- :DiffConflict - 3-way merge in-memory edits with disk changes using Git markers
editor.create_command("DiffConflict", function()
    local cur = editor.get_current_buffer()
    if not cur then return end
    if not cur.diff_conflict then
        editor.set_error("diff_conflict not available")
        return
    end

    local has_conflict, count = cur:diff_conflict()
    if has_conflict then
        editor.set_error(string.format("Found %d conflict(s); inserted Git markers (<<<<<<<, =======, >>>>>>>)", count))
    else
        editor.set_status("Merged external changes cleanly with no conflicts")
    end
end)

--- Check for external modifications and reload clean buffers
function editor.checktime()
    if editor.log then editor.log("commands.lua: editor.checktime() called") end
    local cur = editor.get_current_buffer()
    if not cur then
        if editor.log then editor.log("  -> no current buffer") end
        return false
    end
    local changed = cur.check_external_change and cur:check_external_change()
    if editor.log then editor.log("  -> cur:check_external_change() = " .. tostring(changed)) end
    if changed then
        local dirty, _, _ = cur:is_dirty()
        local name = (cur.get_path and cur:get_path()) or "buffer"
        if editor.log then editor.log("  -> is_dirty = " .. tostring(dirty) .. ", name = " .. tostring(name)) end
        if not dirty then
            local ok, err, msg = cur:reload()
            if editor.log then editor.log("  -> cur:reload() = " .. tostring(ok) .. ", err = " .. tostring(err) .. ", msg = " .. tostring(msg)) end
            if ok then
                editor.set_status('"' .. name .. '" reloaded from disk')
                return true
            else
                editor.set_error('Failed to reload "' .. name .. '": ' .. tostring(msg or err or "unknown"))
            end
        else
            editor.set_error('Warning: File "' .. name .. '" changed on disk with unsaved changes. Run :DiffConflict or :e! to reload')
        end
    end
    return false
end

-- :checktime - check for external modifications
editor.create_command("checktime", function()
    editor.checktime()
end)

--- Open a path (file or directory)
function editor.edit_path(path, force)
    local cur = editor.get_current_buffer()
    local cur_path = (cur and cur.get_path and cur:get_path()) or ""

    if not path or path == "" then
        path = cur_path
    end

    path = path:match("^%s*(.-)%s*$")
    if path == "" then
        editor.set_error("No file name")
        return false
    end

    -- Reloading the current buffer
    if cur and cur_path == path then
        local dirty, _, _ = cur:is_dirty()
        if dirty and not force then
            editor.set_error("No write since last change (add ! to override)")
            return false
        end
        local ok, err, msg = cur:reload()
        if ok then
            editor.set_status('"' .. path .. '" reloaded')
            return true
        else
            editor.set_error("Failed to reload: " .. tostring(msg or err))
            return false
        end
    end

    -- Check if directory
    if (editor.is_dir and editor.is_dir(path)) or path == "." or path:match("/$") then
        if editor.oil then
            return editor.oil.open(path) ~= nil
        end
    end

    -- Check if already open in a buffer
    for _, b_info in ipairs(editor.list_buffers()) do
        local b = editor.get_buffer_by_id(b_info.id)
        if b and b.get_path and b:get_path() == path then
            if force then
                b:reload()
            end
            editor.set_current_buffer(b)
            return true
        end
    end

    -- Try loading existing file from disk
    local buf, err, msg = editor.read_file(path)
    if buf then
        editor.set_current_buffer(buf)
        return true
    end

    -- File does not exist yet: create empty buffer associated with path
    local new_buf, n_err, n_msg = editor.create_buffer()
    if new_buf then
        if new_buf.set_path then
            new_buf:set_path(path)
        end
        editor.set_current_buffer(new_buf)
        editor.set_status('"' .. path .. '" [New File]')
        return true
    end

    editor.set_error("Failed to open file: " .. tostring(msg or n_msg))
    return false
end

-- :e [path] / :edit [path]
editor.create_command("e", function(args)
    editor.edit_path(args, false)
end)

editor.create_command("edit", function(args)
    editor.edit_path(args, false)
end)

-- :e! [path] / :edit! [path] - force reload
editor.create_command("e!", function(args)
    editor.edit_path(args, true)
end)

editor.create_command("edit!", function(args)
    editor.edit_path(args, true)
end)

-- :Oil [path]
editor.create_command("Oil", function(args)
    local p = (args and args ~= "") and args or "."
    if editor.oil then
        editor.oil.open(p)
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
