-- runtime/lua/editor/init.lua
-- Core editor runtime initialization

editor = editor or {}
editor.g = editor.g or {}
editor.g.mapleader = editor.g.mapleader or " "
editor._last_message = ""
editor._last_error = ""

--- Set the informational status line message
function editor.set_status(msg)
    editor._last_message = msg or ""
    editor._last_error = ""
end

--- Set an error message displayed on the status line
function editor.set_error(err)
    editor._last_error = err or ""
    editor._last_message = err or ""
end

--- Retrieve the last status message
function editor.get_last_message()
    return editor._last_message
end

--- Retrieve the last error message
function editor.get_last_error()
    return editor._last_error
end

-- Load command subsystem
require("editor.commands")
-- Load keymap subsystem
require("editor.keymap")
-- Load buffer management subsystem
require("editor.buffers")
-- Load events/autocommand subsystem
require("editor.events")
-- Load oil filesystem buffer subsystem
require("editor.oil")

--- User-facing option setters and getters
function editor.set(opt, val)
    editor.set_option(opt, val)
end

function editor.get(opt)
    return editor.get_option(opt)
end

--- User-facing command registration helper
function editor.command(name, handler)
    if type(handler) == "function" then
        editor.create_command(name, handler)
    elseif type(handler) == "string" then
        editor.create_command(name, function(args)
            local cmd = handler
            if args and args ~= "" then
                cmd = cmd .. " " .. args
            end
            editor.dispatch_command(cmd)
        end)
    else
        error("command handler must be a function or string")
    end
end

--- User-facing keymap helper
function editor.map(mode, lhs, rhs, opts)
    editor.keymap.set(mode, lhs, rhs, opts)
end

-- Default keymaps
editor.keymap.set("n", "<leader>w", ":w<CR>")
editor.keymap.set("n", "<leader>q", ":q<CR>")
editor.keymap.set("n", "<leader>bn", ":bn<CR>")
editor.keymap.set("n", "<leader>bp", ":bp<CR>")

-- Oil filesystem buffer keymaps
editor.keymap.set("n", "-", function()
    if editor.oil and editor.oil.is_oil_buffer(editor.get_current_buffer()) then
        return editor.oil.parent_dir()
    end
    return false
end)

editor.keymap.set("n", "<CR>", function()
    if editor.oil and editor.oil.is_oil_buffer(editor.get_current_buffer()) then
        return editor.oil.select_entry()
    end
    return false
end)

editor.keymap.set("n", "<leader>gg", function()
    if not editor.oil then return end
    local cur_buf = editor.get_current_buffer()
    if cur_buf and editor.oil.is_oil_buffer(cur_buf) then
        editor.oil.parent_dir()
    else
        local path = cur_buf and cur_buf:get_path()
        if path and path ~= "" and not path:match("^oil://") then
            local dir = path:match("^(.-)/[^/]+$")
            if dir and dir ~= "" and editor.is_dir(dir) then
                editor.oil.open(dir)
                return
            end
        end
        editor.oil.open(".")
    end
end)

return editor
