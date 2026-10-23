-- runtime/lua/editor/buffers.lua
-- Buffer list, cycling, switching, and deletion

local M = {}
editor.buffers = M

M.alt_id = nil

function M.list()
    local list = editor.list_buffers()
    local cur = editor.get_current_buffer()
    local cur_id = cur and cur:get_id()

    local lines = {}
    for _, b in ipairs(list) do
        local active_flag = (b.id == cur_id) and "%a" or ((b.id == M.alt_id) and "# " or "  ")
        local dirty_flag = b.is_dirty and " +" or "  "
        local name = b.name or "[No Name]"
        table.insert(lines, string.format("%2d %s%s %-20s line %d", b.id, active_flag, dirty_flag, '"' .. name .. '"', b.line_count or 1))
    end
    local output = table.concat(lines, "\n")
    editor.set_status(output)
    return list
end

function M.next()
    local list = editor.list_buffers()
    if #list == 0 then return end
    local cur = editor.get_current_buffer()
    local cur_id = cur and cur:get_id()

    local cur_idx = 1
    for i, b in ipairs(list) do
        if b.id == cur_id then
            cur_idx = i
            break
        end
    end

    local next_idx = (cur_idx % #list) + 1
    M.switch(list[next_idx].id)
end

function M.prev()
    local list = editor.list_buffers()
    if #list == 0 then return end
    local cur = editor.get_current_buffer()
    local cur_id = cur and cur:get_id()

    local cur_idx = 1
    for i, b in ipairs(list) do
        if b.id == cur_id then
            cur_idx = i
            break
        end
    end

    local prev_idx = ((cur_idx - 2 + #list) % #list) + 1
    M.switch(list[prev_idx].id)
end

function M.switch(target)
    if not target or target == "" then
        editor.set_error("Argument required")
        return false
    end

    local list = editor.list_buffers()
    local target_id = tonumber(target)
    local found_id = nil

    if target_id then
        for _, b in ipairs(list) do
            if b.id == target_id then
                found_id = b.id
                break
            end
        end
    else
        local query = tostring(target):lower()
        for _, b in ipairs(list) do
            local name = (b.name or ""):lower()
            local path = (b.path or ""):lower()
            if name:find(query, 1, true) or path:find(query, 1, true) then
                found_id = b.id
                break
            end
        end
    end

    if not found_id then
        editor.set_error("No matching buffer for: " .. tostring(target))
        return false
    end

    local cur = editor.get_current_buffer()
    if cur and cur:get_id() ~= found_id then
        M.alt_id = cur:get_id()
    end

    local buf = editor.get_buffer_by_id(found_id)
    if buf then
        editor.set_current_buffer(buf)
        editor.set_status('Buffer ' .. tostring(found_id) .. ' active')
        return true
    end
    return false
end

function M.delete(target, force)
    local list = editor.list_buffers()
    if #list == 0 then return false end

    local cur = editor.get_current_buffer()
    local cur_id = cur and cur:get_id()

    local target_id = nil
    if not target or target == "" then
        target_id = cur_id
    else
        local num = tonumber(target)
        if num then
            target_id = num
        else
            local query = tostring(target):lower()
            for _, b in ipairs(list) do
                local name = (b.name or ""):lower()
                local path = (b.path or ""):lower()
                if name:find(query, 1, true) or path:find(query, 1, true) then
                    target_id = b.id
                    break
                end
            end
        end
    end

    if not target_id then
        editor.set_error("No matching buffer to delete")
        return false
    end

    local target_buf = editor.get_buffer_by_id(target_id)
    if not target_buf then
        editor.set_error("Buffer not found: " .. tostring(target_id))
        return false
    end

    local dirty, _, _ = target_buf:is_dirty()
    if dirty and not force then
        editor.set_error("No write since last change for buffer " .. tostring(target_id) .. " (add ! to override)")
        return false
    end

    if M.alt_id == target_id then
        M.alt_id = nil
    end

    editor.close_buffer(target_id)

    -- Ensure a valid active buffer remains
    local remaining = editor.list_buffers()
    if #remaining == 0 then
        local fresh, _, _ = editor.create_buffer()
        editor.set_current_buffer(fresh)
    elseif not editor.get_current_buffer() or target_id == cur_id then
        local next_active = nil
        if M.alt_id then
            for _, b in ipairs(remaining) do
                if b.id == M.alt_id then
                    next_active = M.alt_id
                    break
                end
            end
        end
        if not next_active then
            next_active = remaining[1].id
        end
        local next_buf = editor.get_buffer_by_id(next_active)
        if next_buf then
            editor.set_current_buffer(next_buf)
        end
    end

    return true
end

-- Register commands
editor.create_command("ls", function() M.list() end)
editor.create_command("buffers", function() M.list() end)
editor.create_command("bn", function() M.next() end)
editor.create_command("bnext", function() M.next() end)
editor.create_command("bp", function() M.prev() end)
editor.create_command("bprev", function() M.prev() end)
editor.create_command("b", function(args) M.switch(args) end)
editor.create_command("buffer", function(args) M.switch(args) end)
editor.create_command("bd", function(args) M.delete(args, false) end)
editor.create_command("bdelete", function(args) M.delete(args, false) end)
editor.create_command("bd!", function(args) M.delete(args, true) end)
editor.create_command("bdelete!", function(args) M.delete(args, true) end)

return M
