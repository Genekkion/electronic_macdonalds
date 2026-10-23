-- runtime/lua/editor/init.lua
-- Core editor runtime initialization

editor = editor or {}
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

-- Default keymaps
editor.keymap.set("n", "<leader>w", ":w<CR>")
editor.keymap.set("n", "<leader>q", ":q<CR>")
editor.keymap.set("n", "<leader>bn", ":bn<CR>")
editor.keymap.set("n", "<leader>bp", ":bp<CR>")

return editor
