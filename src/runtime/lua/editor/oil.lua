-- runtime/lua/editor/oil.lua
-- Oil-style filesystem buffer manager for Electronic Macdonalds

local M = {}
editor = editor or {}
editor.oil = M

M.snapshots = {}
M.oil_buffers = {}

function M.is_oil_buffer(buf)
    if not buf then return false end
    return M.oil_buffers[buf:get_id()] == true
end

local function normalize_dir_path(path)
    if not path or path == "" or path == "." then
        path = "."
    end
    if not path:match("/$") then
        path = path .. "/"
    end
    return path
end

--- Open or refresh directory buffer
function M.open(dir_path)
    dir_path = normalize_dir_path(dir_path)

    -- Check if an oil buffer already exists for this path
    local target_buf = nil
    for _, b in ipairs(editor.list_buffers()) do
        local b_obj = editor.get_buffer_by_id(b.id)
        if b_obj and M.is_oil_buffer(b_obj) and b_obj:get_path() == dir_path then
            target_buf = b_obj
            break
        end
    end

    if not target_buf then
        local new_buf, _, _ = editor.create_buffer()
        if not new_buf then
            editor.set_error("Failed to create directory buffer")
            return nil
        end
        target_buf = new_buf
        target_buf:set_path(dir_path)
        M.oil_buffers[target_buf:get_id()] = true
    end

    -- Read entries
    local raw_entries = editor.read_dir(dir_path)
    local dirs = {}
    local files = {}

    for _, entry in ipairs(raw_entries) do
        if entry.is_dir then
            table.insert(dirs, entry.name .. "/")
        else
            table.insert(files, entry.name)
        end
    end

    table.sort(dirs, function(a, b) return a:lower() < b:lower() end)
    table.sort(files, function(a, b) return a:lower() < b:lower() end)

    local sorted_entries = {}
    for _, d in ipairs(dirs) do
        table.insert(sorted_entries, { name = d, is_dir = true })
    end
    for _, f in ipairs(files) do
        table.insert(sorted_entries, { name = f, is_dir = false })
    end

    -- Populate buffer text
    local text = ""
    for _, entry in ipairs(sorted_entries) do
        text = text .. entry.name .. "\n"
    end

    target_buf:delete(0, target_buf:len())
    if #text > 0 then
        target_buf:insert(0, text)
    end

    -- Store snapshot
    M.snapshots[target_buf:get_id()] = {
        dir_path = dir_path,
        entries = sorted_entries,
    }

    editor.set_current_buffer(target_buf)
    editor.set_cursor(0, 0)
    editor.set_status("Oil: " .. dir_path)
    return target_buf
end

--- Navigate into selected entry on current line
function M.select_entry()
    local cur_buf = editor.get_current_buffer()
    if not M.is_oil_buffer(cur_buf) then return false end

    local line_idx, _ = editor.get_cursor()
    local line_text = cur_buf:get_line(line_idx)
    if not line_text or line_text == "" then return false end

    line_text = line_text:match("^%s*(.-)%s*$")
    if line_text == "" then return false end

    local snap = M.snapshots[cur_buf:get_id()]
    local base_dir = snap and snap.dir_path or ""
    if base_dir ~= "" and not base_dir:match("/$") then
        base_dir = base_dir .. "/"
    end

    local clean_entry = line_text:gsub("^/+", "")
    local full_path = base_dir .. clean_entry
    full_path = full_path:gsub("([^/])/+", "%1/")

    if clean_entry:match("/$") or editor.is_dir(full_path) then
        return M.open(full_path) ~= nil
    else
        return editor.edit_path(full_path)
    end
end

--- Navigate to parent directory
function M.parent_dir()
    local cur_buf = editor.get_current_buffer()
    if not M.is_oil_buffer(cur_buf) then return false end

    local snap = M.snapshots[cur_buf:get_id()]
    local cur_dir = snap and snap.dir_path or "."
    cur_dir = cur_dir:gsub("/+$", "")
    local parent = cur_dir:match("^(.-)/[^/]+$")
    if not parent or parent == "" then
        parent = (cur_dir:match("^/") and "/" or "..")
    end
    return M.open(parent) ~= nil
end

--- Save / Commit changes in Oil buffer
function M.save(buf)
    if not M.is_oil_buffer(buf) then return false end

    local snap = M.snapshots[buf:get_id()]
    if not snap then return true end

    local dir_path = snap.dir_path
    local orig = snap.entries

    -- Read current buffer lines
    local current_lines = {}
    local count = buf:line_count()
    for i = 0, count - 1 do
        local l = buf:get_line(i)
        if l and l ~= "" then
            l = l:match("^%s*(.-)%s*$")
            if l ~= "" then
                table.insert(current_lines, l)
            end
        end
    end

    -- Diff lines vs original entries
    local orig_kept = {}
    local curr_matched = {}

    for i, o in ipairs(orig) do
        for j, c in ipairs(current_lines) do
            if not curr_matched[j] and o.name == c then
                orig_kept[i] = true
                curr_matched[j] = true
                break
            end
        end
    end

    local orig_unmatched = {}
    for i, o in ipairs(orig) do
        if not orig_kept[i] then
            table.insert(orig_unmatched, { idx = i, entry = o })
        end
    end

    local curr_unmatched = {}
    for j, c in ipairs(current_lines) do
        if not curr_matched[j] then
            table.insert(curr_unmatched, { idx = j, name = c })
        end
    end

    -- Pairing for rename:
    local min_pair = math.min(#orig_unmatched, #curr_unmatched)
    local renames = {}
    for k = 1, min_pair do
        table.insert(renames, {
            old_name = orig_unmatched[k].entry.name:gsub("/$", ""),
            new_name = curr_unmatched[k].name:gsub("/$", ""),
        })
    end

    -- Extra unmatched in orig are DELETES
    local deletes = {}
    for k = min_pair + 1, #orig_unmatched do
        table.insert(deletes, orig_unmatched[k].entry)
    end

    -- Extra unmatched in curr are CREATES
    local creates = {}
    for k = min_pair + 1, #curr_unmatched do
        table.insert(creates, curr_unmatched[k].name)
    end

    -- Execute operations:
    -- 1. Creates
    for _, name in ipairs(creates) do
        if name:match("/$") then
            editor.fs_mkdir(dir_path .. name:gsub("/$", ""))
        else
            editor.fs_touch(dir_path .. name)
        end
    end

    -- 2. Renames
    for _, r in ipairs(renames) do
        if r.old_name ~= r.new_name then
            editor.fs_rename(dir_path .. r.old_name, dir_path .. r.new_name)
        end
    end

    -- 3. Deletes
    for _, d in ipairs(deletes) do
        local raw_name = d.name:gsub("/$", "")
        editor.fs_delete(dir_path .. raw_name, d.is_dir)
    end

    -- Refresh buffer and snapshot
    M.open(dir_path)
    editor.set_status("Oil: saved changes to " .. dir_path)
    return true
end

return M
