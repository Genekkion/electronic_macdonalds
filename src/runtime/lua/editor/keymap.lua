-- runtime/lua/editor/keymap.lua
-- Vim/Emacs-style keymapping engine

editor = editor or {}
editor.g = editor.g or { mapleader = " " }
editor.keymap = editor.keymap or {}

local keymaps = {
    n = {},
    i = {},
    v = {},
}

local pending_seq = ""

local function canonical_mode(mode)
    if mode == "normal" or mode == "n" then return "n" end
    if mode == "insert" or mode == "i" then return "i" end
    if mode == "visual" or mode == "visual_line" or mode == "v" then return "v" end
    return mode
end

local function normalize_lhs(lhs)
    local leader = (editor.g and editor.g.mapleader) or " "
    local res = lhs
    res = res:gsub("<[lL]eader>", leader)
    res = res:gsub("<[sS]pace>", " ")
    res = res:gsub("<[cC][rR]>", "\n")
    res = res:gsub("<[eE]nter>", "\n")
    res = res:gsub("<[eE]sc>", "\27")
    res = res:gsub("<[tT]ab>", "\t")
    res = res:gsub("<[bB][sS]>", "\x08")
    res = res:gsub("<[bB]ackspace>", "\x08")
    return res
end

--- Register a keymap
-- @param mode string or table of modes ("n", "i", "v")
-- @param lhs string key combination (e.g. "<leader>w", ":w<CR>", "jk")
-- @param rhs function or string command
-- @param opts table of options (optional)
function editor.keymap.set(mode, lhs, rhs, opts)
    opts = opts or {}
    local norm = normalize_lhs(lhs)
    local modes = (type(mode) == "table") and mode or { mode }

    for _, m in ipairs(modes) do
        local c_mode = canonical_mode(m)
        if not keymaps[c_mode] then keymaps[c_mode] = {} end
        keymaps[c_mode][norm] = {
            rhs = rhs,
            opts = opts,
            raw_lhs = lhs,
        }
    end
end

--- Get a registered keymap entry
function editor.keymap.get(mode, lhs)
    local c_mode = canonical_mode(mode)
    local tbl = keymaps[c_mode]
    if not tbl then return nil end

    local norm = normalize_lhs(lhs)
    return tbl[norm] or tbl[lhs]
end

--- Remove a keymap
function editor.keymap.del(mode, lhs)
    local c_mode = canonical_mode(mode)
    local tbl = keymaps[c_mode]
    if not tbl then return end

    local norm = normalize_lhs(lhs)
    tbl[norm] = nil
    tbl[lhs] = nil
end

--- Match a key sequence against registered keymaps
-- @return entry, status ("exact", "prefix", "none")
function editor.keymap.match(mode, seq)
    local c_mode = canonical_mode(mode)
    local tbl = keymaps[c_mode]
    if not tbl then return nil, "none" end

    local exact_entry = tbl[seq]

    -- Check if seq is a prefix of any registered keymap
    local is_prefix = false
    for k, _ in pairs(tbl) do
        if #k > #seq and k:sub(1, #seq) == seq then
            is_prefix = true
            break
        end
    end

    if exact_entry then
        return exact_entry, is_prefix and "exact_or_prefix" or "exact"
    elseif is_prefix then
        return nil, "prefix"
    else
        return nil, "none"
    end
end

--- Dispatch a key combination
function editor.keymap.dispatch(mode, seq)
    local c_mode = canonical_mode(mode)
    local tbl = keymaps[c_mode]
    if not tbl then return false, "none" end

    local entry = tbl[seq]
    if not entry then
        local norm = normalize_lhs(seq)
        entry = tbl[norm]
    end

    if not entry then return false, "not_found" end

    local rhs = entry.rhs
    if type(rhs) == "function" then
        local res = rhs()
        if res == false then
            return false, "rejected"
        end
        return true, "executed"
    elseif type(rhs) == "string" then
        local cmd = rhs:match("^:(.*)<[cC][rR]>$") or rhs:match("^:(.*)\n$")
        if cmd then
            if editor.dispatch_command then
                editor.dispatch_command(":" .. cmd)
            end
            return true, "command"
        elseif rhs:sub(1, 1) == ":" then
            if editor.dispatch_command then
                editor.dispatch_command(rhs)
            end
            return true, "command"
        else
            return true, rhs
        end
    end

    return true, "ok"
end

--- Feed a single key character or sequence into the keymap engine
-- @return status ("pending", "matched", "nomatch"), value, prev_pending
function editor.keymap.feed(mode, key)
    local test_seq = pending_seq .. key
    local entry, status = editor.keymap.match(mode, test_seq)

    if status == "prefix" then
        pending_seq = test_seq
        return "pending", pending_seq
    elseif status == "exact" or status == "exact_or_prefix" then
        pending_seq = ""
        local ok, _ = editor.keymap.dispatch(mode, test_seq)
        if ok == false then
            return "nomatch", key
        end
        return "matched", test_seq
    else
        local prev = pending_seq
        pending_seq = ""
        return "nomatch", key, prev
    end
end

function editor.keymap.get_pending()
    return pending_seq
end

function editor.keymap.clear_pending()
    local p = pending_seq
    pending_seq = ""
    return p
end

return editor.keymap
